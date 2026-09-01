# Doris Lane

This lane now emits JSONBench-style benchmark artifacts under `results/`.

Files:

- `benchmark.sh`: import downloaded `agentlog` shards, print stage-by-stage progress, run query timing, collect Doris storage statistics, write `results/<prefix>_agentlog_<size>.json`, emit `results/_query_results/_<prefix>_agentlog_<size>.query_results`, and fold temporary metric files into the final JSON instead of keeping them in `results/`
- `run_queries.sh`: runs the lightweight agentlog workload, prints `Qxx (n/N)` query progress plus per-try timing progress to the console, clears the Linux page cache, sets Doris query session knobs before execution, and snapshots query outputs in JSONBench text format while omitting long text and payload columns
- `queries.sql`: the local Doris query surface used by benchmark and validation flows
- `create.sql`: Doris table definition
- `import.sh`: loads plain or gzip-compressed NDJSON shards directly and prints total file count plus per-file import progress

Typical run:

```bash
bash ../download.sh --size 1m
bash benchmark.sh --size 1m
```

`DATA_DIR` or `DATA_GLOB` selects the source files and `RUNTIME_DIR` selects the
disposable FE/BE runtime. `DORIS_HOME` selects an existing Doris installation;
the runtime's `fe-meta` and `be-storage` directories are created below it.
