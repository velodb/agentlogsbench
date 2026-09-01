from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

from agentlogsbench.tooling.engines import RUNNABLE_ENGINES, engine_queries_file, iter_engine_surface_paths
from agentlogsbench.tooling.paths import (
    adapter_manifest_path,
    adapters_dir,
    benchmark_root as locate_benchmark_root,
    canonical_queries_path,
    data_generation_path,
    edition_path,
    queries_dir,
    query_suite_path,
)
from agentlogsbench.tooling.query_loader import load_query_sections

REQUIRED_ENGINES = {"clickhouse", "doris", "duckdb", "elastic", "matrixone", "opensearch", "postgres"}
REQUIRED_QUERY_IDS = {f"Q{i:02d}" for i in range(1, 21)}
EXPECTED_QUERY_COUNT = 20
EXPECTED_PROMOTED_COLUMNS = [
    "event_time",
    "biz_date",
    "trace_id",
    "session_id",
    "observation_id",
    "parent_observation_id",
    "seq_no",
    "type",
    "status",
    "tenant",
    "app",
    "environment",
    "task_category",
    "trace_archetype",
    "model",
    "tool_name",
    "input",
    "output",
    "input_tokens",
    "output_tokens",
    "total_cost",
    "latency_ms",
]
REQUIRED_PRESERVE_FLAGS = (
    "trace_first_generation",
    "observation_chain_coherence",
    "mixed_observation_types",
    "sparse_keyword_injection",
    "hard_negatives",
    "tenant_app_long_tail",
    "controlled_text_size_buckets",
    "attr_coverage",
)
REQUIRED_QUERY_MAP_FIELDS = ("query_id", "adapter_mode", "information_access_pattern")
SQL_TEXT_QUERY_CONTRACTS = {
    "Q05": {
        "required_markers": ("'unable'", "'open'"),
        "forbidden_markers": (
            "'sqlite'",
            "'workspace'",
            "'db'",
            "'.db'",
            "'unable to open'",
            "payload_text",
            "tool_result.stderr",
            "{tool_result,stderr}",
        ),
    },
    "Q08": {
        "required_markers": ("'unable'", "'open'", "'unable to open'"),
        "forbidden_markers": (
            "'sqlite'",
            "'workspace'",
            "'db'",
            "'.db'",
            "payload_text",
            "tool_result.stderr",
            "{tool_result,stderr}",
        ),
    },
    "Q11": {
        "required_markers": ("'unable'", "'open'", "'unable to open'"),
        "forbidden_markers": (
            "'sqlite'",
            "'workspace'",
            "'db'",
            "'.db'",
            "payload_text",
            "tool_result.stderr",
            "{tool_result,stderr}",
        ),
    },
}
JSON_SEARCH_TEXT_QUERY_CONTRACTS = {
    "Q05": {
        "required_markers": ('"unable open"',),
        "forbidden_markers": ('"unable to open"', '"sqlite"', '"workspace"', '".db"', '"payload.tool_result.stderr"'),
    },
    "Q08": {
        "required_markers": ('"unable open"', '"unable to open"'),
        "forbidden_markers": ('"sqlite"', '"workspace"', '".db"', '"payload.tool_result.stderr"'),
    },
    "Q11": {
        "required_markers": ('"unable open"', '"unable to open"'),
        "forbidden_markers": ('"sqlite"', '"workspace"', '".db"', '"payload.tool_result.stderr"'),
    },
}


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def benchmark_root(start: Path | None = None) -> Path:
    return locate_benchmark_root(start)


def load_main_track_query_ids(root: Path) -> List[str]:
    edition = load_json(edition_path(root))
    return list(edition["main_track"]["query_ids"])


def load_query_suite(root: Path) -> Dict[str, Any]:
    return load_json(query_suite_path(root))


