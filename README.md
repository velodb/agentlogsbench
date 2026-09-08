# AgentLogsBench: A Benchmark For Search And Analytics On Agent Observability Logs

## Overview

This benchmark compares how analytical databases and search systems handle real AI-agent observability workloads: keyword and phrase retrieval over agent traces, trace replay and tool-failure triage, and analytical rollups over latency, tokens, cost, and dynamic payload attributes.

The dataset is a collection of files containing agent observation events delimited by newline (ndjson). Each event is one observation row in a trace — generations, tool calls, retries, failures, and replayable chains — with a stable set of promoted columns plus a dynamic `payload` for evolving telemetry. Public shards are hosted on a public S3 bucket and downloaded by `download.sh`.

The benchmark currently runs against [ClickHouse](https://clickhouse.com/), [Apache Doris](https://doris.apache.org/), [Elasticsearch](https://www.elastic.co/elasticsearch), [MatrixOne](https://github.com/matrixorigin/matrixone), [OpenSearch](https://opensearch.org/), [PostgreSQL](https://www.postgresql.org/), and [DuckDB](https://duckdb.org/) on the same logical surface.

## Principles

The benchmark is structured around three pillars: Reproducibility, Realism, and Fairness. They mirror the framing used by [ClickBench](https://github.com/ClickHouse/ClickBench) and [JSONBench](https://github.com/ClickHouse/JSONBench), adapted to agent-observability logs.

### Reproducibility

It is easy to reproduce every test in a semi-automated way. The benchmark edition is fixed in `common/config/edition.json`, and the query suite, result contracts, and per-engine adapter manifests are versioned alongside the SQL.

- The full benchmark recipe — installation, data download, import, query execution, and result collection — is captured in shell scripts and Python utilities that ship with this repository.
- Downloaded public shards are immutable inputs. `prepare-dataset` writes metadata-only manifests rather than rewriting data.
- The execution protocol is explicit: serial queries, 1 warmup run, 5 measured runs, 900-second timeout, cache disabled where supported.
- Final result JSON files embed their metric sidecars through `artifact_manifest`, and per-query result snapshots are written under `results/_query_results/`.
- Result scoring is also fixed: per-query normalization against the fastest valid engine, geometric mean across the suite, with median latency as the published statistic.

### Realism

The dataset represents real-world agent telemetry rather than uniform synthetic noise.

- Traces contain mixed observation types — generations, tool calls, events, retries, failures, and replayable chains — so queries exercise the same shapes engineers see in production.
- Trace archetypes include `simple_chat`, `tool_lookup`, `research_agent`, `retry_after_429`, `timeout_then_fallback`, `guardrail_block`, and `large_context_replay`.
- Task categories span coding/devops, research/search, office productivity, workflow automation, data analysis, and safety/compliance.
- Language profiles include English, Chinese, mixed-language content, and code/log-heavy content.
- Tenants and apps follow a long-tail distribution rather than a balanced catalog.
- Text fields cover realistic sizes — `input` ranges from 5KB to 1MB, `output` from 1KB to 50KB — so retrieval is exercised over multi-kilobyte and larger bodies, not only short snippets.
- Text search material includes positive keyword injection at a controlled rate plus hard negatives, so retrieval is not reduced to trivial exact matches.
- The payload contains both core dimensions (provider stop reasons, cache hits, OTel/Langfuse/MLflow blocks) and many long-tail dynamic keys.

The text seed material is adapted from real coding-agent interaction patterns, especially [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)-style workflows, normalized and synthesized into benchmark-ready traces. The data construction approach is influenced by [ZClawBench](https://huggingface.co/datasets/zai-org/ZClawBench): start from realistic agent workflows, preserve multi-step behavior, and generate benchmark data that reflects how agents actually operate.

### Fairness

Databases must be benchmarked using their default settings. Non-default settings are allowed only when they are a prerequisite for running the benchmark (for example, increasing the maximum JVM heap size). Tuning settings aimed specifically at this workload are not allowed.

The scored surface is a single primary table, `agent_observations`, with a stable promoted-column set and a dynamic `payload` column. The benchmark is intentionally not optimized for the easiest possible schema for each engine.

- **Hidden payload flattening is disallowed.** Engines may not flatten the dynamic `payload` into pre-declared typed top-level columns at insertion time, on the assumption that every future payload subfield is known in advance. Production agent telemetry evolves; pre-flattening defeats the workload.
- **Full-raw-payload as the only primary surface is disallowed.** The benchmark requires the promoted-column surface; engines may not skip it and serve everything from a single opaque blob.
- **Multi-table designs are not part of the scored configuration.** Engines may pre-build helper tables for their own runtime use, but the scored queries run against the single observation table.
- **Extra promoted columns are not allowed.** The promoted-column set is fixed in `common/config/edition.json`.

Index structures are a grey zone, handled the same way as JSONBench. Each engine is allowed to use its native indexing facilities — text indexes, inverted indexes, GIN, full-text, generated nested indexes, and engine-native nested mappings on `payload.attr.*` — because real teams index based on anticipated structure.

- *Pros:* Agent observability documents share a common skeleton, so indexing is realistic. Disallowing it would invalidate how teams actually run these systems.
- *Cons:* Indexes also affect compression and pruning, so index quality is measured indirectly. We accept that tradeoff in exchange for matching production practice.

It is not allowed to cache query results between hot runs. The benchmark clears the Linux page cache between queries, following the JSONBench/ClickBench cold-query pattern.

## Goals

The goal is to advance the possibilities of search and analytics on agent observability logs. This benchmark is influenced by [ClickBench](https://github.com/ClickHouse/ClickBench) and [JSONBench](https://github.com/ClickHouse/JSONBench), which have driven measurable improvements in performance, capabilities, and stability across analytics databases. We would like AgentLogsBench to play a similar role for the storage and retrieval layer underneath modern agent observability stacks such as [Langfuse](https://langfuse.com/docs), [MLflow Tracing](https://mlflow.org/docs/latest/genai/tracing/), and [OpenTelemetry GenAI](https://opentelemetry.io/docs/specs/semconv/gen-ai/).

## What The Benchmark Measures

The main track contains 20 queries (Q01 through Q20) over the single primary table `agent_observations`. The queries cover three workload families:

1. **Search and retrieval** — observation lookup, trace replay, generation-to-tool chain expansion, incident phrase retrieval, large-text-field keyword and phrase retrieval, and tool-failure triage with text relevance.
2. **Analytical workloads** — trace-level failure and cost summaries, model and observation-type token usage, tool usage distribution, and provider diagnostics including stop reasons and cache-hit behavior.
3. **Semi-structured search and analysis** — production-style filtering and aggregation over evolving payload fields such as release ring, customer tier, retrieval strategy, and nested provider/tool diagnostics.

Concretely, the benchmark answers questions like:

- Which observations mention a deployment rollback, a retrieval miss, or a guardrail issue?
- How do traces with failures differ in total cost and latency?
- Which tools fail most often, and under what status patterns?
- How do dynamic payload dimensions such as `release_ring`, `customer_tier`, or `retrieval_strategy` affect latency and cost?

### Example observation row

```json
{
  "event_time": "2026-04-10 09:12:31",
  "biz_date": "2026-04-10",
  "trace_id": "trace_000001",
  "session_id": "sess_000001",
  "observation_id": "obs_000145",
  "parent_observation_id": "obs_000144",
  "seq_no": 7,
  "type": "TOOL",
  "status": "error",
  "tenant": "tenant_003",
  "app": "app_002",
  "environment": "prod",
  "task_category": "coding_devops",
  "trace_archetype": "timeout_then_fallback",
  "model": "coder-large",
  "tool_name": "mcp__matrix__read_file",
  "input": "Check the deployment rollback path and inspect the latest error output.",
  "output": "stderr: unable to open /workspace/state/retrieval_3bb6.sqlite",
  "input_tokens": 1482,
  "output_tokens": 231,
  "total_cost": 0.0184,
  "latency_ms": 1240,
  "payload": {
    "provider":   { "stop_reason": "tool_use", "cache_hit": false },
    "tool_result":{ "stderr": "unable to open ...", "exit_code": 1 },
    "attr":       { "release_ring": "canary", "customer_tier": "enterprise", "retrieval_strategy": "hybrid_rerank" },
    "otel":       { "status_code": "ERROR" },
    "langfuse":   { "trace_id": "trace_000001" },
    "mlflow":     { "trace_id": "trace_000001", "status": "error" }
  }
}
```

The schema reflects the data model used in modern tracing systems: [Langfuse](https://langfuse.com/docs)'s observations-first model, [MLflow Tracing](https://mlflow.org/docs/latest/genai/tracing/) trace/span semantics, and [OpenTelemetry semantic conventions for Generative AI](https://opentelemetry.io/docs/specs/semconv/gen-ai/).

### Per-engine indexing

Each engine exposes the same logical surface using its native facilities:

| Engine | Payload representation | Text / payload indexes |
| --- | --- | --- |
| ClickHouse | JSON column | text index over concatenated text |
| Apache Doris | `VARIANT` column | inverted indexes on text columns |
| PostgreSQL | `JSONB` column | GIN on payload + full-text search index |
| Elasticsearch | typed properties | dynamic handling for `payload.attr.*` |
| OpenSearch | typed properties | dynamic handling for `payload.attr.*` |
| DuckDB | JSON column | full table scan baseline |
| MatrixOne | JSON column | native primary key; JSON attribute scan baseline |

## Limitations

- The benchmark is about observability-oriented search and analytics. It is **not** a general OLTP benchmark, a vector retrieval quality benchmark, or an agent task-completion accuracy benchmark.
- The scored design favors dynamic indexability over exhaustive upfront schema modeling. Engines that work well only when every payload subfield is pre-declared as a typed column will be at a disadvantage by design.
- The benchmark does not record data loading times. Many systems require finicky multi-step ingestion, which makes loading-time comparisons difficult to interpret across engines.

## Pre-requisites

Running the full benchmark requires a machine with sufficient resources and disk. The 100m tier is the largest publicly distributed shard set today; the 1B tier is on the roadmap and not yet wired into `download.sh`.

The reference benchmark machine is:

- **Hardware:** AWS EC2 `m6i.8xlarge` with 10 TB gp3 disk
- **OS:** Ubuntu 24.04

This matches the `m6i.8xlarge` convention used by ClickBench and JSONBench so results can be compared across benchmarks.

Supported dataset sizes:

| Size | Approx. observation rows | Purpose |
| --- | --- | --- |
| `1m` | ~1M | development, CI, quick smoke runs |
| `10m` | ~10M | full validation pass on a single workstation |
| `100m` | ~100M | official leaderboard tier (`M` in `edition.json`) |
| `1B` | ~1B (roadmap) | appendix scale; not yet downloadable |

Running the full 100m benchmark takes several hours per engine; smaller tiers complete in minutes.

## Usage

Each engine has its own folder (`clickhouse/`, `doris/`, `elastic/`, `matrixone/`, `opensearch/`, `postgres/`, `duckdb/`) with the install, import, and query scripts for that system. The shared driver is `benchmark.sh` at the top of `agentlogsbench/`.

### Download the data

Download a dataset size with `download.sh`. The downloaded ndjson shards land in `common/downloads/` by default.

```bash
bash download.sh --size 1m
# or --size 10m, --size 100m
```

If the direct S3 route is unavailable or slower, use `download_proxy.sh`. It
honors `http_proxy`/`https_proxy` (including a lower-case `http_proxy` for the
HTTPS dataset URL) and still supports the same resume and skip behavior:

```bash
http_proxy=http://127.0.0.1:7890 \
https_proxy=http://127.0.0.1:7890 \
bash download_proxy.sh --size 1m
```

If you want to inspect or re-use the same data across multiple engines, `download.sh` is idempotent: existing shards are not re-fetched unless `--force` is passed.

### Run the benchmark

Optionally write lightweight metadata beside the downloaded shards:

```bash
bash benchmark.sh prepare-dataset --size 1m
```

Run one engine:

```bash
bash benchmark.sh run-engine --engine clickhouse --size 1m
```

The source data and disposable runtime can also be configured with environment
variables. `DATA_DIR` points to a downloaded tier directory, `DATA_GLOB` points
to one file or a file glob, and `RUNTIME_DIR` selects the runtime directory.
The command-line `--data-dir` or `--data-glob` option overrides the matching
environment variable.

```bash
DATA_DIR=/data/agentlogsbench/1m \
RUNTIME_DIR=/data/agentlogsbench-runtime/clickhouse-1m \
bash benchmark.sh run-engine --engine clickhouse --size 1m

DATA_GLOB=/data/agentlogsbench/1m/agent_observations_0001.ndjson.gz \
RUNTIME_DIR=/data/agentlogsbench-runtime/doris-1m \
bash benchmark.sh run-engine --engine doris --size 1m
```

Add `--no-cleanup` to keep the engine runtime directory after the run for inspection.

Run several engines on the same downloaded data:

```bash
bash benchmark.sh run-all --engines clickhouse,doris,elastic,opensearch --size 1m
```

`benchmark.sh` runs install, import, the 20-query suite, and storage statistics for each engine, following the per-engine script under that engine's folder.

### Run MatrixOne for 1m

The MatrixOne lane uses the same `common/downloads/agent_observations_0001.ndjson.gz`
shard as the other engines. It does not download or build MatrixOne. Point the
adapter at an existing MySQL-compatible MatrixOne endpoint:

```bash
export MO_HOST=127.0.0.1
export MO_PORT=6001
export MO_USER=root
export MO_PASSWORD=''
export MO_DB=agentlogsbench_mo
export MO_TABLE=agent_observations

bash benchmark.sh run-engine \
  --engine matrixone \
  --size 1m \
  --data-dir common/downloads \
  --keep-runtime
```

If the endpoint is not already running, also set `MO_HOME` to a MatrixOne
installation containing `mo-service` and its default `etc/launch/launch.toml`
(or set `MO_BIN` and `MO_CONFIG` explicitly). The adapter uses MatrixOne's
server-side gzip reader by default and loads the compressed shard directly.
When the target table already contains exactly the selected source row count,
import is skipped; a non-empty partial table is rejected. For the current 1m
shard that source count is 998,799. See
[`matrixone/README.md`](matrixone/README.md) for the standalone workflow and
fallback `MO_LOAD_MODE=local`.

### Validate

Validate the benchmark configuration and any result artifacts:

```bash
bash benchmark.sh validate
python3 -m unittest discover -s tests
python3 common/validate_run_artifacts.py --results-dir clickhouse/results
```

### Retrieve results

Each engine writes its own `results/` directory. The result artifacts follow a consistent shape:

- `results/<machine>_agentlog_<size>.json` — final result file. Embeds the metric sidecars and records them under `artifact_manifest`. This is what the dashboard reads.
- `results/_query_results/_<machine>_agentlog_<size>.query_results` — text snapshot of each query's output, with long text and JSON-style payload bodies elided so cross-system diffs stay readable.
- Per-engine sidecars (`.total_size`, `.data_size`, `.results_runtime`, `.results_memory_usage`, etc.) are collected during the run and embedded into the final JSON.

Each engine's `results/` keeps only the final `*.json` plus `_query_results/`; temporary metric files are staged under the engine's runtime directory and folded into the final JSON.

The example result files committed under each engine's `results/` directory show the expected layout (for example, [`clickhouse/results/`](clickhouse/results/) and [`doris/results/`](doris/results/)).

### Render the dashboard

Regenerate `data.generated.js` for the bundled `index.html` dashboard:

```bash
bash benchmark.sh render-dashboard
```

Open `index.html` in a browser to view the leaderboard locally.

## Add a new database

We highly welcome additions of new entries in the benchmark. You don't have to be affiliated with the database engine to contribute. We welcome all types of databases — open-source and closed-source, commercial and experimental, distributed or embedded — except one-off customized builds for the benchmark.

While the main benchmark uses a specific machine configuration for reproducibility, results from cloud services and data lakes are also valuable as reference comparisons.

- [x] [ClickHouse](./clickhouse/README.md)
- [x] [Apache Doris](./doris/README.md)
- [x] [Elasticsearch](./elastic/README.md)
- [x] [OpenSearch](./opensearch/README.md)
- [x] [PostgreSQL](./postgres/README.md)
- [x] [DuckDB](./duckdb/README.md)
- [ ] MongoDB
- [x] [MatrixOne](./matrixone/README.md)
- [ ] VictoriaLogs
- [ ] SingleStore
- [ ] GreptimeDB
- [ ] Quickwit
- [ ] Vespa
- [ ] Manticore Search
- [ ] Snowflake
- [ ] Loki
- [ ] Meilisearch

To add an engine, create a new folder following the layout of the existing engines: `create.sql` (or `create.json` for search engines), `install.sh`, `import.sh`, `run_queries.sh`, `query_runner.py`, and a `README.md`. Add a corresponding adapter manifest under `common/adapters/<engine>/` and a query map that points each canonical query in `common/queries/canonical/` to its engine-native form.

## Repository Layout

```text
agentlogsbench/
  benchmark.sh
  download.sh
  index.html
  common/
    benchmark_lib.sh
    build_jsonbench_result.py
    prepare_external_observation_dataset.py
    config/         # edition.json, data-generation.json
    queries/        # canonical/, queries.sql, query-suite.json
    contracts/      # query-contracts.json
    adapters/       # per-engine manifest + query-map
    seeds/          # seed envelopes for synthetic generation
    context/        # query context per dataset size
  clickhouse/  doris/  elastic/  matrixone/  opensearch/  postgres/  duckdb/
    benchmark.sh   create.sql/.json   install.sh   import.sh
    run_queries.sh   query_runner.py   results/   README.md
  tests/
  tooling/
```

## Related Work

| Project | Main focus | How it differs from AgentLogsBench |
| --- | --- | --- |
| [ClickBench](https://github.com/ClickHouse/ClickBench) | analytical database benchmarking | broader analytical benchmarking, not centered on agent observability |
| [JSONBench](https://github.com/ClickHouse/JSONBench) | JSON analytics benchmarking | focuses on JSON-heavy queries, not agent trace search plus observability analytics |
| [ZClawBench](https://huggingface.co/datasets/zai-org/ZClawBench) | agent-task benchmark data construction | task-completion benchmark inspiration rather than observability-log benchmarking |
| [Langfuse](https://langfuse.com/docs) | agent tracing and observability product | production observability reference, not a cross-database benchmark |
| [MLflow Tracing](https://mlflow.org/docs/latest/genai/tracing/) | trace/span observability for GenAI | tracing model reference, not a storage-system benchmark |

## References

- [ClickBench](https://github.com/ClickHouse/ClickBench) — public benchmark presentation style and cold-query benchmarking inspiration
- [JSONBench](https://github.com/ClickHouse/JSONBench) — JSON-oriented analytics benchmark structure and runtime conventions
- [ZClawBench](https://huggingface.co/datasets/zai-org/ZClawBench) — seed-driven, workflow-oriented synthetic benchmark construction
- [Claude Code Overview](https://docs.anthropic.com/en/docs/claude-code/overview) — coding-agent workflow patterns informing the text seed material
- [Langfuse Documentation](https://langfuse.com/docs) and [Langfuse v4 Observations-First](https://langfuse.com/docs/v4) — agent trace and observation modeling
- [MLflow Tracing for LLM and Agent Observability](https://mlflow.org/docs/latest/genai/tracing/) — trace/span-oriented GenAI observability
- [OpenTelemetry Generative AI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) — portable telemetry semantics
