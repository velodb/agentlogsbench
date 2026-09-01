#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from agentlogsbench.tooling.engines import engine_queries_file
from agentlogsbench.tooling.paths import query_suite_path
from agentlogsbench.tooling.query_loader import load_query_sql
from agentlogsbench.tooling.query_results import build_sql_capture_query, render_sql_result_section


CONTEXT_KEYS = (
    "tenant",
    "app",
    "trace_id",
    "release_ring",
    "customer_tier",
    "traffic_cluster",
    "request_key",
    "workflow_variant",
    "start_date",
    "end_date",
)


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def resolve_mysql_bin() -> str:
    configured = os.environ.get("MO_MYSQL_BIN", "")
    if configured:
        return configured
    resolved = shutil.which("mysql")
    if resolved:
        return resolved
    raise RuntimeError("mysql client was not found; set MO_MYSQL_BIN or add mysql to PATH")


def mysql_command(args: argparse.Namespace, sql: str, *, with_column_names: bool) -> list[str]:
    command = [
        args.mysql_bin,
        "--protocol=TCP",
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--user",
        args.user,
        "--database",
        args.db,
        "--batch",
        "--default-character-set=utf8mb4",
    ]
    if not with_column_names:
        command.append("--skip-column-names")
    command.extend(["--execute", sql])
    return command


def mysql_environment() -> dict[str, str]:
    environment = os.environ.copy()
    if "MO_PASSWORD" in environment:
        environment["MYSQL_PWD"] = environment["MO_PASSWORD"]
    return environment


