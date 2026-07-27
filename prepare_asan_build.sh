#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}
BUILD_DIR=${BUILD_DIR:-"$REPO_ROOT/build-asan"}
BUILD_JOBS=${BUILD_JOBS:-}
LEAK_RESULT_DIR=${LEAK_RESULT_DIR:-"$BUILD_DIR/asan-leak-results"}
LEAK_CASE_DIR=${LEAK_CASE_DIR:-"$REPO_ROOT/test/benchmarks/elfs"}
ISA_MODEL_YAML=${ISA_MODEL_YAML:-"$REPO_ROOT/test/benchmarks/isa_model_config/ctest_isa_model.yaml"}
ISA_MODEL_BIN=${ISA_MODEL_BIN:-"$REPO_ROOT/test/benchmarks/isa_model_config/reset_rom_80000000.bin:0x1000"}
RUN_LEAK_CHECK=0
MODEL_ARGS=()

log()
{
    printf '[asan-prepare] %s\n' "$*"
}

die()
{
    printf '[asan-prepare][error] %s\n' "$*" >&2
    exit 1
}

usage()
{
    cat <<EOF
Usage: tools/shang-tools/prepare_asan_build.sh [-h|--help] [--leak-check -- <case-relative-path>]

Environment overrides:
  BUILD_DIR=<path>             Build directory, default: <repo>/build-asan.
  BUILD_JOBS=<num>             Parallel build jobs, default: half of nproc.
  LEAK_RESULT_DIR=<path>       Leak-check output directory, default: <build>/asan-leak-results.
  LEAK_CASE_DIR=<path>         Case prefix directory, default: <repo>/test/benchmarks/elfs.
  ISA_MODEL_YAML=<path>        Fixed --isa-model-yaml value.
  ISA_MODEL_BIN=<path:addr>    Fixed --isa-model-bin value.
  ASAN_OPTIONS_EXTRA=<opts>    Extra colon-separated AddressSanitizer options.
  LSAN_OPTIONS_EXTRA=<opts>    Extra colon-separated LeakSanitizer options.

Examples:
  tools/shang-tools/prepare_asan_build.sh
  tools/shang-tools/prepare_asan_build.sh --leak-check -- dhrystone.riscv
  tools/shang-tools/prepare_asan_build.sh --leak-check -- isa_case/rv64ui/rv64ui-p-add.riscv

This script is expected to run inside the prepared docker container from ~/workspace/model.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --leak-check)
            RUN_LEAK_CHECK=1
            shift
            ;;
        --)
            shift
            MODEL_ARGS=("$@")
            break
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

package_manager()
{
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt-get'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    else
        return 1
    fi
}

as_root()
{
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "missing required tools and neither root nor sudo is available"
    fi
}

install_packages()
{
    local pm=$1
    shift

    case "$pm" in
        apt-get)
            as_root apt-get update
            as_root apt-get install -y "$@"
            ;;
        dnf)
            as_root dnf install -y "$@"
            ;;
        yum)
            as_root yum install -y "$@"
            ;;
        apk)
            as_root apk add --no-cache "$@"
            ;;
        *)
            die "unsupported package manager: $pm"
            ;;
    esac
}

ensure_tools()
{
    local missing=()
    local tool
    for tool in bash cmake make gcc g++ grep sed awk sort mktemp nproc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        log "required tools are present"
        return 0
    fi

    log "missing tools: ${missing[*]}"

    local pm
    pm=$(package_manager) || die "no supported package manager found"

    case "$pm" in
        apt-get)
            install_packages "$pm" cmake make gcc g++ grep sed gawk coreutils
            ;;
        dnf|yum)
            install_packages "$pm" cmake make gcc gcc-c++ grep sed gawk coreutils
            ;;
        apk)
            install_packages "$pm" cmake make gcc g++ grep sed gawk coreutils
            ;;
    esac

    for tool in "${missing[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || die "tool is still missing after install: $tool"
    done
}

