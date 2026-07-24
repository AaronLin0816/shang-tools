#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

RUNS="${RUNS:-30}"
PERF_BIN="${PERF_BIN:-perf}"
PERF_FREQ="${PERF_FREQ:-997}"
PERF_EVENT="${PERF_EVENT:-cycles:u}"
PERF_CALLGRAPH="${PERF_CALLGRAPH:-dwarf,8192}"
PERF_REPORT_ARGS="${PERF_REPORT_ARGS:---no-inline}"
PERF_SCRIPT_ARGS="${PERF_SCRIPT_ARGS:---no-inline}"
PERF_DROP_POLLUTED_STACKS="${PERF_DROP_POLLUTED_STACKS:-1}"
PERF_MAX_STACK_DEPTH="${PERF_MAX_STACK_DEPTH:-64}"
PERF_MAX_UNKNOWN_RUN="${PERF_MAX_UNKNOWN_RUN:-8}"
BUILD="${BUILD:-1}"
BUILD_JOBS="${BUILD_JOBS:-10}"
PROFILE_BUILD_DIR="${PROFILE_BUILD_DIR:-${REPO_ROOT}/profile_build}"
USE_DOCKER_GCC15="${USE_DOCKER_GCC15:-1}"
DOCKER_GCC15_SCRIPT="${DOCKER_GCC15_SCRIPT:-${REPO_ROOT}/tools/shang-tools/shang-tools/docker-gcc15.sh}"
DEFAULT_FLAMEGRAPH_DIR="${REPO_ROOT}/tools/FlameGraph"
FLAMEGRAPH_REPO="${FLAMEGRAPH_REPO:-https://github.com/brendangregg/FlameGraph.git}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
CONTAINER_IMAGE="${PROFILE_CONTAINER_IMAGE:-${CONTAINER_IMAGE:-}}"
CONTAINER_EXTRA_ARGS="${CONTAINER_EXTRA_ARGS:-}"
BUILD_CMD="${BUILD_CMD:-}"
ROOT_CMAKE_FILE="${REPO_ROOT}/CMakeLists.txt"
PROFILE_CXX_FLAGS_LINE='set(CMAKE_CXX_FLAGS_PROFILE "-O3 -g -fno-omit-frame-pointer" CACHE STRING "" FORCE)'
PROFILE_C_FLAGS_LINE='set(CMAKE_C_FLAGS_PROFILE   "-O3 -g -fno-omit-frame-pointer" CACHE STRING "" FORCE)'

DEFAULT_CASE_DIR="${REPO_ROOT}/test/benchmarks/elfs/isa_cases"
FALLBACK_CASE_DIR="${REPO_ROOT}/test/benchmarks/elfs/isa_case"
CASE_DIR="${CASE_DIR:-${DEFAULT_CASE_DIR}}"

ISA_MODEL_YAML="${ISA_MODEL_YAML-${REPO_ROOT}/test/benchmarks/isa_model_config/ctest_isa_model.yaml}"
ISA_MODEL_BIN="${ISA_MODEL_BIN-${REPO_ROOT}/test/benchmarks/isa_model_config/reset_rom_80000000.bin:0x1000}"
RESULT_ROOT="${RESULT_ROOT:-${SCRIPT_DIR}/perf-results}"

