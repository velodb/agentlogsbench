DuckDB benchmark lane for `agentlogsbench`.

This lane uses DuckDB `VARIANT` for the semi-structured `payload` column, is designed to fold temporary metric files into the final JSON, and keeps only the final `*.json` plus `_query_results/` under `duckdb/results/`.

`DATA_DIR` or `DATA_GLOB` selects the source files, `RUNTIME_DIR` selects
temporary runtime files, and `DB_PATH` selects the DuckDB database file.
DuckDB is loaded from the active Python environment and has no separate
`DUCKDB_HOME` setting.
