# ClickHouse Lane

This lane now emits JSONBench-style benchmark artifacts under `results/`.

Files:

- `benchmark.sh`: import downloaded `agentlog` shards, print stage-by-stage progress, run query timing, collect storage statistics, write `results/<prefix>_agentlog_<size>.json`, emit `results/_query_results/_<prefix>_agentlog_<size>.query_results`, and fold temporary metric files into the final JSON instead of keeping them in `results/`
- `run_queries.sh`: runs the lightweight agentlog workload, prints `Qxx (n/N)` query progress plus per-try timing progress to the console, clears the Linux page cache between queries, and snapshots query outputs in JSONBench text format while omitting long text and payload columns
- `queries.sql`: the local ClickHouse query surface used by benchmark and validation flows
- `create.sql`: physical DDL for `bench.agent_observations`
- `import.sh`: loads plain or gzip-compressed NDJSON shards directly and prints total file count plus per-file import progress

Typical run:

```bash
bash ../download.sh --size 1m
bash benchmark.sh --size 1m
```

`DATA_DIR` or `DATA_GLOB` selects the source files, `RUNTIME_DIR` selects the
disposable runtime, `CH_BIN` selects an existing ClickHouse executable, and
`CH_PATH` selects the ClickHouse data path.
