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
  $0 [--conf <model-relative-config>]

Runs the fixed list of ISA test cases hard-coded in this script, one after
another, using exactly the same model invocation as run_isa_case.sh, and
prints a PASS/FAIL summary at the end.

This script only accepts the --conf argument; it is applied to every case.

Examples:
  $0                                      # unified cache: arches/json/arch.json
  $0 --conf arches/json/dfe_dbe_pcache.json  # perfect cache

Per-case model output is written to:
  ${SCRIPT_DIR}/isa_case_logs/<case>.log
A combined summary is written to:
  ${SCRIPT_DIR}/isa_case_logs/summary.txt
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Hard-coded list of test cases. Paths keep only the part starting from 'model/'
# (the trailing "_default" ctest suffix has been dropped).
# -----------------------------------------------------------------------------
TEST_CASES=(
    "model/test/benchmarks/elfs/isa_case/rv64mi/rv64mi-p-access.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64si/rv64si-p-dirty.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64si/rv64si-p-icache-alias.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-p-lrsc.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoadd_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoadd_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoand_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoand_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomax_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomax_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomaxu_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomaxu_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomin_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amomin_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amominu_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amominu_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoor_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoor_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoswap_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoswap_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoxor_d.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-amoxor_w.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ua/rv64ua-v-lrsc.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64uc/rv64uc-v-rvc.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ud/rv64ud-v-ldst.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ud/rv64ud-v-recoding.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64uf/rv64uf-v-ldst.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-p-sb.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-fence_i.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-ma_data.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-sb.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-sd.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-sh.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64ui/rv64ui-v-sw.riscv"
    "model/test/benchmarks/elfs/isa_case/rv64uzfh/rv64uzfh-v-ldst.riscv"
)

# -----------------------------------------------------------------------------
# Argument parsing: only --conf is accepted, and it is shared by every case.
# -----------------------------------------------------------------------------
DEFAULT_CONF="arches/json/arch.json"
model_extra_args=(--conf "${DEFAULT_CONF}")
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --conf)
            [[ "$#" -ge 2 ]] || die "--conf requires a value"
            model_extra_args=(--conf "$2")
            shift 2
            ;;
        --conf=*)
            model_extra_args=(--conf "${1#--conf=}")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1 (this script only accepts --conf)"
            ;;
    esac
done

REPO_ROOT="$(find_repo_root)" || die "failed to locate model repository root from ${SCRIPT_DIR}"

docker_script="${SCRIPT_DIR}/docker-gcc15.sh"
log_dir="${SCRIPT_DIR}/isa_case_logs"
summary_file="${log_dir}/summary.txt"

container_model_dir="${CONTAINER_MODEL_DIR:-/work/home/shang-chi/workspace/model}"
container_model_bin="${container_model_dir}/release/model"
container_isa_model_yaml="${container_model_dir}/test/benchmarks/isa_model_config/ctest_isa_model.yaml"
container_isa_model_bin="${container_model_dir}/test/benchmarks/isa_model_config/reset_rom_80000000.bin:0x1000"
container_ld_path="${container_model_dir}/release:${container_model_dir}/release/lib:${container_model_dir}/release/thirdparty/DRAMsim3:${container_model_dir}/release/thirdparty/riscv-isa-sim/lib:${container_model_dir}/release/thirdparty/riscv-isa-sim/interface/spike-prefix/src/spike-build:${container_model_dir}/release/src/isa/isa_model:${container_model_dir}/release/src/app/bpu_sim:${container_model_dir}/release/src/app/cache_sim"