def load_contracts(root: Path) -> Dict[str, Any]:
    suite = load_query_suite(root)
    contracts_rel = suite.get("expected_result_contracts_file", "")
    if not contracts_rel:
        raise FileNotFoundError("query-suite missing expected_result_contracts_file")
    return load_json(root.parent / contracts_rel)


def load_adapter_query_map(root: Path, manifest: Dict[str, Any]) -> Dict[str, Any]:
    source = manifest.get("query_map_source")
    if not source:
        raise FileNotFoundError(f"{manifest.get('engine', 'unknown')} manifest missing query_map_source")
    return load_json(root.parent / source)


def validate_sql_text_query_contract(
    surface_name: str,
    query_sections: Dict[str, str],
    errors: List[str],
) -> None:
    for query_id, contract in SQL_TEXT_QUERY_CONTRACTS.items():
        section = query_sections.get(query_id)
        if not section:
            errors.append(f"{surface_name} missing text-retrieval query section {query_id}")
            continue
        for marker in contract["required_markers"]:
            if marker not in section:
                errors.append(f"{surface_name} {query_id} must include marker {marker}")
        for marker in contract["forbidden_markers"]:
            if marker in section:
                errors.append(f"{surface_name} {query_id} must not include legacy marker {marker}")


def validate_json_search_text_query_contract(root: Path, engine: str, errors: List[str]) -> None:
    query_path = root / engine / "queries.json"
    if not query_path.exists():
        errors.append(f"{engine} queries.json missing")
        return

    payload = load_json(query_path)
    queries = {entry.get("id"): entry.get("body", {}) for entry in payload.get("queries", [])}
    for query_id, contract in JSON_SEARCH_TEXT_QUERY_CONTRACTS.items():
        body = queries.get(query_id)
        if body is None:
            errors.append(f"{engine} queries.json missing text-retrieval query {query_id}")
            continue
        body_text = json.dumps(body, ensure_ascii=False, sort_keys=True)
        for marker in contract["required_markers"]:
            if marker not in body_text:
                errors.append(f"{engine} queries.json {query_id} must include marker {marker}")
        for marker in contract["forbidden_markers"]:
            if marker in body_text:
                errors.append(f"{engine} queries.json {query_id} must not include legacy marker {marker}")


def validate_text_search_surface_fairness(root: Path, errors: List[str]) -> None:
    forbidden_markers_by_path = {
        root / "doris" / "create.sql": ("payload_text",),
        root / "doris" / "import.sh": ("payload_text",),
        adapter_manifest_path(root, "doris"): ("payload_text",),
        root / "clickhouse" / "create.sql": ("payload.tool_result.stderr",),
        adapter_manifest_path(root, "clickhouse"): ("payload.tool_result.stderr",),
        root / "postgres" / "create.sql": ("{tool_result,stderr}",),
        adapter_manifest_path(root, "postgres"): ("payload.tool_result.stderr",),
        root / "elastic" / "query_runner.py": ("payload.tool_result.stderr",),
        root / "opensearch" / "query_runner.py": ("payload.tool_result.stderr",),
    }
    for path, markers in forbidden_markers_by_path.items():
        if not path.exists():
            errors.append(f"missing file: {path}")
            continue
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker in text:
                errors.append(f"{path.relative_to(root)} must not contain hidden text-search helper {marker}")


