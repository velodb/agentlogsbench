from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from agentlogsbench.tooling.engines import RUNNABLE_ENGINES, engine_results_dir
from agentlogsbench.tooling.query_loader import load_query_sections


CANONICAL_DATASET_SIZES = {
    1_000_000: "1M",
    10_000_000: "10M",
    100_000_000: "100M",
}

ENGINE_DEFAULT_TAGS = {
    "clickhouse": ["sql", "column-oriented", "full-text", "semi-structured"],
    "doris": ["sql", "column-oriented", "full-text", "semi-structured"],
    "elastic": ["search", "document", "full-text", "semi-structured"],
    "matrixone": ["sql", "semi-structured"],
    "opensearch": ["search", "document", "full-text", "semi-structured"],
    "postgres": ["sql", "row-oriented", "full-text", "semi-structured"],
}

REQUIRED_RESULT_TRIES = 3
GITHUB_BLOB_BASE_URL = "https://github.com/velodb/agentlogsbench/blob/main"


def format_dataset_size_label(dataset_size: int) -> str:
    if dataset_size in CANONICAL_DATASET_SIZES:
        return CANONICAL_DATASET_SIZES[dataset_size]
    if dataset_size >= 1_000_000 and dataset_size % 1_000_000 == 0:
        return f"{dataset_size // 1_000_000}M"
    if dataset_size >= 1_000 and dataset_size % 1_000 == 0:
        return f"{dataset_size // 1_000}K"
    return str(dataset_size)


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_query_catalog(root: Path) -> list[dict[str, Any]]:
    suite_path = root / "common" / "queries" / "query-suite.json"
    query_sql_path = root / "common" / "queries" / "queries.sql"
    suite = read_json(suite_path)
    sections = load_query_sections(query_sql_path)

    queries: list[dict[str, Any]] = []
    for entry in suite.get("queries", []):
        if not entry.get("main_track"):
            continue
        query_id = entry["id"]
        queries.append(
            {
                "id": query_id,
                "title": entry["title"],
                "category": entry["category"],
                "contract": entry["contract"],
                "sql": sections.get(query_id, ""),
            }
        )
    return queries


def iter_dashboard_result_files(root: Path) -> list[Path]:
    result_files: list[Path] = []
    for engine in RUNNABLE_ENGINES:
        results_dir = engine_results_dir(root, engine)
        if not results_dir.exists():
            continue
        result_files.extend(sorted(results_dir.glob("*.json")))
    return result_files


def _number_or_none(value: Any) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    return None


def _valid_runtime_matrix(result: Any, query_count: int) -> bool:
    if not isinstance(result, list) or len(result) != query_count:
        return False
    for row in result:
        if not isinstance(row, list) or len(row) != REQUIRED_RESULT_TRIES:
            return False
        if any(value is not None and not isinstance(value, (int, float)) for value in row):
            return False
    return True


def _string_or_default(value: Any, default: str) -> str:
    if isinstance(value, str) and value.strip():
        return value
    return default


def _cluster_size_or_default(value: Any) -> int | str:
    if isinstance(value, bool) or value is None:
        return 1
    if isinstance(value, (int, str)):
        return value
    return 1


def _normalized_tags(engine: str, value: Any) -> list[str]:
    tags = [tag.strip() for tag in value if isinstance(tag, str) and tag.strip()] if isinstance(value, list) else []
    return tags if tags else ENGINE_DEFAULT_TAGS.get(engine, [engine])


def github_blob_url(relative_path: str) -> str:
    return f"{GITHUB_BLOB_BASE_URL}/{relative_path}"


def normalize_dashboard_record(root: Path, path: Path, query_count: int) -> dict[str, Any] | None:
    payload = read_json(path)
    engine = path.parent.parent.name

    dataset_size = _number_or_none(payload.get("dataset_size"))
    if not isinstance(dataset_size, int) or dataset_size not in CANONICAL_DATASET_SIZES:
        return None

    result = payload.get("result")
    if not _valid_runtime_matrix(result, query_count):
        return None

    system = payload.get("system")
    machine = payload.get("machine")
    if not isinstance(system, str) or not system.strip():
        return None
    if not isinstance(machine, str) or not machine.strip():
        return None

    source = path.relative_to(root).as_posix()
    artifact_manifest = payload.get("artifact_manifest", {})
    query_results_relative = artifact_manifest.get("query_results", {}).get("path")
    query_results_source: str | None = None
    if isinstance(query_results_relative, str) and query_results_relative:
        query_results_path = path.parent / query_results_relative
        if query_results_path.exists():
            query_results_source = github_blob_url(query_results_path.relative_to(root).as_posix())

    storage_bytes = _number_or_none(payload.get("total_size"))
    data_size = _number_or_none(payload.get("data_size"))
    if data_size is None:
        data_size = storage_bytes
    index_size = _number_or_none(payload.get("index_size"))
    load_time = _number_or_none(payload.get("load_time"))

    return {
        "engine": engine,
        "system": system,
        "machine": machine,
        "cluster_size": _cluster_size_or_default(payload.get("cluster_size")),
        "date": payload.get("date"),
        "dataset_size": dataset_size,
        "dataset_label": format_dataset_size_label(dataset_size),
        "load_time": load_time,
        "storage_bytes": storage_bytes,
        "data_size": data_size,
        "index_size": index_size,
        "num_loaded_documents": _number_or_none(payload.get("num_loaded_documents")),
        "retains_structure": payload.get("retains_structure"),
        "proprietary": _string_or_default(payload.get("proprietary"), "no"),
        "hardware": _string_or_default(payload.get("hardware"), "cpu"),
        "tuned": _string_or_default(payload.get("tuned"), "no"),
        "comment": _string_or_default(payload.get("comment"), ""),
        "tags": _normalized_tags(engine, payload.get("tags")),
        "version": payload.get("version"),
        "os": payload.get("os"),
        "result": result,
        "source": github_blob_url(source),
        "query_results_source": query_results_source,
    }


def build_dashboard_payload(root: Path) -> dict[str, Any]:
    queries = load_query_catalog(root)
    results = []
    for path in iter_dashboard_result_files(root):
        normalized = normalize_dashboard_record(root, path, len(queries))
        if normalized is not None:
            results.append(normalized)

    results.sort(
        key=lambda item: (
            item["dataset_size"],
            item["system"].casefold(),
            item["machine"].casefold(),
            item["source"],
        )
    )

    dataset_sizes = sorted({item["dataset_size"] for item in results})
    return {
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "dataset_sizes": [
            {"value": dataset_size, "label": format_dataset_size_label(dataset_size)}
            for dataset_size in dataset_sizes
        ],
        "queries": queries,
        "results": results,
    }


def _render_js_assignment(name: str, value: Any) -> str:
    rendered = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return f"const {name} = {rendered};\n"


def _render_data_array(results: list[dict[str, Any]]) -> str:
    lines = ["const data = ["]
    for index, entry in enumerate(results):
        prefix = "" if index == 0 else ","
        lines.append(f"{prefix}{json.dumps(entry, ensure_ascii=False, separators=(',', ':'))}")
    lines.append("];")
    return "\n".join(lines) + "\n"


def render_dashboard_js(payload: dict[str, Any]) -> str:
    return (
        "// Generated by agentlogsbench/common/render_dashboard.py.\n"
        "// Do not edit this file directly.\n"
        f"// Generated at {payload['generated_at']}.\n"
        + _render_js_assignment("queryCatalog", payload["queries"])
        + _render_js_assignment("datasetSizes", payload["dataset_sizes"])
        + _render_data_array(payload["results"])
    )