# The extra args are identical for every case, so translate them once, using
# exactly the same rules as run_isa_case.sh.
container_extra_args=()
for arg in "${model_extra_args[@]}"; do
    case "${arg}" in
        "${REPO_ROOT}"/*)
            container_extra_args+=("${container_model_dir}/${arg#${REPO_ROOT}/}")
            ;;
        model/*)
            container_extra_args+=("${container_model_dir}/${arg#model/}")
            ;;
        arches/*|test/*)
            container_extra_args+=("${container_model_dir}/${arg}")
            ;;
        *)
            container_extra_args+=("${arg}")
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Shared prerequisite checks (done once for the whole batch).
# -----------------------------------------------------------------------------
[[ -x "${docker_script}" ]] || die "docker launcher not found or not executable: ${docker_script}"
[[ -x "${REPO_ROOT}/release/model" ]] || die "model executable not found or not executable: ${REPO_ROOT}/release/model"
[[ -f "${REPO_ROOT}/test/benchmarks/isa_model_config/ctest_isa_model.yaml" ]] || die "ISA model yaml not found"
[[ -f "${REPO_ROOT}/test/benchmarks/isa_model_config/reset_rom_80000000.bin" ]] || die "ISA model bin not found"

mkdir -p "${log_dir}"

# Globals set by run_one_case.
LAST_LOG_FILE=""
LAST_SKIPPED=0

# Runs a single case with exactly the same invocation as run_isa_case.sh.
# Returns the model's exit status (0 == pass). Sets LAST_LOG_FILE and, when the
# test file is missing, LAST_SKIPPED=1.
run_one_case() {
    # Entries are stored starting from 'model/'. The original run_isa_case.sh
    # treats the repo root as 'model/', so strip that prefix to get the path
    # relative to REPO_ROOT / container_model_dir (exactly its model/*) case).
    local repo_relative="${1#model/}"
    local test_file="${REPO_ROOT}/${repo_relative}"
    local container_test_file="${container_model_dir}/${repo_relative}"
    local safe_name
    safe_name="$(printf '%s' "${repo_relative}" | tr '/' '_')"
    local log_file="${log_dir}/${safe_name}.log"

    LAST_LOG_FILE="${log_file}"
    LAST_SKIPPED=0

    if [[ ! -f "${test_file}" ]]; then
        LAST_SKIPPED=1
        return 0
    fi

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
            "--arch-search-dir=${container_model_dir}/arches" \
            "--config-search-dir=${container_model_dir}" \
            "--isa-model-yaml=${container_isa_model_yaml}" \
            "--isa-model-bin=${container_isa_model_bin}" \
            "${container_test_file}" \
            "${container_extra_args[@]}" \
            -l top info 1
    ) > "${log_file}" 2>&1
    local status=$?
    set -e

    return "${status}"
}

# -----------------------------------------------------------------------------
# Main loop.
# -----------------------------------------------------------------------------
n="${#TEST_CASES[@]}"
idx=0
pass_count=0
fail_count=0
skip_count=0
declare -a results=()

echo "Running ${n} ISA test case(s) from ${REPO_ROOT}"
echo "Extra args (applied to every case): ${model_extra_args[*]}"
echo

for case_rel in "${TEST_CASES[@]}"; do
    idx=$((idx + 1))
    printf '[%2d/%2d] %-64s ' "${idx}" "${n}" "${case_rel#model/test/benchmarks/elfs/isa_case/}"
    if run_one_case "${case_rel}"; then
        if [[ "${LAST_SKIPPED}" -eq 1 ]]; then
            printf 'SKIP (file not found)\n'
            skip_count=$((skip_count + 1))
            results+=("SKIP  ${case_rel}  (test file not found)")
        else
            printf 'PASS\n'
            pass_count=$((pass_count + 1))
            results+=("PASS  ${case_rel}")
        fi
    else
        st=$?
        printf 'FAIL (exit %d)\n' "${st}"
        fail_count=$((fail_count + 1))
        results+=("FAIL  ${case_rel}  (exit ${st}, log: ${LAST_LOG_FILE})")
    fi
done

# -----------------------------------------------------------------------------
# Summary (printed to stdout and written to summary.txt).
# -----------------------------------------------------------------------------
{
    echo "==================== ISA case summary ===================="
    echo "Extra args: ${model_extra_args[*]}"
    echo "Repo root : ${REPO_ROOT}"
    echo "---------------------------------------------------------"
    printf '%s\n' "${results[@]}"
    echo "---------------------------------------------------------"
    echo "PASS: ${pass_count}   FAIL: ${fail_count}   SKIP: ${skip_count}   TOTAL: ${n}"
    echo "========================================================="
} | tee "${summary_file}"

# Non-zero exit if any case failed, so this can be used in CI.
if [[ "${fail_count}" -gt 0 ]]; then
    exit 1
fi
exit 0
