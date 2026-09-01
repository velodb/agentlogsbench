#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"
source "${ROOT_DIR}/agentlogsbench/common/benchmark_lib.sh"

SIZE=""
DATA_DIR="${DATA_DIR:-}"
DATA_GLOB="${DATA_GLOB:-}"
OUTPUT_PREFIX="${OUTPUT_PREFIX:-$(default_output_prefix)}"
MACHINE_LABEL="${BENCHMARK_MACHINE:-$(current_machine_label)}"
OS_LABEL="${BENCHMARK_OS:-$(current_os_label)}"
RUN_DATE="${BENCHMARK_DATE:-$(current_run_date)}"
KEEP_RUNTIME=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --size) SIZE="$2"; shift ;;
        --data-dir|--dataset-dir) DATA_DIR="$2"; shift ;;
        --data-glob) DATA_GLOB="$2"; shift ;;
        --output-prefix) OUTPUT_PREFIX="$2"; shift ;;
        --machine) MACHINE_LABEL="$2"; shift ;;
        --os) OS_LABEL="$2"; shift ;;
        --run-date) RUN_DATE="$2"; shift ;;
        --keep-runtime|--no-cleanup) KEEP_RUNTIME=1 ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

SIZE="$(resolve_dataset_size "${SIZE}")"
if [ -n "${DATA_DIR}" ]; then
    DATA_DIR="$(cd "${DATA_DIR}" && pwd)"
fi
if [ -z "${DATA_GLOB}" ]; then
    if [ -z "${DATA_DIR}" ]; then
        DATA_DIR="$(default_download_dir "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
    fi
    DATA_GLOB="$(dataset_download_files "${DATA_DIR}" "${SIZE}")"