ensure_cmake_version()
{
    local version
    version=$(cmake --version | sed -n 's/^cmake version //p' | sed -n '1p')
    awk -v version="$version" 'BEGIN {
        split(version, part, ".")
        ok = (part[1] > 3) || (part[1] == 3 && part[2] >= 20)
        exit(ok ? 0 : 1)
    }' || die "cmake >= 3.20 is required, found: $version"
    log "cmake version: $version"
}

activate_conda_if_available()
{
    if [ -n "${CONDA_PREFIX:-}" ]; then
        log "CONDA_PREFIX already set: $CONDA_PREFIX"
        return 0
    fi

    local conda_sh
    for conda_sh in \
        /work/tools/miniconda3/etc/profile.d/conda.sh \
        /workspace/luke/miniconda3/etc/profile.d/conda.sh; do
        if [ -f "$conda_sh" ]; then
            # shellcheck source=/dev/null
            . "$conda_sh"
            for env_name in model_gcc15 model_v2_centos7 sparta_new; do
                if conda activate "$env_name" >/dev/null 2>&1; then
                    log "activated conda environment: $env_name"
                    return 0
                fi
            done
        fi
    done

    log "CONDA_PREFIX is not set; continuing and letting CMake report dependency issues"
}

check_asan_compiler_support()
{
    local tmp_dir
    tmp_dir=$(mktemp -d)
    printf 'int main() { return 0; }\n' >"$tmp_dir/asan_probe.cpp"
    "${CXX:-g++}" -fsanitize=address -fno-omit-frame-pointer "$tmp_dir/asan_probe.cpp" -o "$tmp_dir/asan_probe" >/dev/null 2>&1 \
        || die "compiler cannot link a minimal -fsanitize=address program"
    rm -rf "$tmp_dir"
    log "compiler supports -fsanitize=address"
}

ensure_sparta_fastdebug_build_type()
{
    local sparta_cmake="$REPO_ROOT/thirdparty/platform/sparta/CMakeLists.txt"
    local tmp_file

    [ -f "$sparta_cmake" ] || die "Sparta CMakeLists.txt not found: $sparta_cmake"

    if grep -Eq 'CMAKE_BUILD_TYPE[[:space:]]+MATCHES[[:space:]]+"\^\[Ff\]\[Aa\]\[Ss\]\[Tt\]\[Dd\]\[Ee\]\[Bb\]\[Uu\]\[Gg\]\$"' "$sparta_cmake"; then
        if grep -Fq 'add_compile_definitions(NDEBUG)' "$sparta_cmake"; then
            log "Sparta CMakeLists.txt already accepts FASTDEBUG with NDEBUG"
            return 0
        fi

        tmp_file=$(mktemp "${sparta_cmake}.XXXXXX")
        awk '
            {
                print
                if ($0 ~ /^[[:space:]]*message[[:space:]]*\([[:space:]]*STATUS[[:space:]]+"Building Sparta in Fast Debug mode"[[:space:]]*\)/) {
                    print "  add_compile_definitions(NDEBUG)"
                    inserted = 1
                }
            }
            END {
                if (!inserted) {
                    exit 42
                }
            }
        ' "$sparta_cmake" > "$tmp_file" || {
            rm -f "$tmp_file"
            die "failed to patch Sparta CMakeLists.txt FASTDEBUG branch with NDEBUG"
        }
        mv "$tmp_file" "$sparta_cmake"
        log "patched Sparta FASTDEBUG branch with NDEBUG"
        return 0
    fi

    grep -Fq "message (FATAL_ERROR \"Unknown CMAKE_BUILD_TYPE.  See README.md OR type 'make' at the SPARTA root\")" "$sparta_cmake" \
        || die "Sparta CMakeLists.txt build-type guard changed; please inspect before patching"

    tmp_file=$(mktemp "${sparta_cmake}.XXXXXX")
    awk '
        {
            print
            if ($0 ~ /^[[:space:]]*message[[:space:]]*\([[:space:]]*STATUS[[:space:]]+"Building Sparta in Release Minimal Size mode"[[:space:]]*\)/) {
                print "elseif (CMAKE_BUILD_TYPE MATCHES \"^[Ff][Aa][Ss][Tt][Dd][Ee][Bb][Uu][Gg]$\")"
                print "  message (STATUS \"Building Sparta in Fast Debug mode\")"
                print "  add_compile_definitions(NDEBUG)"
                inserted = 1
            }
        }
        END {
            if (!inserted) {
                exit 42
            }
        }
    ' "$sparta_cmake" > "$tmp_file" || {
        rm -f "$tmp_file"
        die "failed to patch Sparta CMakeLists.txt for FASTDEBUG"
    }

    mv "$tmp_file" "$sparta_cmake"
    log "patched Sparta CMakeLists.txt to accept FASTDEBUG build type with NDEBUG"
}

