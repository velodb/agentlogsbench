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
RUNTIME_FILE="${ARTIFACT_DIR}/${RESULT_BASE}.results_runtime"
ES_CONF_DIR="${ES_CONF_DIR:-${RUNTIME_DIR}/conf}"
ES_STORAGE_PATH="${ES_STORAGE_PATH:-${RUNTIME_DIR}/data}"
ES_ENDPOINT="${ES_ENDPOINT:-http://127.0.0.1:9200}"
ES_INDEX="${ES_INDEX:-agentlogsbench_agent_observations}"
QUERY_FILE="${QUERY_FILE:-${SCRIPT_DIR}/queries.json}"
QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE:-}"

mkdir -p "${RESULT_DIR}"
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    mkdir -p "${QUERY_RESULTS_DIR}"
fi
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
    benchmark_log "elastic" "Cleaning up runtime artifacts in ${RUNTIME_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    RUNTIME_DIR="${RUNTIME_DIR}" RESULT_DIR="${RESULT_DIR}" bash "${SCRIPT_DIR}/stop.sh"
}

if [ "${KEEP_RUNTIME}" -ne 1 ]; then
    trap cleanup EXIT
fi

benchmark_log "elastic" "Benchmark start size=${SIZE} data_glob=${DATA_GLOB} result_json=${RESULT_JSON}"
benchmark_log "elastic" "Stage 1/6 starting runtime in ${RUNTIME_DIR}"
RUNTIME_DIR="${RUNTIME_DIR}" ES_CONF_DIR="${ES_CONF_DIR}" ES_STORAGE_PATH="${ES_STORAGE_PATH}" bash "${SCRIPT_DIR}/start.sh"

benchmark_log "elastic" "Stage 2/6 importing data into index ${ES_INDEX}"
start_ns="$(date +%s%N)"
ES_ENDPOINT="${ES_ENDPOINT}" ES_INDEX="${ES_INDEX}" DATA_GLOB="${DATA_GLOB}" bash "${SCRIPT_DIR}/import.sh"
end_ns="$(date +%s%N)"
awk "BEGIN { printf \"%.3f\n\", (${end_ns} - ${start_ns}) / 1000000000 }" > "${LOAD_TIME_FILE}"
benchmark_log "elastic" "Stage 2/6 import complete load_time=$(cat "${LOAD_TIME_FILE}")s"

benchmark_log "elastic" "Stage 3/6 collecting row counts and storage statistics"
curl -fsS "${ES_ENDPOINT}/${ES_INDEX}/_count" | python3 -c '
import json
import sys
from pathlib import Path

payload = json.load(sys.stdin)
Path(sys.argv[1]).write_text("{}\n".format(int(payload.get("count", 0))), encoding="utf-8")
' "${COUNT_FILE}"

curl -fsS "${ES_ENDPOINT}/${ES_INDEX}/_stats/store" | python3 -c '
import json
import sys
from pathlib import Path

index_name = sys.argv[1]
output_path = Path(sys.argv[2])
payload = json.load(sys.stdin)
indices = payload.get("indices", {})
index_payload = indices.get(index_name, {})
size_in_bytes = index_payload.get("total", {}).get("store", {}).get("size_in_bytes", 0)
output_path.write_text("{}\n".format(int(size_in_bytes)), encoding="utf-8")
' "${ES_INDEX}" "${TOTAL_SIZE_FILE}"
benchmark_log "elastic" "Stage 3/6 stats complete rows=$(tr -d '\n' < "${COUNT_FILE}") total_size=$(tr -d '\n' < "${TOTAL_SIZE_FILE}")"

if [ -z "${QUERY_CONTEXT_FILE}" ] && [ -n "${DATA_DIR}" ]; then
    QUERY_CONTEXT_FILE="$(default_query_context_file "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
fi
benchmark_log "elastic" "Stage 4/6 resolving query context"
if [ -n "${QUERY_CONTEXT_FILE}" ]; then
    python3 "${ROOT_DIR}/agentlogsbench/common/resolve_query_context.py" \
        --data-dir "${DATA_DIR}" \
        --size "${SIZE}" \
        --output-file "${QUERY_CONTEXT_FILE}" >/dev/null
fi

benchmark_log "elastic" "Stage 5/6 running benchmark queries from ${QUERY_FILE}"
TRIES=3 QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE}" QUERY_RESULTS_FILE="${QUERY_RESULTS_FILE}" ES_ENDPOINT="${ES_ENDPOINT}" bash "${SCRIPT_DIR}/run_queries.sh" "${ES_INDEX}" "${QUERY_FILE}" > "${RUNTIME_FILE}"
benchmark_log "elastic" "Stage 5/6 query timing saved to ${RUNTIME_FILE}"

ENGINE_VERSION="$(
    curl -fsS "${ES_ENDPOINT}/" | python3 -c '
import json
import sys

payload = json.loads(sys.stdin.read())
print(payload.get("version", {}).get("number", "unknown"))
'
)"
benchmark_log "elastic" "Stage 6/6 building result JSON"
json_args=(
    --system "Elasticsearch"
    --version "${ENGINE_VERSION}"
    --os "${OS_LABEL}"
    --date "${RUN_DATE}"
    --machine "${MACHINE_LABEL}"
    --dataset-size "$(dataset_row_count "${SIZE}")"
    --runtime-file "${RUNTIME_FILE}"
    --count-file "${COUNT_FILE}"
    --total-size-file "${TOTAL_SIZE_FILE}"
    --load-time-file "${LOAD_TIME_FILE}"
    --output-file "${RESULT_JSON}"
)
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")
fi
python3 "${ROOT_DIR}/agentlogsbench/common/build_jsonbench_result.py" "${json_args[@]}"

rm -rf "${ARTIFACT_DIR}"
benchmark_log "elastic" "Benchmark complete result_json=${RESULT_JSON} query_results=${QUERY_RESULTS_FILE}"
