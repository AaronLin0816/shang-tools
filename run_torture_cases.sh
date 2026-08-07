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

Runs the fixed list of torture test cases hard-coded in this script, one after
another, using exactly the same model invocation as run_isa_case.sh, and
prints a PASS/FAIL summary at the end.

This script only accepts the --conf argument; it is applied to every case.

Examples:
  $0                                      # unified cache: arches/json/arch.json
  $0 --conf arches/json/dfe_dbe_pcache.json  # perfect cache

Per-case model output is written to:
  ${SCRIPT_DIR}/torture_case_logs/<case>.log
A combined summary is written to:
  ${SCRIPT_DIR}/torture_case_logs/summary.txt
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
    "model/test/benchmarks/elfs/torture_case/test_1693898619238.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693900014199.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693901506483.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693902998643.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693904607584.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693906123648.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693907678400.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693909297267.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693910854899.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693912416778.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693913896849.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693915456444.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693917006251.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693918456005.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693919974045.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693921542962.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693923069222.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693924632826.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693926121255.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693927617357.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693929093167.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693930621256.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693932116368.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693933581801.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693935077043.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693936691567.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693938276768.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693939764852.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693941308672.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693942965720.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693944543546.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693946048549.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693947612774.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693949161055.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693950653527.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693952155703.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693953687229.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693955155478.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693956700774.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693958230867.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693959795335.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693961294237.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693962834606.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693964388330.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693965963211.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693967538116.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693969132239.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693970672139.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693972338553.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693974056733.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693976084561.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693978495054.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693980749683.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693982876596.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693985085692.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693987606610.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693989989432.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693992195670.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693994549500.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693996661102.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1693999022027.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694001283276.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694003476027.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694005609140.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694007645192.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694009687412.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694011684866.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694013369315.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694015085667.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694016780971.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694018434853.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694020114027.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694021781157.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694023470266.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694026844454.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694028474355.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694030173987.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694031888319.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694033551826.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694035230281.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694036944230.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694038424256.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694039903737.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694041385904.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694042844794.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694044314551.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694045790877.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694047234081.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694048698206.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694050210460.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694051703096.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694053177791.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694054663054.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694056283059.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694057911336.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694059415675.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694060948600.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694062420191.riscv"
    "model/test/benchmarks/elfs/torture_case/test_1694063914816.riscv"
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
log_dir="${SCRIPT_DIR}/torture_case_logs"
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

echo "Running ${n} torture test case(s) from ${REPO_ROOT}"
echo "Extra args (applied to every case): ${model_extra_args[*]}"
echo

for case_rel in "${TEST_CASES[@]}"; do
    idx=$((idx + 1))
    printf '[%2d/%2d] %-64s ' "${idx}" "${n}" "${case_rel#model/test/benchmarks/elfs/torture_case/}"
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
    echo "==================== Torture case summary ===================="
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
