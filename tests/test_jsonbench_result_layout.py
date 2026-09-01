from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class JsonBenchResultLayoutTest(unittest.TestCase):
    def test_build_jsonbench_result_records_embedded_sidecars_and_query_results(self) -> None:
        root = Path(__file__).resolve().parents[1]

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            artifact_dir = temp_root / "runtime" / "result_artifacts"
            results_dir = temp_root / "results"
            query_results_dir = results_dir / "_query_results"
            artifact_dir.mkdir(parents=True, exist_ok=True)
            query_results_dir.mkdir(parents=True, exist_ok=True)

            runtime_file = artifact_dir / "demo.results_runtime"
            count_file = artifact_dir / "demo.count"
            total_size_file = artifact_dir / "demo.total_size"
            data_size_file = artifact_dir / "demo.data_size"
            index_size_file = artifact_dir / "demo.index_size"
            load_time_file = artifact_dir / "demo.load_time"
            output_file = results_dir / "demo.json"
            query_results_file = query_results_dir / "_demo.query_results"

            runtime_file.write_text(
                "\n".join(
                    [
                        "Response time: 0.100 s",
                        "Response time: 0.110 s",
                        "Response time: 0.120 s",
                        "Response time: 0.200 s",
                        "Response time: 0.210 s",
                        "Response time: 0.220 s",
                        "",
                    ]
                ),
                encoding="utf-8",
            )
            count_file.write_text("42\n", encoding="utf-8")
            total_size_file.write_text("2048\n", encoding="utf-8")
            data_size_file.write_text("1536\n", encoding="utf-8")
            index_size_file.write_text("512\n", encoding="utf-8")
            load_time_file.write_text("12.3456\n", encoding="utf-8")
            query_results_file.write_text("Q01\nok\n", encoding="utf-8")

            subprocess.run(
                [
                    "python3",
                    str(root / "common" / "build_jsonbench_result.py"),
                    "--system",
                    "ClickHouse",
                    "--version",
                    "25.1",
                    "--os",
                    "Ubuntu",
                    "--date",
                    "2026-04-15",
                    "--machine",
                    "m6i.8xlarge",
                    "--dataset-size",
                    "1000000",
                    "--tries",
                    "3",
                    "--runtime-file",
                    str(runtime_file),
                    "--count-file",
                    str(count_file),
                    "--total-size-file",
                    str(total_size_file),
                    "--data-size-file",
                    str(data_size_file),
                    "--index-size-file",
                    str(index_size_file),
                    "--load-time-file",
                    str(load_time_file),
                    "--query-results-file",
                    str(query_results_file),
                    "--output-file",
                    str(output_file),
                ],
                check=True,
            )

            rendered = output_file.read_text(encoding="utf-8")
            payload = json.loads(rendered)

        self.assertEqual(payload["num_loaded_documents"], 42)
        self.assertEqual(payload["total_size"], 2048)
        self.assertEqual(payload["data_size"], 1536)
        self.assertEqual(payload["index_size"], 512)
        self.assertEqual(payload["load_time"], 12.346)
        self.assertEqual(payload["result"], [[0.1, 0.11, 0.12], [0.2, 0.21, 0.22]])
        self.assertIn('"result": [\n    [0.1, 0.11, 0.12],\n    [0.2, 0.21, 0.22]\n  ]', rendered)
        self.assertEqual(payload["artifact_manifest"]["query_results"]["path"], "_query_results/_demo.query_results")

        embedded = {
            item["field"]: item
            for item in payload["artifact_manifest"]["embedded_sidecars"]
        }
        self.assertEqual(embedded["num_loaded_documents"]["name"], "demo.count")
        self.assertEqual(embedded["num_loaded_documents"]["value"], 42)
        self.assertEqual(embedded["total_size"]["name"], "demo.total_size")
        self.assertEqual(embedded["data_size"]["name"], "demo.data_size")
        self.assertEqual(embedded["index_size"]["name"], "demo.index_size")
        self.assertEqual(embedded["load_time"]["name"], "demo.load_time")
        self.assertEqual(embedded["load_time"]["value"], 12.346)
        self.assertEqual(embedded["result"]["name"], "demo.results_runtime")
        self.assertEqual(embedded["result"]["rows"], 2)
        self.assertEqual(embedded["result"]["tries"], 3)

    def test_engine_benchmark_scripts_stage_metric_files_outside_results_dir(self) -> None:
        root = Path(__file__).resolve().parents[1]
        expected_artifact_vars = {
            "clickhouse": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "DATA_SIZE_FILE",
                "INDEX_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "doris": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "DATA_SIZE_FILE",
                "INDEX_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "duckdb": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "DATA_SIZE_FILE",
                "INDEX_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "matrixone": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "DATA_SIZE_FILE",
                "INDEX_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "postgres": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "DATA_SIZE_FILE",
                "INDEX_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "elastic": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "RUNTIME_FILE",
            ),
            "opensearch": (
                "LOAD_TIME_FILE",
                "COUNT_FILE",
                "TOTAL_SIZE_FILE",
                "RUNTIME_FILE",
            ),
        }

        for engine, variables in expected_artifact_vars.items():
            content = (root / engine / "benchmark.sh").read_text(encoding="utf-8")
            self.assertIn('QUERY_RESULTS_DIR="${RESULT_DIR}/_query_results"', content)
            self.assertIn('if [ "${SIZE}" = "1m" ]; then', content)
            self.assertIn('ARTIFACT_DIR="${RUNTIME_DIR}/result_artifacts"', content)
            self.assertIn('rm -rf "${ARTIFACT_DIR}"', content)
            self.assertIn('json_args+=(--query-results-file "${QUERY_RESULTS_FILE}")', content)
            for variable in variables:
                self.assertIn(f'{variable}="${{ARTIFACT_DIR}}/', content, msg=f"{engine} should stage {variable} in ARTIFACT_DIR")
                self.assertNotIn(f'{variable}="${{RESULT_DIR}}/', content, msg=f"{engine} should not stage {variable} in RESULT_DIR")

    def test_readmes_describe_results_dir_as_json_plus_query_results_only(self) -> None:
        root = Path(__file__).resolve().parents[1]
        readme = (root / "README.md").read_text(encoding="utf-8")

        self.assertIn("keeps only the final `*.json` plus `_query_results/`", readme)
        self.assertIn("artifact_manifest", readme)
        self.assertNotIn("Result sidecars such as", readme)

        for engine in ("clickhouse", "doris", "duckdb", "matrixone", "postgres", "elastic", "opensearch"):
            content = (root / engine / "README.md").read_text(encoding="utf-8")
            self.assertIn("fold temporary metric files into the final JSON", content)


if __name__ == "__main__":
    unittest.main()
