# MatrixOne

This adapter runs the AgentLogsBench 20-query workload against MatrixOne over
its MySQL-compatible endpoint. The scored surface is one table,
`agent_observations`, with the shared promoted columns and a native `JSON`
`payload` column. The import path first loads each NDJSON line into a temporary
JSON staging table, then projects the promoted fields and payload into the
scored table.

The adapter does not download or build MatrixOne. It reuses a running endpoint,
or `start.sh` can launch an existing `mo-service` binary when `MO_HOME` or
`MO_BIN` and a launch config are provided. The default `MO_LOAD_MODE=direct`
uses MatrixOne's server-side gzip reader, so the `.ndjson.gz` source stays
compressed on disk. Set `MO_LOAD_MODE=local` only when the server cannot read
the source path; that fallback temporarily decompresses the file under `/tmp`.

## 1m smoke run

The repository's 1m shard is `common/downloads/agent_observations_0001.ndjson.gz`.
If it has already been downloaded, run:

```bash
export MO_HOST=127.0.0.1
export MO_PORT=6001
export MO_USER=root
export MO_PASSWORD=''
export MO_DB=agentlogsbench_mo
export MO_TABLE=agent_observations

# Only needed when benchmark.sh must start MatrixOne itself.
export MO_HOME=/path/to/matrixone
# export MO_CONFIG=/path/to/launch.toml
# export MO_BIN=/path/to/mo-service

bash benchmark.sh run-engine \
  --engine matrixone \
  --size 1m \
  --data-dir common/downloads \
  --keep-runtime
```

The root driver also accepts `DATA_DIR` or `DATA_GLOB` for source files and
`RUNTIME_DIR` for adapter runtime files. `MO_HOME`/`MO_BIN` and `MO_CONFIG`
select an existing MatrixOne executable and launch configuration; the server's
own data directory remains managed by MatrixOne.

For a server that is already running, `MO_HOME`, `MO_CONFIG`, and `MO_BIN` are
not required. The command runs install/readiness checks, imports the shard,
executes Q01-Q20 with one warmup and three timed runs, captures 1m query
snapshots, and writes the final JSON under `matrixone/results/`.

To run the adapter directly instead of the root driver:

```bash
bash matrixone/benchmark.sh --size 1m --data-dir common/downloads
```

The import is restartable. By default (`MO_EXPECTED_ROWS=auto`) it counts the
selected source-file lines and reuses `MO_DB.MO_TABLE` when its row count
matches that source count. For the repository's current 1m shard this is
998,799 loaded rows even though the benchmark size label is 1,000,000. A
non-empty partial table is rejected so an incomplete run cannot silently
become a benchmark result.

## Result files

The final result is `matrixone/results/<machine>_agentlog_1m.json`. It embeds
the load, row-count, storage, and query-timing sidecars in `artifact_manifest`.
The actual captured outputs for the 1m run are in
`matrixone/results/_query_results/`.
The adapter is designed to fold temporary metric files into the final JSON and
keep only the final `*.json` plus `_query_results/` under `matrixone/results/`.

Runtime logs and temporary metric files live below `matrixone/runtime/` and
are removed at the end unless `--keep-runtime` is used. `stop.sh` only stops a
MatrixOne process started by this adapter; an externally managed endpoint is
left running.

## Useful overrides

```bash
MO_LOAD_MODE=local                 # client-side temporary decompression fallback
MO_EXPECTED_ROWS=auto              # or an explicit validated row-count override
MO_QUERY_TIMEOUT=900               # timeout per SQL invocation, in seconds
TRIES=3                            # timed runs per query
QUERY_FILE=matrixone/queries.sql   # alternate MatrixOne SQL surface
```

MatrixOne's native storage size is collected with `mo_table_size()` when
available. Because this baseline declares no user-created secondary indexes,
the fallback reports the table size as data size and index size as zero.
