from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


class EngineQuerySqlTest(unittest.TestCase):
    def test_engine_sql_files_do_not_use_placeholder_macros(self) -> None:
        root = Path(__file__).resolve().parents[1]
        query_files = (
            root / "clickhouse" / "queries.sql",
            root / "postgres" / "queries.sql",
            root / "doris" / "queries.sql",
            root / "matrixone" / "queries.sql",
        )
        forbidden_fragments = (
            ":tenant",
            ":app",
            ":trace_id",
            ":start_date",
            ":end_date",
            "TEXT_HAS_TOKEN(",
            "TEXT_TOKEN_SCORE(",
            "TEXT_HAS_PHRASE(",
            "JSON_VALUE(",
        )

        for path in query_files:
            content = path.read_text(encoding="utf-8")
            for fragment in forbidden_fragments:
                self.assertNotIn(fragment, content, msg=f"{path} still contains {fragment}")


if __name__ == "__main__":
    unittest.main()
