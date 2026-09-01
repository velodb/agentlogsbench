#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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
if [ -z "${DATA_GLOB}" ]; then
    if [ -z "${DATA_DIR}" ]; then
        DATA_DIR="$(default_download_dir "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
    fi
    DATA_GLOB="$(dataset_download_files "${DATA_DIR}" "${SIZE}")"
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
SHOW_DATA_POLL_INTERVAL="${DORIS_SHOW_DATA_POLL_INTERVAL:-5}"
SHOW_DATA_MAX_ATTEMPTS="${DORIS_SHOW_DATA_MAX_ATTEMPTS:-60}"
QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE:-}"

mkdir -p "${RESULT_DIR}"
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    mkdir -p "${QUERY_RESULTS_DIR}"
fi
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
    benchmark_log "doris" "Cleaning up runtime artifacts in ${RUNTIME_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    RUNTIME_DIR="${RUNTIME_DIR}" RESULT_DIR="${RESULT_DIR}" bash "${SCRIPT_DIR}/stop.sh"
}

if [ "${KEEP_RUNTIME}" -ne 1 ]; then
    trap cleanup EXIT
fi

benchmark_log "doris" "Benchmark start size=${SIZE} data_glob=${DATA_GLOB} result_json=${RESULT_JSON}"
benchmark_log "doris" "Stage 1/6 starting runtime in ${RUNTIME_DIR}"
RUNTIME_DIR="${RUNTIME_DIR}" bash "${SCRIPT_DIR}/start.sh"

if [ -f "${RUNTIME_DIR}/deploy.env" ]; then
    # shellcheck disable=SC1090
    source "${RUNTIME_DIR}/deploy.env"
fi

DORIS_FE_HOST="${DORIS_FE_HOST:-127.0.0.1}"
DORIS_QUERY_PORT="${DORIS_QUERY_PORT:-19030}"
DORIS_USER="${DORIS_USER:-root}"
DORIS_PASSWORD="${DORIS_PASSWORD:-}"
DORIS_DB="${DORIS_DB:-agentlogsbench_bench}"
DORIS_TABLE="${DORIS_TABLE:-agent_observations}"

mysql_env=()
if [ -n "${DORIS_PASSWORD}" ]; then
    mysql_env=("MYSQL_PWD=${DORIS_PASSWORD}")
fi

benchmark_log "doris" "Stage 2/6 importing data into ${DORIS_DB}.${DORIS_TABLE}"
start_ns="$(date +%s%N)"
RUNTIME_DIR="${RUNTIME_DIR}" DATA_GLOB="${DATA_GLOB}" DORIS_DB="${DORIS_DB}" DORIS_TABLE="${DORIS_TABLE}" bash "${SCRIPT_DIR}/import.sh"
end_ns="$(date +%s%N)"
awk "BEGIN { printf \"%.3f\n\", (${end_ns} - ${start_ns}) / 1000000000 }" > "${LOAD_TIME_FILE}"
benchmark_log "doris" "Stage 2/6 import complete load_time=$(cat "${LOAD_TIME_FILE}")s"

benchmark_log "doris" "Stage 3/6 collecting row counts and storage statistics"
env "${mysql_env[@]}" mysql -N -B -h "${DORIS_FE_HOST}" -P "${DORIS_QUERY_PORT}" -u "${DORIS_USER}" "${DORIS_DB}" -e "SELECT COUNT(*) FROM ${DORIS_TABLE}" > "${COUNT_FILE}"

env "${mysql_env[@]}" mysql -N -B -h "${DORIS_FE_HOST}" -P "${DORIS_QUERY_PORT}" -u "${DORIS_USER}" "${DORIS_DB}" \
    -e "ANALYZE TABLE ${DORIS_TABLE} WITH SYNC" >/dev/null

show_data_output=""
total_size=0
for attempt in $(seq 1 "${SHOW_DATA_MAX_ATTEMPTS}"); do
    benchmark_log "doris" "Stage 3/6 SHOW DATA poll attempt ${attempt}/${SHOW_DATA_MAX_ATTEMPTS}"
    show_data_output="$(
        env "${mysql_env[@]}" mysql -N -B -h "${DORIS_FE_HOST}" -P "${DORIS_QUERY_PORT}" -u "${DORIS_USER}" "${DORIS_DB}" \
            -e "SHOW DATA FROM ${DORIS_TABLE}"
    )"
    total_size="$(
        printf '%s\n' "${show_data_output}" | python3 -c '
