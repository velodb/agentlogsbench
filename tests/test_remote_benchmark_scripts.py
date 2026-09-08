from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class DownloadAndRootBenchmarkScriptsTest(unittest.TestCase):
    def test_download_script_uses_size_selector_and_wget(self) -> None:
        root = Path(__file__).resolve().parents[1]
        content = (root / "download.sh").read_text(encoding="utf-8")

        self.assertIn("wget", content)
        self.assertIn("--size 1m|10m|100m", content)
        self.assertIn("resolve_dataset_size", content)
        self.assertIn("dataset_file_count", content)
        self.assertIn('OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/common/downloads}"', content)
        self.assertIn('TARGET_DIR="${OUTPUT_ROOT}"', content)
        self.assertNotIn('TARGET_DIR="${OUTPUT_ROOT}/${SIZE}"', content)
        self.assertIn('S3_BASE_URL="${S3_BASE_URL:-https://s3.us-east-1.amazonaws.com/bench-dataset/agentlogs}"', content)
        self.assertIn("Select the dataset size:", (root / "common" / "benchmark_lib.sh").read_text(encoding="utf-8"))

    def test_proxy_download_script_preserves_and_normalizes_proxy_environment(self) -> None:
        root = Path(__file__).resolve().parents[1]
        content = (root / "download_proxy.sh").read_text(encoding="utf-8")

        self.assertIn("http_proxy", content)
        self.assertIn("https_proxy", content)
        self.assertIn('export HTTPS_PROXY="${HTTP_PROXY_VALUE}"', content)
        self.assertNotIn("--no-proxy", content)
        self.assertNotIn(
            "HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= ALL_PROXY= all_proxy=",
            content,
        )

    def test_root_benchmark_script_runs_size_based_engines_without_download_logic(self) -> None:
        root = Path(__file__).resolve().parents[1]
        content = (root / "benchmark.sh").read_text(encoding="utf-8")

        self.assertIn("prepare_external_observation_dataset.py", content)
        self.assertIn("--size", content)
        self.assertIn("run-engine", content)
        self.assertIn("run-engine", content)
        self.assertIn("dataset_download_files", content)
        self.assertIn("--input-files", content)
        self.assertIn('ENGINES="clickhouse,doris,elastic,matrixone,opensearch,postgres,duckdb"', content)
        self.assertIn('Engine postgres: skipped for run-all size=100m', content)
        self.assertNotIn('bash "${SCRIPT_DIR}/download.sh"', content)
        self.assertNotIn("common/results/", content)
        self.assertIn("Select the dataset size:", (root / "common" / "benchmark_lib.sh").read_text(encoding="utf-8"))

    def test_docs_and_manifests_do_not_reference_legacy_scripts_surface(self) -> None:
        root = Path(__file__).resolve().parents[1]
        paths = (
            root / "README.md",
            root / "AGENTS.md",
            root / "common" / "adapters" / "clickhouse" / "manifest.json",
            root / "common" / "adapters" / "doris" / "manifest.json",
            root / "common" / "adapters" / "elastic" / "manifest.json",
            root / "common" / "adapters" / "opensearch" / "manifest.json",
            root / "common" / "adapters" / "postgres" / "manifest.json",
        )

        for path in paths:
            content = path.read_text(encoding="utf-8")
            self.assertNotIn("agentlogsbench/scripts/", content, msg=f"{path} still references legacy scripts/")
            self.assertNotIn("run.sh", content, msg=f"{path} still references legacy run.sh")

if __name__ == "__main__":
    unittest.main()
