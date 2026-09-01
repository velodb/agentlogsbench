from __future__ import annotations

from pathlib import Path
from typing import Dict, Iterable, List, Tuple


RUNNABLE_ENGINES = ("clickhouse", "doris", "duckdb", "elastic", "matrixone", "opensearch", "postgres")
ENGINE_SURFACE_FILES: Dict[str, Tuple[str, ...]] = {
    "clickhouse": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.sql", "queries.sql", "README.md"),
    "doris": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.sql", "queries.sql", "README.md"),
    "duckdb": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.sql", "queries.sql", "README.md"),
    "elastic": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.json", "queries.json", "README.md"),
    "matrixone": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.sql", "queries.sql", "README.md"),
    "opensearch": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.json", "queries.json", "README.md"),
    "postgres": ("benchmark.sh", "run_queries.sh", "start.sh", "stop.sh", "create.sql", "queries.sql", "README.md"),
}
LEGACY_RESULTS_DIRNAME = "result"
CLICKBENCH_RESULTS_DIRNAME = "results"


def engine_dir(root: Path, engine: str) -> Path:
    return root / engine


def engine_results_dir(root: Path, engine: str) -> Path:
    return engine_dir(root, engine) / CLICKBENCH_RESULTS_DIRNAME


def legacy_engine_results_dir(root: Path, engine: str) -> Path:
    return engine_dir(root, engine) / LEGACY_RESULTS_DIRNAME


def engine_queries_file(root: Path, engine: str) -> Path:
    if engine in {"elastic", "opensearch"}:
        return engine_dir(root, engine) / "queries.json"
    return engine_dir(root, engine) / "queries.sql"


def runnable_engine_commands(root: Path) -> List[str]:
    engines: List[str] = []
    for engine in RUNNABLE_ENGINES:
        if (engine_dir(root, engine) / "benchmark.sh").exists():
            engines.append(engine)
    return engines


def iter_engine_surface_paths(root: Path, engine: str) -> Iterable[Path]:
    base = engine_dir(root, engine)
    for relative_path in ENGINE_SURFACE_FILES.get(engine, ("benchmark.sh", "start.sh", "stop.sh")):
        yield base / relative_path
