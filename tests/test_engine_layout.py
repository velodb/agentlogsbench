from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from agentlogsbench.tooling.engines import ENGINE_SURFACE_FILES, RUNNABLE_ENGINES


class EngineLayoutTest(unittest.TestCase):
    def test_runnable_engines_expose_declared_surfaces(self) -> None:
        root = Path(__file__).resolve().parents[1]

        for engine in RUNNABLE_ENGINES:
            engine_dir = root / engine
            for relative_path in ENGINE_SURFACE_FILES[engine]:
                self.assertTrue(
                    (engine_dir / relative_path).exists(),
                    msg=f"{engine} is missing {relative_path}",
                )

    def test_root_runner_uses_download_and_common_dataset_prep(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = (root / "benchmark.sh").read_text(encoding="utf-8")
        benchmark_lib = (root / "common" / "benchmark_lib.sh").read_text(encoding="utf-8")

        self.assertIn("prepare_external_observation_dataset.py", script)
        self.assertIn("--size", script)
        self.assertIn("default_download_dir", script)
        self.assertIn("dataset_download_files", script)
        self.assertIn('echo "${root_dir}/common/downloads"', benchmark_lib)
        self.assertIn('echo "${root_dir}/common/context/query_context_${size}.json"', benchmark_lib)
        self.assertNotIn('common/downloads/${size}', benchmark_lib)
        self.assertIn("bash benchmark.sh <command> [options]", script)
        self.assertNotIn("bash agentlogsbench/benchmark.sh <command> [options]", script)

    def test_run_all_collects_failed_engines_without_summary_copy_phase(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = (root / "benchmark.sh").read_text(encoding="utf-8")

        self.assertIn('run-all failed engines:', script)
        self.assertNotIn('run-all missing result files:', script)
        self.assertNotIn("common/results/", script)

    def test_root_runner_can_refresh_dashboard_payload(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = (root / "benchmark.sh").read_text(encoding="utf-8")

        self.assertIn("render-dashboard [--output FILE]", script)
        self.assertIn("render_dashboard_command()", script)
        self.assertIn("generate-results.sh", script)
        self.assertIn("Dashboard data refreshed", script)

    def test_benchmark_lanes_accept_environment_data_and_runtime_paths(self) -> None:
        root = Path(__file__).resolve().parents[1]
        root_script = (root / "benchmark.sh").read_text(encoding="utf-8")

        self.assertIn('DATA_DIR="${DATA_DIR:-}"', root_script)
        self.assertIn('DATA_GLOB="${DATA_GLOB:-}"', root_script)
        self.assertIn("--data-glob", root_script)
        self.assertNotIn('RUNTIME_DIR=""', root_script)

        for engine in RUNNABLE_ENGINES:
            benchmark_script = (root / engine / "benchmark.sh").read_text(encoding="utf-8")
            self.assertIn('DATA_DIR="${DATA_DIR:-}"', benchmark_script, msg=engine)
            self.assertIn('DATA_GLOB="${DATA_GLOB:-}"', benchmark_script, msg=engine)
            self.assertIn('RUNTIME_DIR="${RUNTIME_DIR:-', benchmark_script, msg=engine)

    def test_clickhouse_duckdb_and_postgres_manifests_reference_benchmark_surface(self) -> None:
        root = Path(__file__).resolve().parents[1]
        clickhouse_manifest = (root / "common" / "adapters" / "clickhouse" / "manifest.json").read_text(encoding="utf-8")
        duckdb_manifest = (root / "common" / "adapters" / "duckdb" / "manifest.json").read_text(encoding="utf-8")
        postgres_manifest = (root / "common" / "adapters" / "postgres" / "manifest.json").read_text(encoding="utf-8")

        self.assertIn("clickhouse/benchmark.sh", clickhouse_manifest)
        self.assertIn("clickhouse/results/", clickhouse_manifest)
        self.assertIn("duckdb/benchmark.sh", duckdb_manifest)
        self.assertIn("duckdb/results/", duckdb_manifest)
        self.assertIn("postgres/benchmark.sh", postgres_manifest)
        self.assertIn("postgres/results/", postgres_manifest)

    def test_clickhouse_and_postgres_lanes_do_not_require_sibling_openclaw_repo(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script_paths = (
            root / "clickhouse" / "install.sh",
            root / "clickhouse" / "deploy.sh",
            root / "clickhouse" / "import.sh",
            root / "postgres" / "install.sh",
            root / "postgres" / "deploy.sh",
            root / "postgres" / "import.sh",
            root / "postgres" / "query.sh",
            root / "postgres" / "cleanup.sh",
            root / "clickhouse" / "query_runner.py",
        )

        for path in script_paths:
            self.assertNotIn("openclaw/", path.read_text(encoding="utf-8"), msg=f"{path} still depends on openclaw/")

    def test_clickhouse_phrase_queries_use_supported_text_index_pattern(self) -> None:
        root = Path(__file__).resolve().parents[1]
        content = (root / "clickhouse" / "queries.sql").read_text(encoding="utf-8")

        self.assertNotIn("hasPhrase(", content)
        self.assertIn("positionCaseInsensitiveUTF8(", content)
        self.assertIn("enable_full_text_index = 1", content)
        self.assertIn("query_plan_direct_read_from_text_index = 1", content)

    def test_doris_single_tablet_import_requires_random_bucketing(self) -> None:
        root = Path(__file__).resolve().parents[1]
        create_sql = (root / "doris" / "create.sql").read_text(encoding="utf-8")
        import_script = (root / "doris" / "import.sh").read_text(encoding="utf-8")

        self.assertNotIn("DISTRIBUTED BY RANDOM", create_sql)
        self.assertNotIn("DISTRIBUTED BY HASH(", create_sql)
        self.assertIn('-H "load_to_single_tablet: true"', import_script)

    def test_postgres_import_defers_index_build_until_after_copy(self) -> None:
        root = Path(__file__).resolve().parents[1]
        create_sql = (root / "postgres" / "create.sql").read_text(encoding="utf-8")
        import_script = (root / "postgres" / "import.sh").read_text(encoding="utf-8")
        deploy_script = (root / "postgres" / "deploy.sh").read_text(encoding="utf-8")
        benchmark_script = (root / "postgres" / "benchmark.sh").read_text(encoding="utf-8")
        start_script = (root / "postgres" / "start.sh").read_text(encoding="utf-8")
        runtime_env = (root / "postgres" / "runtime_env.sh").read_text(encoding="utf-8")

        self.assertIn("-- AIBENCH_PRELOAD_SCHEMA", create_sql)
        self.assertIn("-- AIBENCH_POSTLOAD_SCHEMA", create_sql)
        self.assertIn("CREATE TABLE", create_sql)
        self.assertNotIn("CREATE UNLOGGED TABLE", create_sql)
        self.assertNotIn("PARTITION BY LIST", create_sql)
        self.assertNotIn("partition_bucket", create_sql)
        self.assertNotIn("__PG_PARTITIONS__", create_sql)
        self.assertIn("idx___PG_TABLE___observation_id", create_sql)
        self.assertIn("idx___PG_TABLE___payload_gin", create_sql)
        self.assertIn("jsonb_path_ops", create_sql)
        self.assertIn("copy_commit_rows", import_script)
        self.assertNotIn("PG_LOAD_WORKERS", import_script)
        self.assertNotIn("PG_LOAD_PARTITIONS", import_script)
        self.assertNotIn("multiprocessing", import_script)
        self.assertNotIn("partition_bucket(", import_script)
        self.assertNotIn("render_partition_sql", import_script)
        self.assertIn("maintenance_work_mem", import_script)
        self.assertIn("copy_expert", import_script)
        self.assertIn("pigz", import_script)
        self.assertIn('files=( ${DATA_GLOB} )', import_script)
        self.assertIn('"${files[@]}"', import_script)
        self.assertNotIn("ThreadPoolExecutor", import_script)
        self.assertIn("PG_SKIP_FTS_INDEX", import_script)
        self.assertIn("PG_DEFER_POSTLOAD_INDEXES", import_script)
        self.assertNotIn("raw_stage", import_script)
        self.assertIn("resolve_pg_port()", runtime_env)
        self.assertIn("tcp_port_in_use()", runtime_env)
        self.assertIn('PG_PORT="$(resolve_pg_port "${PG_PORT:-}")"', start_script)
        self.assertIn("default_pg_shared_buffers()", deploy_script)
        self.assertIn("default_pg_effective_cache_size()", deploy_script)
        self.assertIn("default_pg_maintenance_work_mem()", deploy_script)
        self.assertIn('PG_PORT="$(resolve_pg_port "${PG_PORT:-}")"', deploy_script)
        self.assertIn('tcp_port_in_use "${PG_PORT}"', deploy_script)
        self.assertIn("tail -n 80", deploy_script)
        self.assertIn("fsync = off", deploy_script)
        self.assertIn("wal_level = minimal", deploy_script)
        self.assertIn("max_wal_senders = 0", deploy_script)
        self.assertIn('PG_PORT="$(resolve_pg_port "${PG_PORT:-}")"', benchmark_script)
        self.assertIn("--fast-ingest", benchmark_script)
        self.assertIn("PG_DEFERRED_SCHEMA_FILE", benchmark_script)
        self.assertIn("PG_DEFER_POSTLOAD_INDEXES", benchmark_script)
        self.assertIn("_failed_runtime_logs", benchmark_script)

    def test_duckdb_import_uses_explicit_json_schema_and_deferred_checkpoint(self) -> None:
        root = Path(__file__).resolve().parents[1]
        create_sql = (root / "duckdb" / "create.sql").read_text(encoding="utf-8")
        import_script = (root / "duckdb" / "import.sh").read_text(encoding="utf-8")
        benchmark_script = (root / "duckdb" / "benchmark.sh").read_text(encoding="utf-8")

        self.assertIn("payload VARIANT NOT NULL", create_sql)
        self.assertIn('CREATE_SQL="${CREATE_SQL:-${SCRIPT_DIR}/create.sql}"', import_script)
        self.assertNotIn("DUCKDB_IMPORT_THREADS", import_script)
        self.assertNotIn("DUCKDB_IMPORT_BATCH_FILES", import_script)
        self.assertIn("DUCKDB_WAL_AUTOCHECKPOINT", import_script)
        self.assertIn("DUCKDB_DEFER_CHECKPOINT", import_script)
        self.assertIn("auto_detect=false", import_script)
        self.assertIn("payload: 'JSON'", import_script)
        self.assertIn("payload::VARIANT AS payload", import_script)
        self.assertIn("read_ndjson(", import_script)
        self.assertIn("columns={column_spec_sql()}", import_script)
        self.assertIn("maximum_object_size", import_script)
        self.assertIn('con.execute("PRAGMA threads=1")', import_script)
        self.assertIn("serial file batch", import_script)
        self.assertIn('con.execute("PRAGMA disable_checkpoint_on_shutdown")', import_script)
        self.assertNotIn("split_gzip_file", import_script)
        self.assertNotIn("pigz", import_script)
        self.assertIn('if wal_path.exists() and wal_path.stat().st_size > 0:', benchmark_script)
        self.assertIn('con.execute("CHECKPOINT")', benchmark_script)
        self.assertNotIn('duckdb.connect(str(db_path), read_only=True)', benchmark_script)
        self.assertIn('CALLER_DIR="$(pwd)"', benchmark_script)
        self.assertIn('DATA_DIR="${CALLER_DIR}/${DATA_DIR}"', benchmark_script)
        self.assertIn('DATA_GLOB="${CALLER_DIR}/${DATA_GLOB}"', benchmark_script)
        self.assertIn('CALLER_DIR="$(pwd)"', import_script)
        self.assertIn('DATA_GLOB="${CALLER_DIR}/${DATA_GLOB}"', import_script)

    def test_json_search_import_uses_auto_generated_ids_for_serial_bulk_load(self) -> None:
        root = Path(__file__).resolve().parents[1]
        for engine in ("elastic", "opensearch"):
            import_script = (root / engine / "import.sh").read_text(encoding="utf-8")
            create_json = (root / engine / "create.json").read_text(encoding="utf-8")

            self.assertIn('files=( ${DATA_GLOB} )', import_script, msg=engine)
            self.assertIn('"${files[@]}"', import_script, msg=engine)
            self.assertIn('{"index":{}}', import_script, msg=engine)
            self.assertNotIn('"_id"', import_script, msg=engine)
            self.assertIn("filter_path=errors,items.*.error", import_script, msg=engine)
            self.assertIn("serial bulk uploads", import_script, msg=engine)
            self.assertIn("post_bulk(bytes(bulk))", import_script, msg=engine)
            self.assertNotIn("ThreadPoolExecutor", import_script, msg=engine)
            self.assertNotIn("BULK_WORKERS", import_script, msg=engine)
            self.assertIn("pigz", import_script, msg=engine)
            self.assertIn('"translog.durability": "async"', create_json, msg=engine)

        elastic_create = (root / "elastic" / "create.json").read_text(encoding="utf-8")
        self.assertIn('"agentlog_simple"', elastic_create)
        self.assertIn('"search_analyzer": "agentlog_simple"', elastic_create)

    def test_json_search_cleanup_and_deploy_use_runtime_scoped_pid_and_dynamic_heap(self) -> None:
        root = Path(__file__).resolve().parents[1]
        elastic_cleanup = (root / "elastic" / "cleanup.sh").read_text(encoding="utf-8")
        elastic_deploy = (root / "elastic" / "deploy.sh").read_text(encoding="utf-8")
        opensearch_cleanup = (root / "opensearch" / "cleanup.sh").read_text(encoding="utf-8")
        opensearch_deploy = (root / "opensearch" / "deploy.sh").read_text(encoding="utf-8")

        self.assertIn('ES_PID_FILE="${ES_PID_FILE:-${RUNTIME_DIR}/elasticsearch.pid}"', elastic_cleanup)
        self.assertNotIn('ES_PID_FILE="${ES_PID_FILE:-${SCRIPT_DIR}/runtime/elasticsearch.pid}"', elastic_cleanup)
        self.assertIn("default_es_heap_mb()", elastic_deploy)
        self.assertIn('ES_HEAP_MB="${ES_HEAP_MB:-$(default_es_heap_mb)}"', elastic_deploy)
        self.assertIn('ES_JAVA_OPTS="${ES_JAVA_OPTS:--Xms${ES_HEAP_MB}m -Xmx${ES_HEAP_MB}m}"', elastic_deploy)

        self.assertIn('OS_PID_FILE="${OS_PID_FILE:-${RUNTIME_DIR}/opensearch.pid}"', opensearch_cleanup)
        self.assertNotIn('OS_PID_FILE="${OS_PID_FILE:-${SCRIPT_DIR}/runtime/opensearch.pid}"', opensearch_cleanup)
        self.assertIn("default_os_heap_mb()", opensearch_deploy)
        self.assertIn('OS_HEAP_MB="${OS_HEAP_MB:-$(default_os_heap_mb)}"', opensearch_deploy)
        self.assertIn('OS_JAVA_OPTS="${OS_JAVA_OPTS:--Xms${OS_HEAP_MB}m -Xmx${OS_HEAP_MB}m}"', opensearch_deploy)
        self.assertIn("plugins.security.disabled: true", opensearch_deploy)

    def test_json_search_run_queries_uses_local_queries_surface(self) -> None:
        root = Path(__file__).resolve().parents[1]
        for engine in ("elastic", "opensearch"):
            queries = (root / engine / "queries.json").read_text(encoding="utf-8")
            run_queries = (root / engine / "run_queries.sh").read_text(encoding="utf-8")

            self.assertIn('"id": "Q01"', queries, msg=engine)
            self.assertIn('"id": "Q20"', queries, msg=engine)
            self.assertIn("__TENANT__", queries, msg=engine)
            self.assertIn("__TRACE_ID__", queries, msg=engine)
            self.assertIn("__RELEASE_RING__", queries, msg=engine)
            self.assertIn("__REQUEST_KEY__", queries, msg=engine)
            self.assertIn("replace_placeholders", run_queries, msg=engine)
            self.assertIn("queries.json", run_queries, msg=engine)
            self.assertIn("fielddata=true&query=true&request=true", run_queries, msg=engine)

        elastic_run_queries = (root / "elastic" / "run_queries.sh").read_text(encoding="utf-8")
        elastic_execute_query = (root / "elastic" / "execute_query.py").read_text(encoding="utf-8")
        opensearch_run_queries = (root / "opensearch" / "run_queries.sh").read_text(encoding="utf-8")
        opensearch_execute_query = (root / "opensearch" / "execute_query.py").read_text(encoding="utf-8")

        self.assertIn("execute_query.py", elastic_run_queries)
        self.assertIn("request_cache=false", elastic_execute_query)
        self.assertIn("execute_query.py", opensearch_run_queries)
        self.assertIn("request_cache=false", opensearch_execute_query)
        self.assertIn("Could not resolve Elasticsearch query context from", elastic_run_queries)
        self.assertIn("Could not resolve OpenSearch query context from", opensearch_run_queries)
        self.assertIn('"_source": ["tenant", "app", "trace_id", "payload"]', elastic_run_queries)

    def test_text_index_tokenizers_match_log_semantics(self) -> None:
        root = Path(__file__).resolve().parents[1]
        clickhouse_create = (root / "clickhouse" / "create.sql").read_text(encoding="utf-8")
        doris_create = (root / "doris" / "create.sql").read_text(encoding="utf-8")

        self.assertIn("tokenizer = 'splitByNonAlpha'", clickhouse_create)
        self.assertIn('"char_filter_pattern" = "._"', doris_create)
        self.assertIn('"char_filter_replacement" = " "', doris_create)

    def test_doris_deploy_waits_for_probe_table_readiness(self) -> None:
        root = Path(__file__).resolve().parents[1]
        deploy_script = (root / "doris" / "deploy.sh").read_text(encoding="utf-8")

        self.assertIn("__agentlogsbench_deploy_probe__", deploy_script)
        self.assertIn("DISTRIBUTED BY RANDOM BUCKETS 1", deploy_script)
        self.assertIn("CREATE DATABASE IF NOT EXISTS", deploy_script)

    def test_jsonbench_style_runtime_surfaces_exist(self) -> None:
        root = Path(__file__).resolve().parents[1]
        expected_paths = (
            root / "clickhouse" / "run_queries.sh",
            root / "clickhouse" / "queries.sql",
            root / "doris" / "run_queries.sh",
            root / "doris" / "queries.sql",
            root / "duckdb" / "run_queries.sh",
            root / "duckdb" / "queries.sql",
            root / "postgres" / "run_queries.sh",
            root / "postgres" / "queries.sql",
            root / "elastic" / "run_queries.sh",
            root / "elastic" / "queries.json",
            root / "opensearch" / "run_queries.sh",
            root / "opensearch" / "queries.json",
        )

        for path in expected_paths:
            self.assertTrue(path.exists(), msg=str(path))


if __name__ == "__main__":
    unittest.main()