usage() {
    cat <<EOF
Usage:
  $0 <case-relative-path-or-absolute-path> [model extra args...]

Default behavior:
  - Build in CMake Profile mode under docker-gcc15 when available
  - Case prefix: ${CASE_DIR}
  - Run the same case ${RUNS} times under perf
  - Generate perf.data, perf report, collapsed stack, and flamegraph SVG

Environment overrides:
  BUILD                                      Build before profiling, default: 1
  BUILD_CMD                                  Optional custom build command run from repo root
  BUILD_JOBS                                 Build parallelism for default Profile build, default: 10
  PROFILE_BUILD_DIR                         Profile build directory, default: <repo>/profile_build
                                             Reused when it contains executable model; rebuilt otherwise
  USE_DOCKER_GCC15                           Use docker-gcc15 for default build when available, default: 1
  DOCKER_GCC15_SCRIPT                        docker-gcc15 wrapper path
  PROFILE_CONTAINER_IMAGE / CONTAINER_IMAGE  Optional container image used for BUILD_CMD
  CONTAINER_RUNTIME                          Container runtime, default: docker
  CONTAINER_EXTRA_ARGS                       Extra args appended to container run
  CASE_DIR                                   Case prefix directory
  RUNS                                       Loop count, default: 30
  PERF_BIN                                   perf command, default: perf
  PERF_FREQ                                  perf sampling frequency, default: 997
  PERF_EVENT                                 perf event, default: cycles:u
  PERF_CALLGRAPH                             perf call graph mode, default: dwarf,8192
  PERF_REPORT_ARGS                           Extra perf report args, default: --no-inline
  PERF_SCRIPT_ARGS                           Extra perf script args, default: --no-inline
  PERF_DROP_POLLUTED_STACKS                  Drop obviously broken folded stacks, default: 1
  PERF_MAX_STACK_DEPTH                       Dropped stack depth threshold, default: 64
  PERF_MAX_UNKNOWN_RUN                       Consecutive [unknown] threshold, default: 8
  FLAMEGRAPH_DIR                             Directory containing stackcollapse-perf.pl and flamegraph.pl
  FLAMEGRAPH_REPO                            Repo cloned into tools/FlameGraph when missing
  RESULT_ROOT                                Result output root
  ISA_MODEL_YAML                             --isa-model-yaml value
  ISA_MODEL_BIN                              --isa-model-bin value
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

is_false() {
    [[ "$1" == "0" || "$1" == "false" || "$1" == "FALSE" || "$1" == "no" || "$1" == "NO" ]]
}

ensure_default_flamegraph_dir() {
    if [[ -x "${DEFAULT_FLAMEGRAPH_DIR}/stackcollapse-perf.pl" && -x "${DEFAULT_FLAMEGRAPH_DIR}/flamegraph.pl" ]]; then
        return 0
    fi

    if [[ -e "${DEFAULT_FLAMEGRAPH_DIR}" ]]; then
        die "FlameGraph directory exists but required scripts are missing: ${DEFAULT_FLAMEGRAPH_DIR}"
    fi

    command -v git >/dev/null 2>&1 || die "git command not found; cannot clone FlameGraph"
    mkdir -p "${REPO_ROOT}/tools"

    echo "[tools] FlameGraph not found under tools; cloning ${FLAMEGRAPH_REPO}"
    git clone "${FLAMEGRAPH_REPO}" "${DEFAULT_FLAMEGRAPH_DIR}"
}

find_flamegraph_tool() {
    local tool_name="$1"

    if [[ -n "${FLAMEGRAPH_DIR:-}" && -x "${FLAMEGRAPH_DIR}/${tool_name}" ]]; then
        printf '%s\n' "${FLAMEGRAPH_DIR}/${tool_name}"
        return 0
    fi

    if command -v "${tool_name}" >/dev/null 2>&1; then
        command -v "${tool_name}"
        return 0
    fi

    local candidate
    for candidate in \
        "${DEFAULT_FLAMEGRAPH_DIR}/${tool_name}" \
        "${REPO_ROOT}/FlameGraph/${tool_name}" \
        "/opt/FlameGraph/${tool_name}" \
        "/usr/local/FlameGraph/${tool_name}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

ensure_root_profile_flags() {
    [[ -f "${ROOT_CMAKE_FILE}" ]] || die "root CMake file does not exist: ${ROOT_CMAKE_FILE}"

    local tmp_file
    tmp_file="$(mktemp "${ROOT_CMAKE_FILE}.XXXXXX")"

    awk \
        -v cxx_flags="${PROFILE_CXX_FLAGS_LINE}" \
        -v c_flags="${PROFILE_C_FLAGS_LINE}" '
        /^[[:space:]]*set[[:space:]]*\([[:space:]]*CMAKE_CXX_FLAGS_PROFILE[[:space:]]+/ {
            if (!seen_cxx) {
                print cxx_flags
            }
            seen_cxx = 1
            next
        }
        /^[[:space:]]*set[[:space:]]*\([[:space:]]*CMAKE_C_FLAGS_PROFILE[[:space:]]+/ {
            if (!seen_c) {
                print c_flags
            }
            seen_c = 1
            next
        }
        { print }
        END {
            if (!seen_cxx) {
                print cxx_flags
            }
            if (!seen_c) {
                print c_flags
            }
        }
    ' "${ROOT_CMAKE_FILE}" > "${tmp_file}"

    if cmp -s "${ROOT_CMAKE_FILE}" "${tmp_file}"; then
        rm -f "${tmp_file}"
        echo "[build] root Profile flags already satisfy perf requirements"
    else
        mv "${tmp_file}" "${ROOT_CMAKE_FILE}"
        echo "[build] updated root Profile flags in ${ROOT_CMAKE_FILE}"
    fi
}

profile_build_artifact_exists() {
    [[ -d "${PROFILE_BUILD_DIR}" && -x "${PROFILE_BUILD_DIR}/model" ]]
}

run_default_profile_build() {
    local build_body
    printf -v build_body         'rm -rf %q && mkdir -p %q && cd %q && cmake %q -DCMAKE_BUILD_TYPE=Profile -DQUEUE_USAGE=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && cmake --build . -j%q'         "${PROFILE_BUILD_DIR}"         "${PROFILE_BUILD_DIR}"         "${PROFILE_BUILD_DIR}"         "${REPO_ROOT}"         "${BUILD_JOBS}"

    if ! is_false "${USE_DOCKER_GCC15}"; then
        [[ -f "${DOCKER_GCC15_SCRIPT}" ]] || die "docker-gcc15 script not found: ${DOCKER_GCC15_SCRIPT}"
        echo "[build] docker-gcc15 Profile build: ${PROFILE_BUILD_DIR}"
        (cd "${REPO_ROOT}" && CONTAINER_MODEL_DIR="${REPO_ROOT}" bash "${DOCKER_GCC15_SCRIPT}" bash -lc "${build_body}")
        return 0
    fi

    echo "[build] local Profile build: ${PROFILE_BUILD_DIR}"
    (cd "${REPO_ROOT}" && bash -lc "${build_body}")
}
build_profile() {
    if is_false "${BUILD}"; then
        echo "[build] skipped"
        return 0
    fi

    if profile_build_artifact_exists; then
        echo "[build] reusing existing Profile artifact: ${PROFILE_BUILD_DIR}/model"
        return 0
    fi

    if [[ -z "${BUILD_CMD}" ]]; then
        run_default_profile_build
        return 0
    fi

    if [[ -n "${CONTAINER_IMAGE}" ]]; then
        command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1 || die "container runtime not found: ${CONTAINER_RUNTIME}"
        echo "[build] container image: ${CONTAINER_IMAGE}"
        echo "[build] command: ${BUILD_CMD}"
        # shellcheck disable=SC2086
        "${CONTAINER_RUNTIME}" run --rm             -v "${REPO_ROOT}:${REPO_ROOT}"             -w "${REPO_ROOT}"             ${CONTAINER_EXTRA_ARGS}             "${CONTAINER_IMAGE}"             bash -lc "${BUILD_CMD}"
    else
        echo "[build] custom command: ${BUILD_CMD}"
        (cd "${REPO_ROOT}" && bash -lc "${BUILD_CMD}")
    fi
}

resolve_case() {
    local case_arg="$1"

    if [[ ! -d "${CASE_DIR}" && "${CASE_DIR}" == "${DEFAULT_CASE_DIR}" && -d "${FALLBACK_CASE_DIR}" ]]; then
        CASE_DIR="${FALLBACK_CASE_DIR}"
    fi

    if [[ "${case_arg}" == /* ]]; then
        [[ -f "${case_arg}" ]] || die "case file does not exist: ${case_arg}"
        printf '%s\n' "${case_arg}"
        return 0
    fi

    [[ -d "${CASE_DIR}" ]] || die "case prefix directory does not exist: ${CASE_DIR}"

    local case_path="${CASE_DIR}/${case_arg}"
    [[ -f "${case_path}" ]] || die "case file does not exist: ${case_path}"
    printf '%s\n' "${case_path}"
}

write_runner() {
    local runner="$1"
    local runs="$2"
    local model_bin="$3"
    local case_path="$4"
    shift 4

    local model_args=("${model_bin}")
    if [[ -n "${ISA_MODEL_YAML}" ]]; then
        model_args+=("--isa-model-yaml=${ISA_MODEL_YAML}")
    fi
    if [[ -n "${ISA_MODEL_BIN}" ]]; then
        model_args+=("--isa-model-bin=${ISA_MODEL_BIN}")
    fi
    model_args+=("${case_path}" "$@")

    {
        cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
for i in \$(seq 1 ${runs}); do
EOF
        printf '    '
        printf '%q ' "${model_args[@]}"
        printf '\n'
        cat <<EOF
done
EOF
    } > "${runner}"
    chmod +x "${runner}"
}


filter_folded_stacks() {
    local folded_raw="$1"
    local folded="$2"

    if is_false "${PERF_DROP_POLLUTED_STACKS}"; then
        cp "${folded_raw}" "${folded}"
        return 0
    fi

    awk \
        -v max_depth="${PERF_MAX_STACK_DEPTH}" \
        -v max_unknown_run="${PERF_MAX_UNKNOWN_RUN}" '
        function is_polluted(stack, parts, depth, i, unknown_run) {
            depth = split(stack, parts, ";")
            if (max_depth > 0 && depth > max_depth) {
                return 1
            }

            unknown_run = 0
            for (i = 1; i <= depth; i++) {
                if (parts[i] == "[unknown]") {
                    unknown_run++
                    if (max_unknown_run > 0 && unknown_run > max_unknown_run) {
                        return 1
                    }
                } else {
                    unknown_run = 0
                }
            }

            return 0
        }

        {
            if (match($0, / [0-9]+$/) == 0) {
                next
            }

            stack = substr($0, 1, RSTART - 1)
            count = substr($0, RSTART + 1) + 0
            if (is_polluted(stack)) {
                dropped_lines++
                dropped_count += count
                next
            }

            kept_count += count
            print
        }

        END {
            printf("[perf] folded filter: dropped_lines=%d dropped_count=%d kept_count=%d\n",
                dropped_lines, dropped_count, kept_count) > "/dev/stderr"
        }
    ' "${folded_raw}" > "${folded}"
}

main() {
    if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    local rel_case="$1"
    shift

    command -v "${PERF_BIN}" >/dev/null 2>&1 || die "perf command not found: ${PERF_BIN}"
    if [[ -z "${FLAMEGRAPH_DIR:-}" ]]; then
        ensure_default_flamegraph_dir
    fi

    local stackcollapse
    local flamegraph
    stackcollapse="$(find_flamegraph_tool stackcollapse-perf.pl)" || die "stackcollapse-perf.pl not found; set FLAMEGRAPH_DIR"
    flamegraph="$(find_flamegraph_tool flamegraph.pl)" || die "flamegraph.pl not found; set FLAMEGRAPH_DIR"

    ensure_root_profile_flags
    build_profile
    ensure_root_profile_flags

    local model_bin="${PROFILE_BUILD_DIR}/model"
    [[ -x "${model_bin}" ]] || die "profile model binary not found or not executable: ${model_bin}"

    local case_path
    case_path="$(resolve_case "${rel_case}")"

    local case_name
    case_name="${rel_case#/}"
    case_name="${case_name//\//_}"
    case_name="${case_name//[^A-Za-z0-9_.-]/_}"

    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    local out_dir="${RESULT_ROOT}/${stamp}_${case_name}"
    mkdir -p "${out_dir}"

    local runner="${out_dir}/run_case_${RUNS}x.sh"
    write_runner "${runner}" "${RUNS}" "${model_bin}" "${case_path}" "$@"

    local perf_data="${out_dir}/perf.data"
    local perf_report="${out_dir}/perf.report.txt"
    local perf_report_no_children="${out_dir}/perf.report.no-children.txt"
    local perf_script="${out_dir}/perf.script"
    local folded_raw="${out_dir}/perf.folded.raw"
    local folded="${out_dir}/perf.folded"
    local svg="${out_dir}/flamegraph.svg"

    local perf_report_args=()
    local perf_script_args=()
    read -r -a perf_report_args <<< "${PERF_REPORT_ARGS}"
    read -r -a perf_script_args <<< "${PERF_SCRIPT_ARGS}"

    echo "[perf] output: ${out_dir}"
    echo "[perf] runs: ${RUNS}, frequency: ${PERF_FREQ}, event: ${PERF_EVENT}, callgraph: ${PERF_CALLGRAPH}"
    "${PERF_BIN}" record -e "${PERF_EVENT}" -F "${PERF_FREQ}" -g --call-graph "${PERF_CALLGRAPH}" -o "${perf_data}" -- "${runner}"
    "${PERF_BIN}" report "${perf_report_args[@]}" --stdio -i "${perf_data}" --sort=overhead,symbol,dso --percent-limit 0.5 > "${perf_report}"
    "${PERF_BIN}" report "${perf_report_args[@]}" --stdio --no-children -i "${perf_data}" --sort=symbol,dso --percent-limit 0.3 > "${perf_report_no_children}"
    "${PERF_BIN}" script "${perf_script_args[@]}" -i "${perf_data}" > "${perf_script}"
    "${stackcollapse}" "${perf_script}" > "${folded_raw}"
    filter_folded_stacks "${folded_raw}" "${folded}"
    "${flamegraph}" "${folded}" > "${svg}"

    echo "[done] flamegraph: ${svg}"
    echo "[done] perf report: ${perf_report}"
    echo "[done] no-children report: ${perf_report_no_children}"
    echo "[done] runner: ${runner}"
}

main "$@"
