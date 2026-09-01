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
FAST_INGEST=0

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
        --fast-ingest) FAST_INGEST=1 ;;
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
PGDATA="${PGDATA:-${RUNTIME_DIR}/pgdata}"
PG_LOG="${PG_LOG:-${RUNTIME_DIR}/postgres.log}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="$(resolve_pg_port "${PG_PORT:-}")"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-agentlogsbench_pg}"
PG_TABLE="${PG_TABLE:-agent_observations}"
QUERY_FILE="${QUERY_FILE:-${SCRIPT_DIR}/queries.sql}"
DEFERRED_SCHEMA_FILE="${RUNTIME_DIR}/deferred_postload.sql"
RESULT_TAGS="${RESULT_TAGS:-}"
QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE:-}"

if [ "${FAST_INGEST}" -eq 1 ]; then
    if [ -n "${RESULT_TAGS}" ]; then
        RESULT_TAGS="${RESULT_TAGS},fast-ingest"
    else
        RESULT_TAGS="fast-ingest"
    fi
fi

mkdir -p "${RESULT_DIR}"
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    mkdir -p "${QUERY_RESULTS_DIR}"
fi
mkdir -p "${ARTIFACT_DIR}"

cleanup() {
    local status=$?

    if [ "${status}" -ne 0 ] && [ -f "${PG_LOG}" ]; then
        local failure_log_dir="${RESULT_DIR}/_failed_runtime_logs"
        local failure_log_file="${failure_log_dir}/${RESULT_BASE}.postgres.log"

        mkdir -p "${failure_log_dir}"
        cp "${PG_LOG}" "${failure_log_file}" || true
        benchmark_log "postgres" "Preserved failed runtime log at ${failure_log_file}"
    fi

    benchmark_log "postgres" "Cleaning up runtime artifacts in ${RUNTIME_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    PGDATA="${PGDATA}" PG_LOG="${PG_LOG}" RUNTIME_DIR="${RUNTIME_DIR}" RESULT_DIR="${RESULT_DIR}" bash "${SCRIPT_DIR}/stop.sh"
    return "${status}"
}

if [ "${KEEP_RUNTIME}" -ne 1 ]; then
    trap cleanup EXIT
fi

benchmark_log "postgres" "Benchmark start size=${SIZE} data_glob=${DATA_GLOB} result_json=${RESULT_JSON}"
benchmark_log "postgres" "Stage 1/7 starting runtime in ${RUNTIME_DIR}"
PGDATA="${PGDATA}" PG_LOG="${PG_LOG}" RUNTIME_DIR="${RUNTIME_DIR}" bash "${SCRIPT_DIR}/start.sh"

PG_BIN_DIR_RESOLVED="${PG_BIN_DIR:-$(resolve_pg_bin_dir)}"
PSQL_BIN="${PG_BIN_DIR_RESOLVED}/psql"

benchmark_log "postgres" "Stage 2/7 importing data into ${PG_DB}.${PG_TABLE}"
start_ns="$(date +%s%N)"
DATA_GLOB="${DATA_GLOB}" PGDATA="${PGDATA}" PG_LOG="${PG_LOG}" PG_HOST="${PG_HOST}" PG_PORT="${PG_PORT}" PG_USER="${PG_USER}" PG_DB="${PG_DB}" PG_TABLE="${PG_TABLE}" PG_DEFER_POSTLOAD_INDEXES="${FAST_INGEST}" PG_SKIP_FTS_INDEX="${FAST_INGEST}" PG_DEFERRED_SCHEMA_FILE="${DEFERRED_SCHEMA_FILE}" bash "${SCRIPT_DIR}/import.sh"
end_ns="$(date +%s%N)"
awk "BEGIN { printf \"%.3f\n\", (${end_ns} - ${start_ns}) / 1000000000 }" > "${LOAD_TIME_FILE}"
benchmark_log "postgres" "Stage 2/7 import complete load_time=$(cat "${LOAD_TIME_FILE}")s"

if [ -s "${DEFERRED_SCHEMA_FILE}" ]; then
    benchmark_log "postgres" "Stage 3/7 applying deferred post-load DDL from ${DEFERRED_SCHEMA_FILE}"
    "${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -v ON_ERROR_STOP=1 -f "${DEFERRED_SCHEMA_FILE}" >/dev/null
else
    benchmark_log "postgres" "Stage 3/7 no deferred post-load DDL to apply"
fi

benchmark_log "postgres" "Stage 4/7 collecting row counts and storage statistics"
"${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -At -c "SELECT COUNT(*) FROM ${PG_TABLE}" > "${COUNT_FILE}"
"${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -At -c "SELECT pg_total_relation_size('${PG_TABLE}')" > "${TOTAL_SIZE_FILE}"
"${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -At -c "SELECT pg_table_size('${PG_TABLE}')" > "${DATA_SIZE_FILE}"
"${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -At -c "SELECT pg_indexes_size('${PG_TABLE}')" > "${INDEX_SIZE_FILE}"
benchmark_log "postgres" "Stage 4/7 stats complete rows=$(tr -d '\n' < "${COUNT_FILE}") total_size=$(tr -d '\n' < "${TOTAL_SIZE_FILE}")"

if [ -z "${QUERY_CONTEXT_FILE}" ] && [ -n "${DATA_DIR}" ]; then
    QUERY_CONTEXT_FILE="$(default_query_context_file "${ROOT_DIR}/agentlogsbench" "${SIZE}")"
fi
benchmark_log "postgres" "Stage 5/7 resolving query context"
if [ -n "${QUERY_CONTEXT_FILE}" ]; then
    python3 "${ROOT_DIR}/agentlogsbench/common/resolve_query_context.py" \
        --data-dir "${DATA_DIR}" \
        --size "${SIZE}" \
        --output-file "${QUERY_CONTEXT_FILE}" >/dev/null
fi

benchmark_log "postgres" "Stage 6/7 running benchmark queries from ${QUERY_FILE}"
TRIES=3 QUERY_CONTEXT_FILE="${QUERY_CONTEXT_FILE}" QUERY_RESULTS_FILE="${QUERY_RESULTS_FILE}" PG_HOST="${PG_HOST}" PG_PORT="${PG_PORT}" PG_USER="${PG_USER}" bash "${SCRIPT_DIR}/run_queries.sh" "${PG_DB}" "${QUERY_FILE}" > "${RUNTIME_FILE}"
benchmark_log "postgres" "Stage 6/7 query timing saved to ${RUNTIME_FILE}"

ENGINE_VERSION="$("${PSQL_BIN}" -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d "${PG_DB}" -At -c "SHOW server_version")"
benchmark_log "postgres" "Stage 7/7 building result JSON"
json_args=(
    --system "PostgreSQL"
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
    --tags "${RESULT_TAGS}"
    --output-file "${RESULT_JSON}"
)
if [ -n "${QUERY_RESULTS_FILE}" ]; then
    json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")
fi
python3 "${ROOT_DIR}/agentlogsbench/common/build_jsonbench_result.py" "${json_args[@]}"

rm -rf "${ARTIFACT_DIR}"
benchmark_log "postgres" "Benchmark complete result_json=${RESULT_JSON} query_results=${QUERY_RESULTS_FILE}"
