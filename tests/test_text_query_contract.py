from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from agentlogsbench.elastic.query_runner import q05_body, q08_body, q11_body, q13_body, q14_body
from agentlogsbench.tooling.query_loader import load_query_sections


class TextQueryContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[1]

    def test_root_and_canonical_snippets_match(self) -> None:
        root_sections = load_query_sections(self.root / "common" / "queries" / "queries.sql")
        snippet_paths = {
            "Q05": self.root / "common" / "queries" / "canonical" / "q05_tool_failure_triage.sql",
            "Q08": self.root / "common" / "queries" / "canonical" / "q08_structured_text_search.sql",
        }
        for query_id, path in snippet_paths.items():
            self.assertEqual(root_sections[query_id], path.read_text(encoding="utf-8").strip(), msg=query_id)

    def test_sql_query_surfaces_share_unable_open_contract(self) -> None:
        sections_by_surface = {
            "common/queries/queries.sql": load_query_sections(self.root / "common" / "queries" / "queries.sql"),
            "clickhouse/queries.sql": load_query_sections(self.root / "clickhouse" / "queries.sql"),
            "doris/queries.sql": load_query_sections(self.root / "doris" / "queries.sql"),
            "postgres/queries.sql": load_query_sections(self.root / "postgres" / "queries.sql"),
            "matrixone/queries.sql": load_query_sections(self.root / "matrixone" / "queries.sql"),
        }

        for surface_name, sections in sections_by_surface.items():
            q05 = sections["Q05"]
            self.assertIn("'unable'", q05, msg=surface_name)
            self.assertIn("'open'", q05, msg=surface_name)
            self.assertNotIn("'sqlite'", q05, msg=surface_name)
            self.assertNotIn("'unable to open'", q05, msg=surface_name)
            self.assertNotIn("payload_text", q05, msg=surface_name)
            self.assertNotIn("tool_result.stderr", q05, msg=surface_name)
            self.assertNotIn("{tool_result,stderr}", q05, msg=surface_name)

            for query_id in ("Q08", "Q11"):
                section = sections[query_id]
                self.assertIn("'unable'", section, msg=f"{surface_name} {query_id}")
                self.assertIn("'open'", section, msg=f"{surface_name} {query_id}")
                self.assertIn("'unable to open'", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("'sqlite'", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("'workspace'", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("'.db'", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("payload_text", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("tool_result.stderr", section, msg=f"{surface_name} {query_id}")
                self.assertNotIn("{tool_result,stderr}", section, msg=f"{surface_name} {query_id}")

    def test_json_search_query_surfaces_share_unable_open_contract(self) -> None:
        for engine in ("elastic", "opensearch"):
            payload = json.loads((self.root / engine / "queries.json").read_text(encoding="utf-8"))
            queries_by_id = {
                entry["id"]: json.dumps(entry["body"], ensure_ascii=False, sort_keys=True)
                for entry in payload["queries"]
            }

            self.assertIn('"unable open"', queries_by_id["Q05"], msg=engine)
            self.assertNotIn('"unable to open"', queries_by_id["Q05"], msg=engine)
            self.assertNotIn('"payload.tool_result.stderr"', queries_by_id["Q05"], msg=engine)

            for query_id in ("Q08", "Q11"):
                self.assertIn('"unable open"', queries_by_id[query_id], msg=f"{engine} {query_id}")
                self.assertIn('"unable to open"', queries_by_id[query_id], msg=f"{engine} {query_id}")
                self.assertNotIn('"sqlite"', queries_by_id[query_id], msg=f"{engine} {query_id}")
                self.assertNotIn('"workspace"', queries_by_id[query_id], msg=f"{engine} {query_id}")
                self.assertNotIn('".db"', queries_by_id[query_id], msg=f"{engine} {query_id}")
                self.assertNotIn('"payload.tool_result.stderr"', queries_by_id[query_id], msg=f"{engine} {query_id}")

            self.assertIn('"transient"', queries_by_id["Q14"], msg=engine)
            self.assertIn('"output"', queries_by_id["Q14"], msg=engine)
            self.assertNotIn('"input": {"query": "transient"}', queries_by_id["Q14"], msg=engine)
            self.assertIn('"timeout awaiting headers"', queries_by_id["Q13"], msg=engine)
            self.assertIn('"retry budget depleted"', queries_by_id["Q13"], msg=engine)
            self.assertIn('"transient upstream failure"', queries_by_id["Q13"], msg=engine)
            self.assertNotIn('"error timeout retry"', queries_by_id["Q13"], msg=engine)

    def test_elastic_query_builders_match_contract(self) -> None:
        params = {
            "tenant": "tenant_001",
            "app": "app_001",
            "start_date": "2026-03-17",
            "end_date": "2027-03-20",
        }

        q05_body_payload = q05_body(params)
        q05_must = [clause["multi_match"]["query"] for clause in q05_body_payload["query"]["bool"]["must"]]
        self.assertEqual(q05_must, ["unable open"])
        self.assertEqual(q05_body_payload["query"]["bool"]["must"][0]["multi_match"]["fields"], ["input", "output"])
        self.assertEqual(q05_body_payload["size"], 50)
        self.assertEqual(q05_body_payload["sort"], [{"latency_ms": {"order": "desc"}}, {"event_time": {"order": "desc"}}])

        q08_body_payload = q08_body(params)
        q08_must = [clause["multi_match"]["query"] for clause in q08_body_payload["query"]["bool"]["must"]]
        self.assertEqual(q08_must, ["unable open", "unable to open"])
        for clause in q08_body_payload["query"]["bool"]["must"]:
            self.assertEqual(clause["multi_match"]["fields"], ["input", "output"])
        self.assertEqual(q08_body_payload["size"], 50)
        self.assertEqual(
            q08_body_payload["sort"],
            [
                {"event_time": {"order": "desc"}},
                {"trace_id": {"order": "desc"}},
                {"observation_id": {"order": "desc"}},
            ],
        )
        self.assertEqual(sorted(q08_body_payload["highlight"]["fields"].keys()), ["input", "output"])

        q11_body_payload = q11_body(params)
        q11_must = [clause["multi_match"]["query"] for clause in q11_body_payload["query"]["bool"]["must"]]
        self.assertEqual(q11_must, ["unable open", "unable to open"])
        for clause in q11_body_payload["query"]["bool"]["must"]:
            self.assertEqual(clause["multi_match"]["fields"], ["input", "output"])
        self.assertEqual(q11_body_payload["size"], 50)
        self.assertEqual(
            q11_body_payload["sort"],
            [
                {"latency_ms": {"order": "desc"}},
                {"event_time": {"order": "desc"}},
                {"trace_id": {"order": "desc"}},
                {"observation_id": {"order": "desc"}},
            ],
        )

        q13_body_payload = q13_body(params)
        q13_should = q13_body_payload["query"]["bool"]["must"][0]["bool"]["should"]
        self.assertEqual(
            q13_should,
            [
                {"multi_match": {"query": "timeout awaiting headers", "fields": ["input", "output"], "type": "phrase"}},
                {"multi_match": {"query": "retry budget depleted", "fields": ["input", "output"], "type": "phrase"}},
                {"multi_match": {"query": "transient upstream failure", "fields": ["input", "output"], "type": "phrase"}},
            ],
        )

        q14_body_payload = q14_body(params)
        q14_should = q14_body_payload["query"]["bool"]["must"][0]["bool"]["should"]
        self.assertEqual(
            q14_should,
            [
                {"match": {"input": {"query": "deployment"}}},
                {"match": {"output": {"query": "deployment"}}},
                {"match": {"input": {"query": "rollback"}}},
                {"match": {"output": {"query": "rollback"}}},
                {"match": {"output": {"query": "transient"}}},
            ],
        )

    def test_text_search_surfaces_do_not_use_hidden_payload_helpers(self) -> None:
        path_expectations = {
            self.root / "doris" / "create.sql": ["payload_text"],
            self.root / "doris" / "import.sh": ["payload_text"],
            self.root / "common" / "adapters" / "doris" / "manifest.json": ["payload_text"],
            self.root / "clickhouse" / "create.sql": ["payload.tool_result.stderr"],
            self.root / "common" / "adapters" / "clickhouse" / "manifest.json": ["payload.tool_result.stderr"],
            self.root / "postgres" / "create.sql": ["{tool_result,stderr}"],
            self.root / "common" / "adapters" / "postgres" / "manifest.json": ["payload.tool_result.stderr"],
            self.root / "elastic" / "query_runner.py": ["payload.tool_result.stderr"],
            self.root / "opensearch" / "query_runner.py": ["payload.tool_result.stderr"],
        }

        for path, forbidden_markers in path_expectations.items():
            content = path.read_text(encoding="utf-8")
            for marker in forbidden_markers:
                self.assertNotIn(marker, content, msg=str(path.relative_to(self.root)))

    def test_clickhouse_incident_queries_use_expected_text_predicates(self) -> None:
        clickhouse_sections = load_query_sections(self.root / "clickhouse" / "queries.sql")

        q13 = clickhouse_sections["Q13"]
        self.assertIn("'timeout awaiting headers'", q13)
        self.assertIn("'retry budget depleted'", q13)
        self.assertIn("'transient upstream failure'", q13)
        self.assertNotIn("'error'", q13)
        self.assertNotIn("hasAnyTokens(", q13)

        q19 = clickhouse_sections["Q19"]
        self.assertIn("match(", q19)
        self.assertIn("(^|[^a-z])(error|timeout|retry)([^a-z]|$)", q19)
        self.assertNotIn("hasAnyTokens(", q19)

        self.assertIn("payload.attr.deployment_channel::String", q19)
        self.assertIn("payload.attr.release_ring::String", q19)
        self.assertNotIn("JSONExtractString(", q19)


if __name__ == "__main__":
    unittest.main()