def validate_edition(root: Path) -> Dict[str, Any]:
    root = root.resolve()
    errors: List[str] = []
    warnings: List[str] = []

    edition_path_value = edition_path(root)
    generation_path = data_generation_path(root)
    suite_path = query_suite_path(root)

    for path in (edition_path_value, generation_path, suite_path):
        if not path.exists():
            errors.append(f"missing file: {path}")
    if errors:
        return {"ok": False, "errors": errors, "warnings": warnings}

    edition = load_json(edition_path_value)
    generation = load_json(generation_path)
    suite = load_query_suite(root)
    contracts_rel = suite.get("expected_result_contracts_file", "")
    contracts_path = root.parent / contracts_rel
    if not contracts_rel or not contracts_path.exists():
        errors.append(f"missing expected result contracts file: {contracts_rel}")
        contracts = {"contracts": {}}
    else:
        contracts = load_json(contracts_path)

    if edition.get("dynamic_column") != "payload":
        errors.append("edition.dynamic_column must be 'payload'")

    if edition.get("table_name") != "agent_observations":
        errors.append("edition.table_name must be 'agent_observations'")

    promoted = edition.get("promoted_columns", [])
    if promoted != EXPECTED_PROMOTED_COLUMNS:
        errors.append("edition.promoted_columns must match the observation allowlist")

    protocol = edition.get("execution_protocol", {})
    if protocol.get("main_leaderboard_tier") != "M":
        errors.append("execution_protocol.main_leaderboard_tier must be 'M'")
    if protocol.get("measured_runs") != 5:
        errors.append("execution_protocol.measured_runs must be 5")
    if protocol.get("warmup_runs") != 1:
        errors.append("execution_protocol.warmup_runs must be 1")
    if protocol.get("concurrency") != 1:
        errors.append("execution_protocol.concurrency must be 1")

    tiers = generation.get("tiers", {})
    if set(tiers.keys()) != {"S", "M", "L"}:
        errors.append("data-generation tiers must define exactly S, M, and L")
    for tier_name, tier in tiers.items():
        if "raw_call_rows" in tier:
            errors.append(f"data-generation tier {tier_name} must not export raw_call_rows")
        if "generation_rows" not in tier:
            errors.append(f"data-generation tier {tier_name} missing generation_rows")
    preserve = generation.get("preserve", {})
    for key in REQUIRED_PRESERVE_FLAGS:
        if preserve.get(key) is not True:
            errors.append(f"data-generation preserve flag must be true: {key}")
    if not generation.get("trace_archetypes"):
        errors.append("data-generation trace_archetypes must not be empty")

    queries = suite.get("queries", [])
    query_ids = {entry.get("id") for entry in queries}
    if query_ids != REQUIRED_QUERY_IDS:
        errors.append("query-suite must define exactly Q01-Q20")

    if suite.get("query_count") != EXPECTED_QUERY_COUNT:
        errors.append(f"query-suite.query_count must be {EXPECTED_QUERY_COUNT}")

    categories = {entry.get("category") for entry in queries}
    required_categories = {"retrieval", "analytics", "semi_structured"}
    missing_categories = required_categories - categories
    if missing_categories:
        errors.append(f"query-suite missing required categories: {sorted(missing_categories)}")

    contract_entries = contracts.get("contracts", {})
    for entry in queries:
        sql_file = entry.get("canonical_sql_file")
        if not sql_file:
            errors.append(f"{entry.get('id')} missing canonical_sql_file")
            continue
        sql_path = root.parent / sql_file
        if not sql_path.exists():
            errors.append(f"missing canonical SQL file: {sql_file}")
        section = entry.get("canonical_sql_section")
        if not section:
            errors.append(f"{entry.get('id')} missing canonical_sql_section")
        elif sql_path.exists():
            sections = load_query_sections(sql_path)
            if section not in sections:
                errors.append(f"{entry.get('id')} canonical SQL section not found: {section}")
        contract_id = entry.get("expected_result_contract_id")
        if not contract_id:
            errors.append(f"{entry.get('id')} missing expected_result_contract_id")
        elif contract_id not in contract_entries:
            errors.append(f"{entry.get('id')} missing expected result contract entry")
        else:
            contract = contract_entries[contract_id]
            if "fixture_dataset" not in contract:
                errors.append(f"{entry.get('id')} contract missing fixture_dataset")
            if "assertions" not in contract:
                errors.append(f"{entry.get('id')} contract missing assertions")

    manifests = list(adapters_dir(root).glob("*/manifest.json"))
    engines_found = set()
    canonical_query_sections = load_query_sections(canonical_queries_path(root))
    validate_sql_text_query_contract("common/queries/queries.sql", canonical_query_sections, errors)
    for manifest_path in manifests:
        manifest = load_json(manifest_path)
        engine = manifest.get("engine")
        if not engine:
            errors.append(f"manifest missing engine: {manifest_path}")
            continue
        engines_found.add(engine)
        supported = set(manifest.get("main_track_supported_query_ids", []))
        if supported != REQUIRED_QUERY_IDS:
            errors.append(f"{engine} manifest must declare support for Q01-Q20")
        if manifest.get("logical_surface") != "single-primary-surface":
            errors.append(f"{engine} manifest must use logical_surface=single-primary-surface")
        if not manifest.get("dynamic_representation"):
            errors.append(f"{engine} manifest missing dynamic_representation")
        if manifest.get("manifest_version") != 1:
            errors.append(f"{engine} manifest_version must be 1")
        if manifest.get("promoted_columns_confirmed") != EXPECTED_PROMOTED_COLUMNS:
            errors.append(f"{engine} manifest must confirm the observation promoted-column allowlist")
        schema = manifest.get("declared_schema", {})
        if schema.get("dynamic_column") != "payload":
            errors.append(f"{engine} manifest must declare dynamic_column=payload")
        if manifest.get("table_name") != "agent_observations":
            errors.append(f"{engine} manifest table_name must be agent_observations")
        proof = manifest.get("primary_surface_proof", {})
        if proof.get("secondary_scored_tables") != []:
            errors.append(f"{engine} manifest must declare no secondary scored tables")
        source = manifest.get("query_map_source")
        if not source:
            errors.append(f"{engine} manifest missing query_map_source")
        else:
            source_path = root.parent / source
            if not source_path.exists():
                errors.append(f"{engine} manifest query_map_source does not exist: {source}")
            else:
                query_map = load_json(source_path)
                if query_map.get("engine") != engine:
                    errors.append(f"{engine} query-map engine must match manifest engine")
                if not isinstance(query_map.get("adapter_version"), int):
                    errors.append(f"{engine} query-map adapter_version must be an integer")
                mapped_queries = query_map.get("queries", [])
                mapped_ids = {entry.get("query_id") for entry in mapped_queries}
                if mapped_ids != REQUIRED_QUERY_IDS:
                    errors.append(f"{engine} query-map must define exactly Q01-Q20")
                for query_entry in mapped_queries:
                    for field in REQUIRED_QUERY_MAP_FIELDS:
                        if not query_entry.get(field):
                            errors.append(f"{engine} query-map entry missing {field}: {query_entry}")
    for engine in RUNNABLE_ENGINES:
        for surface_path in iter_engine_surface_paths(root, engine):
            if not surface_path.exists():
                errors.append(f"{engine} missing runnable surface: {surface_path.relative_to(root)}")
        runnable_queries = engine_queries_file(root, engine)
        if runnable_queries.exists() and runnable_queries.suffix == ".sql":
            runnable_sections = load_query_sections(runnable_queries)
            if set(runnable_sections.keys()) != set(canonical_query_sections.keys()):
                errors.append(f"{engine} queries.sql must define the same query sections as common/queries/queries.sql")
            validate_sql_text_query_contract(f"{engine} queries.sql", runnable_sections, errors)

    for engine in ("elastic", "opensearch"):
        validate_json_search_text_query_contract(root, engine, errors)
    validate_text_search_surface_fairness(root, errors)

    missing_engines = REQUIRED_ENGINES - engines_found
    if missing_engines:
        errors.append(f"missing adapter manifests for: {', '.join(sorted(missing_engines))}")

    fairness = edition.get("fairness", {})
    if fairness.get("allow_extra_promoted_columns") is not False:
        errors.append("fairness.allow_extra_promoted_columns must be false")
    if fairness.get("allow_hidden_payload_flattening") is not False:
        errors.append("fairness.allow_hidden_payload_flattening must be false")

    return {
        "ok": not errors,
        "errors": errors,
        "warnings": warnings,
    }
