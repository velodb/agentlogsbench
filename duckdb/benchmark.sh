#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CALLER_DIR="$(pwd)"
source "${ROOT_DIR}/agentlogsbench/common/benchmark_lib.sh"
cd "${ROOT_DIR}"

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
    if [[ "${DATA_DIR}" != /* ]]; then
        DATA_DIR="${CALLER_DIR}/${DATA_DIR}"
    fi
    DATA_DIR="$(cd "${DATA_DIR}" && pwd)"
fi
if [ -z "${DATA_GLOB}" ]; then
    if [ -z "${DATA_DIR}" ]; then
        DATA_DIR="$(default_download_dir "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
    fi
    DATA_GLOB="$(dataset_download_files "${DATA_DIR}" "${SIZE}")"
elif [[ "${DATA_GLOB}" != /* ]]; then
    DATA_GLOB="${CALLER_DIR}/${DATA_GLOB}"
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
DB_PATH="${DB_PATH:-${RUNTIME_DIR}/agentlogsbench.duckdb}"
DUCKDB_TABLE="${DUCKDB_TABLE:-agent_observations}"
QUERY_FILE="${QUERY_FILE:-${SCRIPT_DIR}/queries.sql}"
QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE:-}"

mkdir -p "${RESULT_DIR}"
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    mkdir -p "${QUERY_RESULTS_DIR}"
fi
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
    benchmark_log "duckdb" "Cleaning up runtime artifacts in ${RUNTIME_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    RUNTIME_DIR="${RUNTIME_DIR}" bash "${SCRIPT_DIR}/stop.sh"
}

if [ "${KEEP_RUNTIME}" -ne 1 ]; then
    trap cleanup EXIT
fi

benchmark_log "duckdb" "Benchmark start size=${SIZE} data_glob=${DATA_GLOB} result_json=${RESULT_JSON}"
benchmark_log "duckdb" "Stage 1/6 preparing runtime in ${RUNTIME_DIR}"
RUNTIME_DIR="${RUNTIME_DIR}" bash "${SCRIPT_DIR}/start.sh"

benchmark_log "duckdb" "Stage 2/6 importing data into ${DB_PATH}"
start_ns="$(date +%s%N)"
DB_PATH="${DB_PATH}" DUCKDB_TABLE="${DUCKDB_TABLE}" DATA_GLOB="${DATA_GLOB}" bash "${SCRIPT_DIR}/import.sh"
benchmark_log "duckdb" "Stage 2/6 finalizing deferred checkpoint state"
python3 - "${DB_PATH}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import duckdb


db_path = Path(sys.argv[1])
wal_path = db_path.with_suffix(db_path.suffix + ".wal")
if wal_path.exists() and wal_path.stat().st_size > 0:
    con = duckdb.connect(str(db_path))
    con.execute("CHECKPOINT")
    con.close()
PY
end_ns="$(date +%s%N)"
awk "BEGIN { printf \"%.3f\n\", (${end_ns} - ${start_ns}) / 1000000000 }" > "${LOAD_TIME_FILE}"
benchmark_log "duckdb" "Stage 2/6 import complete load_time=$(cat "${LOAD_TIME_FILE}")s"

benchmark_log "duckdb" "Stage 3/6 collecting row counts and storage statistics"
python3 - "${DB_PATH}" "${DUCKDB_TABLE}" "${COUNT_FILE}" "${TOTAL_SIZE_FILE}" "${DATA_SIZE_FILE}" "${INDEX_SIZE_FILE}" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import duckdb


db_path = Path(sys.argv[1])
table = sys.argv[2]
count_file = Path(sys.argv[3])
total_size_file = Path(sys.argv[4])
data_size_file = Path(sys.argv[5])
index_size_file = Path(sys.argv[6])
wal_path = db_path.with_suffix(db_path.suffix + ".wal")

con = duckdb.connect(str(db_path))
count_value = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
con.close()
size_value = db_path.stat().st_size
if wal_path.exists():
    size_value += wal_path.stat().st_size
count_file.write_text(f"{count_value}\n", encoding="utf-8")
total_size_file.write_text(f"{size_value}\n", encoding="utf-8")
data_size_file.write_text(f"{size_value}\n", encoding="utf-8")
index_size_file.write_text("0\n", encoding="utf-8")
PY
benchmark_log "duckdb" "Stage 3/6 stats complete rows=$(tr -d '\n' < "${COUNT_FILE}") total_size=$(tr -d '\n' < "${TOTAL_SIZE_FILE}")"

if [ -z "${QUERY_CONTEXT_FILE}" ] && [ -n "${DATA_DIR}" ]; then
    QUERY_CONTEXT_FILE="$(default_query_context_file "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
fi
benchmark_log "duckdb" "Stage 4/6 resolving query context"
if [ -n "${QUERY_CONTEXT_FILE}" ]; then
    python3 "${ROOT_DIR}/agentlogsbench/common/resolve_query_context.py" \
        --data-dir "${DATA_DIR}" \
        --size "${SIZE}" \
        --output-file "${QUERY_CONTEXT_FILE}" >/dev/null
fi

benchmark_log "duckdb" "Stage 5/6 running benchmark queries from ${QUERY_FILE}"
TRIES=3 QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE}" QUERY_RESULTS_FILE="${QUERY_RESULTS_FILE}" DUCKDB_TABLE="${DUCKDB_TABLE}" bash "${SCRIPT_DIR}/run_queries.sh" "${DB_PATH}" "${QUERY_FILE}" > "${RUNTIME_FILE}"
benchmark_log "duckdb" "Stage 5/6 query timing saved to ${RUNTIME_FILE}"

ENGINE_VERSION="$(python3 - <<'PY'
import duckdb
print(duckdb.__version__)
PY
)"
benchmark_log "duckdb" "Stage 6/6 building result JSON"
json_args=(
    --system "DuckDB"
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
    --output-file "${RESULT_JSON}"
)
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")
fi
python3 "${ROOT_DIR}/agentlogsbench/common/build_jsonbench_result.py" "${json_args[@]}"

rm -rf "${ARTIFACT_DIR}"
benchmark_log "duckdb" "Benchmark complete result_json=${RESULT_JSON} query_results=${QUERY_RESULTS_FILE}"