import re
import sys

UNITS = {
    "B": 1,
    "KB": 1024,
    "MB": 1024 ** 2,
    "GB": 1024 ** 3,
    "TB": 1024 ** 4,
    "PB": 1024 ** 5,
}

def parse_size(text: str) -> int | None:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?B)", text.strip(), re.IGNORECASE)
    if not match:
        return None
    return int(float(match.group(1)) * UNITS[match.group(2).upper()])

rows = []
for raw_line in sys.stdin.read().splitlines():
    line = raw_line.rstrip()
    if not line:
        continue
    cols = line.split("\t")
    if len(cols) < 3:
        continue
    rows.append(cols)

for cols in rows:
    if cols[1].strip() == "Total":
        size = parse_size(cols[2])
        if size is not None:
            print(size)
            raise SystemExit(0)

for cols in rows:
    size = parse_size(cols[2])
    if size is not None:
        print(size)
        raise SystemExit(0)

print(0)
'
    )"
    if [ "${total_size}" -gt 0 ]; then
        break
    fi
    if [ "${attempt}" -lt "${SHOW_DATA_MAX_ATTEMPTS}" ]; then
        sleep "${SHOW_DATA_POLL_INTERVAL}"
    fi
done

if [ "${total_size}" -le 0 ]; then
    echo "Doris SHOW DATA stayed at zero after ANALYZE TABLE WITH SYNC" >&2
    printf '%s\n' "${show_data_output}" >&2
    exit 1
fi

printf '%s\n' "${total_size}" > "${TOTAL_SIZE_FILE}"
printf '%s\n' "${total_size}" > "${DATA_SIZE_FILE}"
rm -f "${INDEX_SIZE_FILE}"
benchmark_log "doris" "Stage 3/6 stats complete rows=$(tr -d '\n' < "${COUNT_FILE}") total_size=${total_size}"

if [ -z "${QUERY_CONTEXT_FILE}" ] && [ -n "${DATA_DIR}" ]; then
    QUERY_CONTEXT_FILE="$(default_query_context_file "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
fi
benchmark_log "doris" "Stage 4/6 resolving query context"
if [ -n "${QUERY_CONTEXT_FILE}" ]; then
    python3 "${ROOT_DIR}/agentlogsbench/common/resolve_query_context.py" \
        --data-dir "${DATA_DIR}" \
        --size "${SIZE}" \
        --output-file "${QUERY_CONTEXT_FILE}" >/dev/null
fi

benchmark_log "doris" "Stage 5/6 running benchmark queries from ${QUERY_FILE}"
TRIES=3 QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE}" QUERY_RESULTS_FILE="${QUERY_RESULTS_FILE}" DORIS_FE_HOST="${DORIS_FE_HOST}" DORIS_QUERY_PORT="${DORIS_QUERY_PORT}" DORIS_USER="${DORIS_USER}" DORIS_PASSWORD="${DORIS_PASSWORD}" \
    bash "${SCRIPT_DIR}/run_queries.sh" "${DORIS_DB}" "${QUERY_FILE}" > "${RUNTIME_FILE}"
benchmark_log "doris" "Stage 5/6 query timing saved to ${RUNTIME_FILE}"

ENGINE_VERSION="$(
    env "${mysql_env[@]}" mysql -N -B -h "${DORIS_FE_HOST}" -P "${DORIS_QUERY_PORT}" -u "${DORIS_USER}" "${DORIS_DB}" -e "SELECT version()"
)"
benchmark_log "doris" "Stage 6/6 building result JSON"
json_args=(
    --system "Apache Doris"
    --version "${ENGINE_VERSION}"
    --os "${OS_LABEL}"
    --date "${RUN_DATE}"
    --machine "${MACHINE_LABEL}"
    --dataset-size "$(dataset_row_count "${SIZE}")"
    --runtime-file "${RUNTIME_FILE}"
    --count-file "${COUNT_FILE}"
    --total-size-file "${TOTAL_SIZE_FILE}"
    --data-size-file "${DATA_SIZE_FILE}"
    --load-time-file "${LOAD_TIME_FILE}"
    --output-file "${RESULT_JSON}"
)
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")
fi
python3 "${ROOT_DIR}/agentlogsbench/common/build_jsonbench_result.py" "${json_args[@]}"

rm -rf "${ARTIFACT_DIR}"
benchmark_log "doris" "Benchmark complete result_json=${RESULT_JSON} query_results=${QUERY_RESULTS_FILE}"
