#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"
source "${ROOT_DIR}/agentlogsbench/common/benchmark_lib.sh"

MO_EXPECTED_ROWS="${MO_EXPECTED_ROWS:-auto}"
DATA_GLOB="${DATA_GLOB:-${ROOT_DIR}/agentlogsbench/common/generated/small/agent_observations_s.ndjson}"
CREATE_SQL="${CREATE_SQL:-${SCRIPT_DIR}/create.sql}"

if [ "${MO_EXPECTED_ROWS}" != "auto" ] && [[ ! "${MO_EXPECTED_ROWS}" =~ ^[0-9]+$ ]]; then
    echo "MO_EXPECTED_ROWS must be auto or a non-negative integer: ${MO_EXPECTED_ROWS}" >&2
    exit 1
fi

shopt -s nullglob
files=( ${DATA_GLOB} )
shopt -u nullglob
if [ "${#files[@]}" -eq 0 ]; then
    echo "No files matched DATA_GLOB=${DATA_GLOB}" >&2
    exit 1
fi
for index in "${!files[@]}"; do
    if [[ "${files[${index}]}" != /* ]]; then
        files[${index}]="$(cd "$(dirname "${files[${index}]}")" && pwd)/$(basename "${files[${index}]}")"
    fi
done

if [ "${MO_EXPECTED_ROWS}" = "auto" ]; then
    MO_EXPECTED_ROWS=0
    for file in "${files[@]}"; do
        if [[ "${file}" == *.gz || "${file}" == *.gzip ]]; then
            file_rows="$(gzip -cd -- "${file}" | wc -l)"
        else
            file_rows="$(wc -l < "${file}")"
        fi
        MO_EXPECTED_ROWS=$((MO_EXPECTED_ROWS + file_rows))
    done
    echo "[matrixone] source row-count expectation: ${MO_EXPECTED_ROWS} (MO_EXPECTED_ROWS=auto)" >&2
fi

matrixone_require_client
matrixone_validate_identifier MO_DB "${MO_DB}"
matrixone_validate_identifier MO_TABLE "${MO_TABLE}"
matrixone_validate_identifier MO_STAGE_TABLE "${MO_STAGE_TABLE}"

matrixone_mysql -e "CREATE DATABASE IF NOT EXISTS \`${MO_DB}\`;"

table_exists="$(matrixone_mysql -N -B -e \
    "SHOW TABLES FROM \`${MO_DB}\` LIKE '${MO_TABLE}'" 2>/dev/null || true)"
if [ "${table_exists}" = "${MO_TABLE}" ]; then
    actual_rows="$(matrixone_mysql --database="${MO_DB}" -N -B -e \
        "SELECT COUNT(*) FROM \`${MO_TABLE}\`" | tr -d '[:space:]')"
    if [ "${actual_rows}" = "${MO_EXPECTED_ROWS}" ]; then
        echo "Existing MatrixOne.${MO_DB}.${MO_TABLE} already contains ${actual_rows} rows; skipping reload." >&2
        exit 0
    fi
    if [ "${actual_rows}" != "0" ]; then
        echo "MatrixOne.${MO_DB}.${MO_TABLE} contains ${actual_rows} rows; expected ${MO_EXPECTED_ROWS}. Refusing to drop or reload a non-empty partial table." >&2
        exit 1
    fi
    echo "MatrixOne.${MO_DB}.${MO_TABLE} exists but is empty; recreating it before loading." >&2
fi

schema_sql="$(sed "s/__MO_TABLE__/${MO_TABLE}/g" "${CREATE_SQL}")"
matrixone_mysql --database="${MO_DB}" -e "${schema_sql}"

matrixone_mysql --database="${MO_DB}" -e \
    "DROP TABLE IF EXISTS \`${MO_STAGE_TABLE}\`; CREATE TABLE \`${MO_STAGE_TABLE}\` (raw_data JSON NOT NULL);"

temporary_dir=""
if [ "${MO_LOAD_MODE}" = "local" ]; then
    temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentlogsbench-matrixone.XXXXXX")"
    trap 'rm -rf "${temporary_dir}"' EXIT
elif [ "${MO_LOAD_MODE}" != "direct" ]; then
    echo "MO_LOAD_MODE must be direct or local: ${MO_LOAD_MODE}" >&2
    exit 1
fi

load_file() {
    local file="$1"
    local escaped_file
    local load_sql
    escaped_file="$(matrixone_sql_escape "${file}")"

    if [ "${MO_LOAD_MODE}" = "local" ]; then
        local local_file="${file}"
        if [[ "${file}" == *.gz || "${file}" == *.gzip ]]; then
            local_file="${temporary_dir}/$(basename "${file%.gz}")"
            if [[ "${file}" == *.gzip ]]; then
                local_file="${temporary_dir}/$(basename "${file%.gzip}")"
            fi
            gzip -dc "${file}" > "${local_file}"
        fi
        escaped_file="$(matrixone_sql_escape "${local_file}")"
        load_sql="LOAD DATA LOCAL INFILE '${escaped_file}' INTO TABLE \`${MO_STAGE_TABLE}\` FIELDS TERMINATED BY '\\t' ESCAPED BY '' LINES TERMINATED BY '\\n'"
        matrixone_mysql --local-infile=1 --database="${MO_DB}" -e "${load_sql}"
        return
    fi

    if [[ "${file}" == *.gz || "${file}" == *.gzip ]]; then
        load_sql="LOAD DATA INFILE {'filepath'='${escaped_file}', 'compression'='gzip', 'format'='csv'} INTO TABLE \`${MO_STAGE_TABLE}\` FIELDS TERMINATED BY '\\t' ESCAPED BY '' LINES TERMINATED BY '\\n'"
    else
        load_sql="LOAD DATA INFILE {'filepath'='${escaped_file}', 'format'='csv'} INTO TABLE \`${MO_STAGE_TABLE}\` FIELDS TERMINATED BY '\\t' ESCAPED BY '' LINES TERMINATED BY '\\n'"
    fi
    matrixone_mysql --database="${MO_DB}" -e "${load_sql}"
}

for index in "${!files[@]}"; do
    file="${files[${index}]}"
    echo "[matrixone] loading file $((index + 1))/${#files[@]}: ${file}" >&2
    load_file "${file}"
done

matrixone_mysql --database="${MO_DB}" -e "
INSERT INTO \`${MO_TABLE}\` (
    event_time, biz_date, trace_id, session_id, observation_id,
    parent_observation_id, seq_no, type, status, tenant, app, environment,
    task_category, trace_archetype, model, tool_name, input, output,
    input_tokens, output_tokens, total_cost, latency_ms, payload
)
SELECT
    CAST(s.raw_data ->> '\$.event_time' AS DATETIME),
    CAST(s.raw_data ->> '\$.biz_date' AS DATE),
    s.raw_data ->> '\$.trace_id',
    s.raw_data ->> '\$.session_id',
    s.raw_data ->> '\$.observation_id',
    s.raw_data ->> '\$.parent_observation_id',
    CAST(s.raw_data ->> '\$.seq_no' AS INT),
    s.raw_data ->> '\$.type',
    s.raw_data ->> '\$.status',
    s.raw_data ->> '\$.tenant',
    s.raw_data ->> '\$.app',
    s.raw_data ->> '\$.environment',
    s.raw_data ->> '\$.task_category',
    s.raw_data ->> '\$.trace_archetype',
    s.raw_data ->> '\$.model',
    s.raw_data ->> '\$.tool_name',
    s.raw_data ->> '\$.input',
    s.raw_data ->> '\$.output',
    CAST(s.raw_data ->> '\$.input_tokens' AS BIGINT),
    CAST(s.raw_data ->> '\$.output_tokens' AS BIGINT),
    CAST(s.raw_data ->> '\$.total_cost' AS DOUBLE),
    CAST(s.raw_data ->> '\$.latency_ms' AS INT),
    s.raw_data -> '\$.payload'
FROM \`${MO_STAGE_TABLE}\` AS s;
DROP TABLE \`${MO_STAGE_TABLE}\`;
"

actual_rows="$(matrixone_mysql --database="${MO_DB}" -N -B -e \
    "SELECT COUNT(*) FROM \`${MO_TABLE}\`" | tr -d '[:space:]')"
if [ "${actual_rows}" != "${MO_EXPECTED_ROWS}" ]; then
    echo "Expected ${MO_EXPECTED_ROWS} rows, loaded ${actual_rows}" >&2
    exit 1
fi

echo "[matrixone] loaded ${actual_rows} rows into ${MO_DB}.${MO_TABLE}" >&2
sync
