#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

REMOTE_REPO=${REMOTE_REPO:-/workspace/luke/git_local/model.git}
TARGET_REF=${TARGET_REF:-origin/isa_fe_be}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-3600}
BASE_DIR=${BASE_DIR:-"$HOME/workspace/suncheek/auto-compile-work"}
WORK_DIR=${WORK_DIR:-"$BASE_DIR/work"}
CLONE_DIR=${CLONE_DIR:-"$WORK_DIR/model"}
LOG_DIR=${LOG_DIR:-"$BASE_DIR/logs"}
STATE_DIR=${STATE_DIR:-"$BASE_DIR/state"}
TOP_LOG=${TOP_LOG:-"$LOG_DIR/auto_compile.log"}
LAST_COMMIT_FILE=${LAST_COMMIT_FILE:-"$STATE_DIR/last_checked_commit"}
CONTAINER_SCRIPT=${CONTAINER_SCRIPT:-"$SCRIPT_DIR/docker-gcc15.sh"}
CONTAINER_MODEL_DIR=${CONTAINER_MODEL_DIR:-/work/home/shang-chi/workspace/model}
PARENT_SEARCH_LIMIT=${PARENT_SEARCH_LIMIT:-0}

RUN_ONCE=0

usage()
{
    cat <<EOF
Usage: $(basename "$0") [--once] [--interval SECONDS]

Environment overrides:
  REMOTE_REPO              default: /workspace/luke/git_local/model.git
  TARGET_REF               default: origin/isa_fe_be
  BASE_DIR                 default: \$HOME/workspace/suncheek/auto-compile-work
  PARENT_SEARCH_LIMIT      default: 0 (unlimited)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --once)
            RUN_ONCE=1
            shift
            ;;
        --interval)
            if [ "$#" -lt 2 ]; then
                echo "--interval requires a value" >&2
                exit 2
            fi
            INTERVAL_SECONDS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "$WORK_DIR" "$LOG_DIR" "$STATE_DIR"

timestamp()
{
    date "+%Y-%m-%d %H:%M:%S"
}

log_top()
{
    local run_id=$1
    local stage=$2
    local status=$3
    local message=$4

    printf '[%s] run=%s stage=%s status=%s %s\n' \
        "$(timestamp)" "$run_id" "$stage" "$status" "$message" | tee -a "$TOP_LOG"
}

run_stage()
{
    local run_id=$1
    local stage=$2
    local detail_log=$3
    shift 3

    log_top "$run_id" "$stage" "START" "log=$detail_log"
    if "$@" >"$detail_log" 2>&1; then
        log_top "$run_id" "$stage" "OK" "log=$detail_log"
        return 0
    fi

    local status=$?
    log_top "$run_id" "$stage" "FAIL" "exit=$status log=$detail_log"
    return "$status"
}

clone_and_prepare()
{
    local run_id=$1
    local run_log_dir=$2

    rm -rf "$CLONE_DIR"

    run_stage "$run_id" "clone" "$run_log_dir/01_clone.log" \
        bash -lc "cd \"\$1\" && git clone \"\$2\"" _ "$WORK_DIR" "$REMOTE_REPO" || return

    run_stage "$run_id" "fetch" "$run_log_dir/02_fetch.log" \
        git -C "$CLONE_DIR" fetch origin || return

    run_stage "$run_id" "checkout" "$run_log_dir/03_checkout.log" \
        git -C "$CLONE_DIR" checkout "$TARGET_REF" || return

    run_stage "$run_id" "submodule" "$run_log_dir/04_submodule.log" \
        git -C "$CLONE_DIR" submodule update --init --recursive || return
}

compile_commit()
{
    local run_id=$1
    local commit=$2
    local label=$3
    local run_log_dir=$4
    local commit_log_dir="$run_log_dir/$label"

    mkdir -p "$commit_log_dir"

    run_stage "$run_id" "$label.checkout" "$commit_log_dir/01_checkout.log" \
        git -C "$CLONE_DIR" checkout --detach "$commit" || return

    run_stage "$run_id" "$label.submodule" "$commit_log_dir/02_submodule.log" \
        git -C "$CLONE_DIR" submodule update --init --recursive || return

    rm -rf "$CLONE_DIR/release"

    run_stage "$run_id" "$label.compile" "$commit_log_dir/03_compile.log" \
        env HOST_MODEL_DIR="$CLONE_DIR" CONTAINER_MODEL_DIR="$CONTAINER_MODEL_DIR" \
        "$CONTAINER_SCRIPT" bash -lc \
        'mkdir release && cd release && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j10'
}

search_failed_parent()
{
    local run_id=$1
    local failed_commit=$2
    local run_log_dir=$3
    local cursor=$failed_commit
    local depth=0

    while parent=$(git -C "$CLONE_DIR" rev-parse --verify "${cursor}^" 2>/dev/null); do
        depth=$((depth + 1))
        if [ "$PARENT_SEARCH_LIMIT" -gt 0 ] && [ "$depth" -gt "$PARENT_SEARCH_LIMIT" ]; then
            log_top "$run_id" "parent_search" "STOP" "limit=$PARENT_SEARCH_LIMIT last_tested=$cursor"
            return 0
        fi

        log_top "$run_id" "parent_search" "START" "depth=$depth commit=$parent"
        if compile_commit "$run_id" "$parent" "parent_${depth}" "$run_log_dir"; then
            log_top "$run_id" "parent_search" "PASS" "depth=$depth commit=$parent"
        else
            log_top "$run_id" "parent_search" "FOUND_FAIL" "depth=$depth commit=$parent"
            return 0
        fi

        cursor=$parent
    done

    log_top "$run_id" "parent_search" "DONE" "no_failed_parent_found"
}

run_check_once()
{
    local run_id
    run_id=$(date "+%Y%m%d_%H%M%S")
    local run_log_dir="$LOG_DIR/$run_id"

    mkdir -p "$run_log_dir"
    log_top "$run_id" "check" "START" "work_dir=$WORK_DIR clone_dir=$CLONE_DIR"

    if ! clone_and_prepare "$run_id" "$run_log_dir"; then
        log_top "$run_id" "check" "FAIL" "clone_or_prepare_failed"
        return 0
    fi

    local current_commit
    current_commit=$(git -C "$CLONE_DIR" rev-parse HEAD)
    log_top "$run_id" "commit" "OK" "current=$current_commit"

    local last_commit=""
    if [ -f "$LAST_COMMIT_FILE" ]; then
        last_commit=$(cat "$LAST_COMMIT_FILE")
    fi

    if [ "$current_commit" = "$last_commit" ]; then
        log_top "$run_id" "compare" "SKIP" "same_commit=$current_commit"
        return 0
    fi

    printf '%s\n' "$current_commit" >"$LAST_COMMIT_FILE"
    log_top "$run_id" "compare" "CHANGED" "last=${last_commit:-none} current=$current_commit"

    if compile_commit "$run_id" "$current_commit" "current" "$run_log_dir"; then
        log_top "$run_id" "check" "OK" "compiled=$current_commit"
    else
        log_top "$run_id" "check" "FAIL" "compiled=$current_commit"
        search_failed_parent "$run_id" "$current_commit" "$run_log_dir"
    fi
}

while true; do
    run_check_once

    if [ "$RUN_ONCE" -eq 1 ]; then
        break
    fi

    sleep "$INTERVAL_SECONDS"
done
