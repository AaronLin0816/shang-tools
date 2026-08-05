#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_repo_root() {
    local dir="${SCRIPT_DIR}"
    while [[ "${dir}" != "/" ]]; do
        if [[ -f "${dir}/CMakeLists.txt" && -x "${dir}/build.sh" ]]; then
            printf "%s\n" "${dir}"
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 1
}

usage() {
    cat <<EOF
Usage:
  $0 <model-relative-test-file>

Example:
  $0 model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-lb.riscv

The model output is overwritten to:
  ${SCRIPT_DIR}/log.txt
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

if [[ "$#" -ne 1 ]]; then
    usage >&2
    exit 2
fi

REPO_ROOT="$(find_repo_root)" || die "failed to locate model repository root from ${SCRIPT_DIR}"

case_arg="$1"
case "${case_arg}" in
    /*)
        case "${case_arg}" in
            "${REPO_ROOT}"/*)
                repo_relative="${case_arg#${REPO_ROOT}/}"
                ;;
            *)
                die "absolute test path must be inside repo root: ${REPO_ROOT}"
                ;;
        esac
        ;;
    model/*)
        repo_relative="${case_arg#model/}"
        ;;
    ./*|../*)
        die "please pass a path relative from model, for example: model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-lb.riscv"
        ;;
    *)
        repo_relative="${case_arg}"
        ;;
esac

test_file="${REPO_ROOT}/${repo_relative}"
log_file="${SCRIPT_DIR}/log.txt"
docker_script="${SCRIPT_DIR}/docker-gcc15.sh"

container_model_dir="${CONTAINER_MODEL_DIR:-/work/home/shang-chi/workspace/model}"
container_model_bin="${container_model_dir}/release/model"
container_isa_model_yaml="${container_model_dir}/test/benchmarks/isa_model_config/ctest_isa_model.yaml"
container_isa_model_bin="${container_model_dir}/test/benchmarks/isa_model_config/reset_rom_80000000.bin:0x1000"
container_test_file="${container_model_dir}/${repo_relative}"
container_ld_path="${container_model_dir}/release:${container_model_dir}/release/lib:${container_model_dir}/release/thirdparty/DRAMsim3:${container_model_dir}/release/thirdparty/riscv-isa-sim/lib:${container_model_dir}/release/thirdparty/riscv-isa-sim/interface/spike-prefix/src/spike-build:${container_model_dir}/release/src/isa/isa_model:${container_model_dir}/release/src/app/bpu_sim:${container_model_dir}/release/src/app/cache_sim"

[[ -x "${docker_script}" ]] || die "docker launcher not found or not executable: ${docker_script}"
[[ -x "${REPO_ROOT}/release/model" ]] || die "model executable not found or not executable: ${REPO_ROOT}/release/model"
[[ -f "${REPO_ROOT}/test/benchmarks/isa_model_config/ctest_isa_model.yaml" ]] || die "ISA model yaml not found"
[[ -f "${REPO_ROOT}/test/benchmarks/isa_model_config/reset_rom_80000000.bin" ]] || die "ISA model bin not found"
[[ -f "${test_file}" ]] || die "test file not found: ${test_file}"

: > "${log_file}"

set +e
(
    cd "${REPO_ROOT}"
    HOST_MODEL_DIR="${REPO_ROOT}" CONTAINER_MODEL_DIR="${container_model_dir}" "${docker_script}" \
        bash -lc '
            set -euo pipefail
            export LD_LIBRARY_PATH="$1${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            shift
            exec "$@"
        ' _ \
        "${container_ld_path}" \
        "${container_model_bin}" \
        "--isa-model-yaml=${container_isa_model_yaml}" \
        "--isa-model-bin=${container_isa_model_bin}" \
        "${container_test_file}" \
        -l top info 1
) > "${log_file}" 2>&1
status=$?
set -e

echo "log written to ${log_file}"
exit "${status}"
