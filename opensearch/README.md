# OpenSearch Lane

This lane emits JSONBench-style benchmark artifacts under `results/`.

Files:

- `benchmark.sh`: import downloaded `agentlog` shards, print stage-by-stage progress, run query timing, collect index store statistics, write `results/<prefix>_agentlog_<size>.json`, emit `results/_query_results/_<prefix>_agentlog_<size>.query_results`, and fold temporary metric files into the final JSON instead of keeping them in `results/`
- `run_queries.sh`: runs the lightweight agentlog workload, prints query ordinal progress plus per-try timing progress to the console, clears the Linux page cache and explicit OpenSearch fielddata/query/request caches before every measured try, disables request-cache hits on `_search`, and snapshots query outputs in JSONBench text format while omitting long text and payload columns
- `queries.json`: the local OpenSearch query surface used by benchmark and validation flows
- `create.json`: OpenSearch index mapping
- `import.sh`: expands `DATA_GLOB` into an ordered shard list, then streams plain or gzip-compressed NDJSON shards into concurrent `_bulk` workers with `pigz`-assisted decompression, auto-generated document ids, bulk-friendly index settings, and console file-progress logging
- `deploy.sh`: stores the PID inside the active runtime directory, derives a host-aware default OpenSearch heap from `/proc/meminfo`, clamps it to `1g..8g` unless `OS_JAVA_OPTS` or `OS_HEAP_MB` is set explicitly, and disables the security plugin for local single-node benchmarking

Typical run:

```bash
bash ../download.sh --size 1m
bash benchmark.sh --size 1m
```

`DATA_DIR` or `DATA_GLOB` selects the source files and `RUNTIME_DIR` selects
the disposable runtime. Set `OS_BIN` to an existing OpenSearch executable;
`OS_STORAGE_PATH`, `OS_CONF_DIR`, and `OS_LOG_PATH` override its runtime paths.
If `OS_BIN` is not set or does not exist, the fallback installer uses its
versioned directory below `opensearch/.local/`.