configure_asan()
{
    [ -f "$REPO_ROOT/CMakeLists.txt" ] || die "CMakeLists.txt not found in repo root: $REPO_ROOT"
    grep -Eq 'option[[:space:]]*\([[:space:]]*ENABLE_ASAN' "$REPO_ROOT/CMakeLists.txt" \
        || die "ENABLE_ASAN option is not defined in root CMakeLists.txt"

    ensure_sparta_fastdebug_build_type

    mkdir -p "$BUILD_DIR"
    log "configuring FASTDEBUG ASAN build in: $BUILD_DIR"

    cmake -S "$REPO_ROOT" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=FASTDEBUG \
        -DENABLE_ASAN=ON \
        -DQUEUE_USAGE=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

    grep -Eq '^ENABLE_ASAN:BOOL=ON$' "$BUILD_DIR/CMakeCache.txt" \
        || die "ENABLE_ASAN is not ON in $BUILD_DIR/CMakeCache.txt"
    grep -Eq '^CMAKE_BUILD_TYPE:STRING=FASTDEBUG$' "$BUILD_DIR/CMakeCache.txt" \
        || die "CMAKE_BUILD_TYPE is not FASTDEBUG in $BUILD_DIR/CMakeCache.txt"

    log "ASAN switch is ON and FASTDEBUG configure is complete"
}

asan_build_artifact_exists()
{
    [ -d "$BUILD_DIR" ] && [ -x "$BUILD_DIR/model" ]
}

asan_build_cache_matches_repo_root()
{
    [ ! -f "$BUILD_DIR/CMakeCache.txt" ] && return 0
    grep -Fxq "CMAKE_HOME_DIRECTORY:INTERNAL=$REPO_ROOT" "$BUILD_DIR/CMakeCache.txt"
}

reset_stale_asan_build_state()
{
    [ -d "$BUILD_DIR" ] || return 0
    log "clearing stale ASAN CMake cache and executable in: $BUILD_DIR"
    rm -rf "$BUILD_DIR/CMakeCache.txt" "$BUILD_DIR/CMakeFiles" "$BUILD_DIR/model"
}

asan_build_artifact_runtime_deps_resolved()
{
    local runtime_ld_path
    local ldd_output

    command -v ldd >/dev/null 2>&1 || {
        log "ldd is not available; cannot validate existing ASAN artifact runtime dependencies"
        return 0
    }

    runtime_ld_path=$(build_runtime_ld_path)
    if ! ldd_output=$(LD_LIBRARY_PATH="$runtime_ld_path" ldd "$BUILD_DIR/model" 2>&1); then
        log "existing ASAN artifact failed runtime dependency inspection"
        printf '%s\n' "$ldd_output" | sed 's/^/[asan-prepare]   /' >&2
        return 1
    fi

    if printf '%s\n' "$ldd_output" | grep -Fq 'not found'; then
        log "existing ASAN artifact has unresolved runtime dependencies"
        printf '%s\n' "$ldd_output" | sed -n '/not found/s/^/[asan-prepare]   /p' >&2
        return 1
    fi
}