elif [[ "${DATA_GLOB}" != /* ]]; then
    DATA_GLOB="${PWD}/${DATA_GLOB}"
fi

RESULT_DIR="${RESULT_DIR:-${SCRIPT_DIR}/results}"
RESULT_BASE="$(result_base_name "${OUTPUT_PREFIX}" "${SIZE}")"
RESULT_JSON="${RESULT_DIR}/${RESULT_BASE}.json"
QUERY_RESULTS_DIR="${RESULT_DIR}/_query_results"
QUERY_RESULTS_FILE=""
if [ "${SIZE}" = "1m" ]; then
    QUERY_RESULTS_FILE="${QUERY_RESULTS_DIR}/_${RESULT_BASE}.query_results"
fi
RUNTIME_DIR="${RUNTIME_DIR:-${SCRIPT_DIR}/runtime/${RESULT_BASE}}"
ARTIFACT_DIR="${RUNTIME_DIR}/result_artifacts"
LOAD_TIME_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.load_time"
COUNT_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.count"
TOTAL_SIZE_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.total_size"
DATA_SIZE_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.data_size"
INDEX_SIZE_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.index_size"
RUNTIME_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.results_runtime"
QUERY_FILE="${QUERY_FILE:-${SCRIPT_DIR}/queries.sql}"
QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE:-}"
MO_EXPECTED_ROWS="${MO_EXPECTED_ROWS:-auto}"
TRIES="${TRIES:-3}"
if ! [[ "${TRIES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "TRIES must be a positive integer: ${TRIES}" >&2
    exit 1
fi

mkdir -p "${RESULT_DIR}"
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    mkdir -p "${QUERY_RESULTS_DIR}"
fi
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
    local status=$?
    benchmark_log "matrixone" "Cleaning up runtime artifacts in ${RUNTIME_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    MO_PID_FILE="${MO_PID_FILE}" bash "${SCRIPT_DIR}/stop.sh" || status=$?
    return "${status}"
}

if [ "${KEEP_RUNTIME}" -ne 1 ]; then
    trap cleanup EXIT
fi

benchmark_log "matrixone" "Benchmark start size=${SIZE} data_glob=${DATA_GLOB} result_json=${RESULT_JSON}"
benchmark_log "matrixone" "Stage 1/6 checking MatrixOne client and SQL endpoint"
bash "${SCRIPT_DIR}/install.sh"
bash "${SCRIPT_DIR}/start.sh"

benchmark_log "matrixone" "Stage 2/6 importing data into ${MO_DB}.${MO_TABLE}"
start_ns="$(date +%s%N)"
MO_EXPECTED_ROWS="${MO_EXPECTED_ROWS}" DATA_GLOB="${DATA_GLOB}" bash "${SCRIPT_DIR}/import.sh"
end_ns="$(date +%s%N)"
awk "BEGIN { printf \"%.3f\\n\", (${end_ns} - ${start_ns}) / 1000000000 }" > "${LOAD_TIME_FILE}"
benchmark_log "matrixone" "Stage 2/6 import complete load_time=$(cat "${LOAD_TIME_FILE}")s"

benchmark_log "matrixone" "Stage 3/6 collecting row counts and storage statistics"
actual_rows="$(matrixone_mysql --database="${MO_DB}" -N -B -e "SELECT COUNT(*) FROM \`${MO_TABLE}\`" | tr -d '[:space:]')"
printf '%s\n' "${actual_rows}" > "${COUNT_FILE}"

table_status="$(matrixone_mysql --database="${MO_DB}" --batch --skip-column-names --raw \
    --execute="SHOW TABLE STATUS FROM \`${MO_DB}\` LIKE '${MO_TABLE}';" 2>/dev/null | tail -n 1 || true)"
data_size="$(printf '%s\n' "${table_status}" | awk -F '\t' 'NF >= 8 { print $6 }')"
index_size="$(printf '%s\n' "${table_status}" | awk -F '\t' 'NF >= 8 { print $8 }')"
if ! [[ "${data_size}" =~ ^[0-9]+$ && "${index_size}" =~ ^[0-9]+$ ]] ||
    { [ "${data_size}" = "0" ] && [ "${index_size}" = "0" ]; }; then
    total_size="$(matrixone_mysql --database="${MO_DB}" -N -B -e \
        "SELECT mo_table_size('$(matrixone_sql_escape "${MO_DB}")', '$(matrixone_sql_escape "${MO_TABLE}")')" \
        2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "${total_size}" =~ ^[0-9]+$ ]]; then
        data_size="${total_size}"
        index_size=0
    else
        data_size=0
        index_size=0
    fi
fi
printf '%s\n' "$((data_size + index_size))" > "${TOTAL_SIZE_FILE}"
printf '%s\n' "${data_size}" > "${DATA_SIZE_FILE}"
printf '%s\n' "${index_size}" > "${INDEX_SIZE_FILE}"
benchmark_log "matrixone" "Stage 3/6 stats complete rows=$(tr -d '\n' < "${COUNT_FILE}") total_size=$(tr -d '\n' < "${TOTAL_SIZE_FILE}")"

if [ -z "${QUERY_CONTEXT_FILE}" ] && [ -n "${DATA_DIR}" ]; then
    QUERY_CONTEXT_FILE="$(default_query_context_file "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
fi
benchmark_log "matrixone" "Stage 4/6 resolving query context"
if [ -n "${QUERY_CONTEXT_FILE}" ]; then
    python3 "${ROOT_DIR}/agentlogsbench/common/resolve_query_context.py" \
        --data-dir "${DATA_DIR}" \
        --size "${SIZE}" \
        --output-file "${QUERY_CONTEXT_FILE}" >/dev/null
fi

benchmark_log "matrixone" "Stage 5/6 running benchmark queries from ${QUERY_FILE}"
MO_DB="${MO_DB}" MO_TABLE="${MO_TABLE}" MO_HOST="${MO_HOST}" MO_PORT="${MO_PORT}" \
    MO_USER="${MO_USER}" MO_PASSWORD="${MO_PASSWORD}" TRIES="${TRIES}" \
    QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE}" QUERY_RESULTS_FILE="${QUERY_RESULTS_FILE}" \
    RUNTIME_LOG="${RUNTIME_FILE}" bash "${SCRIPT_DIR}/run_queries.sh" "${MO_DB}" "${QUERY_FILE}" > "${RUNTIME_FILE}"
benchmark_log "matrixone" "Stage 5/6 query timing saved to ${RUNTIME_FILE}"

ENGINE_VERSION="$(matrixone_mysql --database="${MO_DB}" -N -B -e 'SELECT VERSION()' | tr -d '\r\n')"
if [ -z "${ENGINE_VERSION}" ]; then
    ENGINE_VERSION="unknown"
fi
benchmark_log "matrixone" "Stage 6/6 building result JSON"
json_args=(
    --system "MatrixOne"
    --version "${ENGINE_VERSION}"
    --os "${OS_LABEL}"
    --date "${RUN_DATE}"
    --machine "${MACHINE_LABEL}"
    --dataset-size "$(dataset_row_count "${SIZE}")"
    --runtime-file "${RUNTIME_FILE}"
    --count-file "${COUNT_FILE}"
    --total-size-file "${TOTAL_SIZE_FILE}"
    --data-size-file "${DATA_SIZE_FILE}"
    --index-size-file "${INDEX_SIZE_FILE}"
    --load-time-file "${LOAD_TIME_FILE}"
    --tries "${TRIES}"
    --output-file "${RESULT_JSON}"
)
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")
fi
python3 "${ROOT_DIR}/agentlogsbench/common/build_jsonbench_result.py" "${json_args[@]}"

rm -rf "${ARTIFACT_DIR}"
benchmark_log "matrixone" "Benchmark complete result_json=${RESULT_JSON} query_results=${QUERY_RESULTS_FILE}"
