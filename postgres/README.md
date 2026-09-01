# PostgreSQL Lane

This lane now emits JSONBench-style benchmark artifacts under `results/`.

Files:

- `benchmark.sh`: import downloaded `agentlog` shards, print stage-by-stage progress, run query timing, collect PostgreSQL storage statistics, write `results/<prefix>_agentlog_<size>.json`, emit `results/_query_results/_<prefix>_agentlog_<size>.query_results`, and fold temporary metric files into the final JSON instead of keeping them in `results/`
- `run_queries.sh`: runs the lightweight agentlog workload, prints `Qxx (n/N)` query progress plus per-try timing progress to the console, clears the Linux page cache between queries, and snapshots query outputs in JSONBench text format while omitting long text and payload columns
- `queries.sql`: the local PostgreSQL query surface used by benchmark and validation flows
- `create.sql`: single-table DDL plus serial post-load index definitions for `agent_observations`
- `import.sh`: expands `DATA_GLOB` into an ordered shard list, then streams NDJSON shards through one process, prints total file count plus per-file import progress, loads rows with bounded `COPY` batches, and applies post-load indexes without concurrent loader workers
- `deploy.sh`: writes a disposable bulk-load-oriented `postgresql.conf` profile for benchmark runtimes

Post-load indexes:

- The lane keeps `observation_id`, `biz_date/trace_id/seq_no`, `tenant/type/status/app`, `payload jsonb_path_ops`, and the FTS GIN index.
- The loader no longer uses PostgreSQL native partitions or concurrent loader workers.

100m policy:

- PostgreSQL `100m` can still be run manually.
- Root `bash benchmark.sh run-all --size 100m` skips PostgreSQL automatically and leaves the lane available through `run-engine`.
- Current published benchmark summaries leave PostgreSQL `100m` blank because the import path on the benchmark host is far slower than the Elasticsearch, ClickHouse, and Doris lanes we record for `100m`.

Fast ingest:

- `bash benchmark.sh --size 1m --fast-ingest` still records `load_time` before deferred post-load indexes are applied, then replays the deferred DDL before query timing.
- `PG_SKIP_FTS_INDEX=1 bash import.sh` is available for raw ingest-only probes when you want to skip the FTS index entirely.
- `PG_DEFER_POSTLOAD_INDEXES=1 bash import.sh` is available for raw ingest-only probes when you want pure heap-load timing with all post-load indexes skipped.
- `bash import.sh` is now a single-process loader. Use `PG_COPY_BATCH_ROWS` and `PG_COPY_COMMIT_ROWS` if you need to tune serial batch size.

Typical run:

```bash
bash ../download.sh --size 1m
bash benchmark.sh --size 1m
```

`DATA_DIR` or `DATA_GLOB` selects the source files, `RUNTIME_DIR` selects the
disposable runtime, and `PG_HOME` or `PG_BIN_DIR` selects the existing
PostgreSQL installation. `PGDATA` can override the cluster data directory.