def run_sql(args: argparse.Namespace, sql: str, *, with_column_names: bool = False) -> str:
    try:
        process = subprocess.run(
            mysql_command(args, sql, with_column_names=with_column_names),
            check=False,
            capture_output=True,
            text=True,
            env=mysql_environment(),
            timeout=args.timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise TimeoutError(f"MatrixOne query timed out after {args.timeout}s") from exc
    if process.returncode != 0:
        message = process.stderr.strip() or process.stdout.strip() or f"mysql exited with {process.returncode}"
        raise RuntimeError(message)
    return process.stdout


def clear_os_cache() -> None:
    subprocess.run(["sync"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cache_path = Path("/proc/sys/vm/drop_caches")
    try:
        if os.access(cache_path, os.W_OK):
            cache_path.write_text("3\n", encoding="ascii")
            return
    except OSError:
        pass

    sudo = shutil.which("sudo")
    if sudo:
        subprocess.run(
            [sudo, "-n", "tee", str(cache_path)],
            input="3\n",
            text=True,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def load_context(args: argparse.Namespace, root: Path) -> dict[str, str]:
    if args.context_file and args.context_file.is_file():
        payload = json.loads(args.context_file.read_text(encoding="utf-8"))
        return {key: str(payload[key]) for key in CONTEXT_KEYS}

    table = args.table
    identity_sql = f"""
SELECT
    tenant,
    app,
    trace_id,
    payload ->> '$.attr.release_ring',
    payload ->> '$.attr.customer_tier',
    payload ->> '$.attr.traffic_cluster',
    payload ->> '$.attr.request_key',
    payload ->> '$.attr.workflow_variant'
FROM `{table}`
WHERE payload ->> '$.attr.release_ring' IS NOT NULL
  AND payload ->> '$.attr.customer_tier' IS NOT NULL
  AND payload ->> '$.attr.traffic_cluster' IS NOT NULL
  AND payload ->> '$.attr.request_key' IS NOT NULL
  AND payload ->> '$.attr.workflow_variant' IS NOT NULL
ORDER BY biz_date ASC, trace_id ASC, seq_no ASC, observation_id ASC
LIMIT 1
"""
    identity = run_sql(args, identity_sql).strip().splitlines()
    if not identity or not identity[0]:
        raise RuntimeError(f"Could not resolve MatrixOne query context from {args.db}.{table}")
    values = identity[0].split("\t")
    if len(values) != 8:
        raise RuntimeError(f"MatrixOne returned an invalid query context row: {identity[0]}")

    date_sql = f"SELECT MIN(biz_date), MAX(biz_date) FROM `{table}`"
    date_values = run_sql(args, date_sql).strip().splitlines()[0].split("\t")
    if len(date_values) != 2 or not all(date_values):
        raise RuntimeError(f"Could not resolve MatrixOne date range from {args.db}.{table}")
    return dict(zip(CONTEXT_KEYS, values + date_values))


def bind_query(query_sql: str, params: dict[str, str], table: str) -> str:
    rendered = query_sql.strip()
    if rendered.endswith(";"):
        rendered = rendered[:-1]
    replacements = {
        "__MO_TABLE__": f"`{table}`",
        "__TENANT__": sql_quote(params["tenant"]),
        "__APP__": sql_quote(params["app"]),
        "__TRACE_ID__": sql_quote(params["trace_id"]),
        "__RELEASE_RING__": sql_quote(params["release_ring"]),
        "__CUSTOMER_TIER__": sql_quote(params["customer_tier"]),
        "__TRAFFIC_CLUSTER__": sql_quote(params["traffic_cluster"]),
        "__REQUEST_KEY__": sql_quote(params["request_key"]),
        "__WORKFLOW_VARIANT__": sql_quote(params["workflow_variant"]),
        "__START_DATE__": sql_quote(params["start_date"]),
        "__END_DATE__": sql_quote(params["end_date"]),
    }
    for marker, value in replacements.items():
        rendered = rendered.replace(marker, value)
    return rendered


def query_definitions(root: Path) -> list[dict[str, Any]]:
    suite = json.loads(query_suite_path(root).read_text(encoding="utf-8"))
    return list(suite["queries"])


def write_failure_log(path: Path, log_lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(log_lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the AgentLogsBench SQL workload on MatrixOne.")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--db", required=True)
    parser.add_argument("--table", default="agent_observations")
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--query-file", type=Path, default=None)
    parser.add_argument("--context-file", default="")
    parser.add_argument("--out-file", type=Path, required=True)
    parser.add_argument("--result-file", type=Path, default=None)
    parser.add_argument("--query-results-file", default="")
    parser.add_argument("--tries", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("MO_QUERY_TIMEOUT", "900")))
    parser.add_argument("--mysql-bin", default=resolve_mysql_bin())
    args = parser.parse_args()

    if args.tries < 1:
        raise SystemExit("--tries must be positive")
    if args.timeout < 1:
        raise SystemExit("--timeout must be positive")
    if not args.table or not args.table.replace("_", "a").isalnum() or not (args.table[0].isalpha() or args.table[0] == "_"):
        raise SystemExit(f"unsafe MatrixOne table name: {args.table}")

    args.context_file = Path(args.context_file) if args.context_file else None
    args.query_results_file = Path(args.query_results_file) if args.query_results_file else None
    root = args.root.resolve()
    query_file = args.query_file or engine_queries_file(root, "matrixone")
    context_file = args.context_file
    args.context_file = context_file

    params = load_context(args, root)
    definitions = query_definitions(root)
    log_lines: list[str] = []
    query_summaries: list[dict[str, Any]] = []
    result_sections: list[str] = []

    if args.query_results_file is not None:
        args.query_results_file.parent.mkdir(parents=True, exist_ok=True)

    try:
        for query_number, definition in enumerate(definitions, start=1):
            query_id = definition["id"]
            query_sql = bind_query(load_query_sql(query_file, definition["canonical_sql_section"]), params, args.table)
            log_lines.extend([f"{query_id}\n", f"{query_sql}\n"])
            print(
                f"[matrixone] Query {query_number}/{len(definitions)} ({query_id}): clearing file system cache",
                file=sys.stderr,
                flush=True,
            )
            clear_os_cache()
            print(
                f"[matrixone] Query {query_number}/{len(definitions)} ({query_id}): executing timed runs",
                file=sys.stderr,
                flush=True,
            )

            run_sql(args, query_sql)
            runs: list[float] = []
            for try_index in range(1, args.tries + 1):
                print(
                    f"[matrixone] Query {query_number}/{len(definitions)} ({query_id}): try {try_index}/{args.tries}",
                    file=sys.stderr,
                    flush=True,
                )
                started = time.perf_counter()
                run_sql(args, query_sql)
                elapsed = round(time.perf_counter() - started, 3)
                runs.append(elapsed)
                print(f"Response time: {elapsed:.3f} s")

            log_lines.append(f"latency_seconds_runs={runs}\n\n")
            query_summaries.append({"query_id": query_id, "status": "ok", "latency_seconds_runs": runs})

            if args.query_results_file is not None:
                capture_sql = build_sql_capture_query(query_id, query_sql)
                captured = run_sql(args, capture_sql, with_column_names=True)
                result_sections.append(render_sql_result_section(query_id, captured, with_header=True))

    except Exception as exc:  # noqa: BLE001 - preserve the failing SQL in the runtime log
        log_lines.append(f"ERROR: {exc}\n\n")
        write_failure_log(args.out_file, log_lines)
        raise

    write_failure_log(args.out_file, log_lines)
    if args.query_results_file is not None:
        args.query_results_file.write_text("".join(result_sections), encoding="utf-8")

    if args.result_file is not None:
        args.result_file.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "engine": "matrixone",
            "database": args.db,
            "table": args.table,
            "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "query_results": query_summaries,
        }
        args.result_file.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