prepare_or_reuse_asan_build()
{
    if asan_build_artifact_exists; then
        if asan_build_cache_matches_repo_root && asan_build_artifact_runtime_deps_resolved; then
            log "reusing existing ASAN FASTDEBUG build artifact: $BUILD_DIR/model"
            return 0
        fi
        reset_stale_asan_build_state
    elif ! asan_build_cache_matches_repo_root; then
        reset_stale_asan_build_state
    fi

    configure_asan
    build_asan
}

resolve_leak_case()
{
    local case_arg=$1
    local case_path

    [ -d "$LEAK_CASE_DIR" ] || die "leak case prefix directory does not exist: $LEAK_CASE_DIR"

    case "$case_arg" in
        /*)
            die "leak case path must be relative to $LEAK_CASE_DIR: $case_arg"
            ;;
        *..*)
            die "leak case path must not contain '..': $case_arg"
            ;;
        test/benchmarks/elfs/*)
            die "pass the path after test/benchmarks/elfs only: $case_arg"
            ;;
    esac

    case_arg=${case_arg#./}
    case_path="$LEAK_CASE_DIR/$case_arg"
    [ -f "$case_path" ] || die "leak case file does not exist: $case_path"
    printf '%s\n' "$case_path"
}

build_leak_model_args()
{
    local case_path=$1

    MODEL_ARGS=(
        "--arch-search-dir" "$REPO_ROOT/arches"
        "--config-search-dir" "$REPO_ROOT"
        "--isa-model-yaml=$ISA_MODEL_YAML"
        "--isa-model-bin=$ISA_MODEL_BIN"
        "$case_path"
    )
}

build_runtime_ld_path()
{
    local dirs=(
        "$BUILD_DIR"
        "$BUILD_DIR/lib"
        "$BUILD_DIR/thirdparty/DRAMsim3"
        "$BUILD_DIR/thirdparty/riscv-isa-sim/lib"
        "$BUILD_DIR/thirdparty/riscv-isa-sim/interface/spike-prefix/src/spike-build"
        "$BUILD_DIR/src/isa/isa_model"
        "$BUILD_DIR/src/app/bpu_sim"
        "$BUILD_DIR/src/app/cache_sim"
    )

    if [ -n "${CONDA_PREFIX:-}" ]; then
        dirs+=("$CONDA_PREFIX/lib" "$CONDA_PREFIX/lib64")
    fi
    local dir
    local joined=""

    for dir in "${dirs[@]}"; do
        [ -d "$dir" ] || continue
        if [ -z "$joined" ]; then
            joined="$dir"
        else
            joined="$joined:$dir"
        fi
    done

    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        joined="$joined:$LD_LIBRARY_PATH"
    fi

    printf '%s
' "$joined"
}

append_sanitizer_options()
{
    local base_options=$1
    local extra_options=$2

    if [ -n "$extra_options" ]; then
        printf '%s:%s' "$base_options" "$extra_options"
    else
        printf '%s' "$base_options"
    fi
}

run_leak_check()
{
    [ -x "$BUILD_DIR/model" ] || die "ASAN model executable not found: $BUILD_DIR/model"

    if [ "${#MODEL_ARGS[@]}" -ne 1 ]; then
        die "--leak-check requires exactly one case path after --"
    fi

    local case_path
    case_path=$(resolve_leak_case "${MODEL_ARGS[0]}")
    build_leak_model_args "$case_path"

    mkdir -p "$LEAK_RESULT_DIR"

    local timestamp
    local log_base
    local stdout_log
    local stderr_log
    local sanitizer_log_prefix
    local asan_options
    local lsan_options
    local model_rc
    local runtime_ld_path
    local leak_found=0
    local sanitizer_error_found=0
    local log_file

    timestamp=$(date +%Y%m%d-%H%M%S)
    log_base="$LEAK_RESULT_DIR/asan-leak-$timestamp"
    stdout_log="$log_base.stdout.log"
    stderr_log="$log_base.stderr.log"
    sanitizer_log_prefix="$log_base.sanitizer"

    asan_options=$(append_sanitizer_options         "detect_leaks=1:halt_on_error=0:allocator_may_return_null=1:strict_string_checks=1:check_initialization_order=1:log_path=$sanitizer_log_prefix"         "${ASAN_OPTIONS_EXTRA:-}")
    lsan_options=$(append_sanitizer_options         "exitcode=23:report_objects=1:log_threads=1"         "${LSAN_OPTIONS_EXTRA:-}")
    runtime_ld_path=$(build_runtime_ld_path)

    log "running leak check with ASAN FASTDEBUG artifact: $BUILD_DIR/model"
    log "leak case: $case_path"
    log "leak-check logs: $LEAK_RESULT_DIR"

    if ASAN_OPTIONS="$asan_options" LSAN_OPTIONS="$lsan_options" LD_LIBRARY_PATH="$runtime_ld_path" "$BUILD_DIR/model" "${MODEL_ARGS[@]}" >"$stdout_log" 2>"$stderr_log"; then
        model_rc=0
    else
        model_rc=$?
    fi

    for log_file in "$stderr_log" "$sanitizer_log_prefix".*; do
        [ -f "$log_file" ] || continue
        if grep -Eq 'ERROR: LeakSanitizer: detected memory leaks|SUMMARY: AddressSanitizer: .* leaked|Direct leak of|Indirect leak of' "$log_file"; then
            leak_found=1
        fi
        if grep -Eq 'ERROR: AddressSanitizer|ERROR: LeakSanitizer' "$log_file"; then
            sanitizer_error_found=1
        fi
    done

    log "model stdout: $stdout_log"
    log "model stderr: $stderr_log"
    log "sanitizer log prefix: $sanitizer_log_prefix.<pid>"

    if [ "$leak_found" -eq 1 ]; then
        log "LeakSanitizer result: memory leak detected"
        return 23
    fi

    if [ "$sanitizer_error_found" -eq 1 ]; then
        log "AddressSanitizer result: sanitizer error detected; inspect logs"
        return 24
    fi

    if [ "$model_rc" -ne 0 ]; then
        log "model exited with code $model_rc; no leak signature was found in sanitizer logs"
        return "$model_rc"
    fi

    log "LeakSanitizer result: no leak detected"
}

resolve_build_jobs()
{
    if [ -n "$BUILD_JOBS" ]; then
        case "$BUILD_JOBS" in
            ''|*[!0-9]*)
                die "BUILD_JOBS must be a positive integer: $BUILD_JOBS"
                ;;
        esac
        [ "$BUILD_JOBS" -gt 0 ] || die "BUILD_JOBS must be greater than 0"
        return 0
    fi

    BUILD_JOBS=$(($(nproc) / 2))
    if [ "$BUILD_JOBS" -lt 1 ]; then
        BUILD_JOBS=1
    fi
}

build_asan()
{
    resolve_build_jobs
    log "building ASAN FASTDEBUG target with $BUILD_JOBS parallel jobs"

    cmake --build "$BUILD_DIR" --parallel "$BUILD_JOBS"

    if [ ! -x "$BUILD_DIR/model" ]; then
        die "build completed but executable was not found: $BUILD_DIR/model"
    fi

    log "ASAN FASTDEBUG build is complete: $BUILD_DIR/model"
}

ensure_tools
ensure_cmake_version
activate_conda_if_available
check_asan_compiler_support
prepare_or_reuse_asan_build

if [ "$RUN_LEAK_CHECK" -eq 1 ]; then
    run_leak_check
fi
