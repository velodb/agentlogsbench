#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CALLER_DIR="$(pwd)"
cd "${ROOT_DIR}"

DB_PATH="${DB_PATH:-${SCRIPT_DIR}/runtime/agentlogsbench.duckdb}"
DUCKDB_TABLE="${DUCKDB_TABLE:-agent_observations}"
DATA_GLOB="${DATA_GLOB:-${ROOT_DIR}/agentlogsbench/common/generated/small/agent_observations_s.ndjson}"
CREATE_SQL="${CREATE_SQL:-${SCRIPT_DIR}/create.sql}"

if [[ "${DATA_GLOB}" != /* ]]; then
    DATA_GLOB="${CALLER_DIR}/${DATA_GLOB}"
fi

shopt -s nullglob
files=( ${DATA_GLOB} )
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
    echo "No files matched DATA_GLOB=${DATA_GLOB}" >&2
    exit 1
fi

python3 - "${DB_PATH}" "${DUCKDB_TABLE}" "${CREATE_SQL}" "${files[@]}" <<'PY'
from __future__ import annotations

from datetime import datetime
import os
from pathlib import Path
import sys

import duckdb


def log(message: str) -> None:
    print(
        f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [duckdb] {message}",
        file=sys.stderr,
        flush=True,
    )


def render_create_sql(create_sql_path: Path, table_name: str) -> str:
    return create_sql_path.read_text(encoding="utf-8").replace("__DUCKDB_TABLE__", table_name)


def execute_statements(conn: duckdb.DuckDBPyConnection, sql_text: str) -> None:
    for statement in sql_text.split(";"):
        statement = statement.strip()
        if statement:
            conn.execute(statement)


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def sql_string_list(values: list[str]) -> str:
    return "[" + ",".join(sql_literal(value) for value in values) + "]"


def default_memory_limit() -> str:
    page_size = os.sysconf("SC_PAGE_SIZE")
    phys_pages = os.sysconf("SC_PHYS_PAGES")
    limit_bytes = max(int(page_size * phys_pages * 0.7), 512 * 1024 * 1024)
    gib = limit_bytes // (1024 ** 3)
    if gib >= 1:
        return f"{gib}GiB"
    mib = max(limit_bytes // (1024 ** 2), 512)
    return f"{mib}MiB"


def column_spec_sql() -> str:
    return """{
        event_time: 'TIMESTAMP',
        biz_date: 'DATE',
        trace_id: 'VARCHAR',
        session_id: 'VARCHAR',
        observation_id: 'VARCHAR',
        parent_observation_id: 'VARCHAR',
        seq_no: 'INTEGER',
        type: 'VARCHAR',
        status: 'VARCHAR',
        app: 'VARCHAR',
        environment: 'VARCHAR',
        task_category: 'VARCHAR',
        trace_archetype: 'VARCHAR',
        model: 'VARCHAR',
        tool_name: 'VARCHAR',
        input: 'VARCHAR',
        output: 'VARCHAR',
        input_tokens: 'BIGINT',
        output_tokens: 'BIGINT',
        total_cost: 'DOUBLE',
        latency_ms: 'INTEGER',
        tenant: 'VARCHAR',
        payload: 'JSON'
    }"""


def import_sql(table_name: str, files: list[str], maximum_object_size: int) -> str:
    return f"""
        INSERT INTO {table_name}
        SELECT
            event_time,
            biz_date,
            trace_id,
            session_id,
            observation_id,
            parent_observation_id,
            seq_no,
            type,
            status,
            app,
            environment,
            task_category,
            trace_archetype,
            model,
            tool_name,
            input,
            output,
            input_tokens,
            output_tokens,
            total_cost,
            latency_ms,
            tenant,
            payload::VARIANT AS payload
        FROM read_ndjson(
            {sql_string_list(files)},
            auto_detect=false,
            records=true,
            ignore_errors=false,
            maximum_object_size={maximum_object_size},
            columns={column_spec_sql()}
        )
    """


db_path = Path(sys.argv[1])
table = sys.argv[2]
create_sql_path = Path(sys.argv[3])
files = [str(Path(item).resolve()) for item in sys.argv[4:]]

maximum_object_size = int(os.environ.get("DUCKDB_MAXIMUM_OBJECT_SIZE", "1048576000"))
defer_checkpoint = os.environ.get("DUCKDB_DEFER_CHECKPOINT", "1").lower() in {"1", "true", "yes"}
wal_autocheckpoint = os.environ.get("DUCKDB_WAL_AUTOCHECKPOINT", "1 TiB")
memory_limit = os.environ.get("DUCKDB_MEMORY_LIMIT", default_memory_limit())

db_path.parent.mkdir(parents=True, exist_ok=True)
if db_path.exists():
    db_path.unlink()
wal_path = db_path.with_suffix(db_path.suffix + ".wal")
if wal_path.exists():
    wal_path.unlink()

con = duckdb.connect(str(db_path), config={"storage_compatibility_version": "latest"})
con.execute("PRAGMA threads=1")
con.execute(f"SET wal_autocheckpoint='{wal_autocheckpoint}'")
con.execute(f"SET memory_limit='{memory_limit}'")
if defer_checkpoint:
    con.execute("PRAGMA disable_checkpoint_on_shutdown")
execute_statements(con, render_create_sql(create_sql_path, table))
file_batches = [[file_path] for file_path in files]
log(
    f"Importing {len(files)} file(s) in {len(file_batches)} serial file batch(es) with explicit DuckDB JSON schema, "
    f"threads=1, batch_files=1, memory_limit={memory_limit}, "
    f"defer_checkpoint={'yes' if defer_checkpoint else 'no'}"
)

try:
    for batch_index, batch_files in enumerate(file_batches, start=1):
        log(
            f"Import batch {batch_index}/{len(file_batches)}: "
            f"{', '.join(Path(path).name for path in batch_files)}"
        )
        con.execute(import_sql(table, batch_files, maximum_object_size))
finally:
    con.close()
PY
