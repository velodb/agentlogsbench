#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"

# Only stop a MatrixOne process started by this adapter. An externally managed
# MatrixOne endpoint is intentionally left running after the benchmark.
pid=""
if [ -f "${MO_PID_FILE}" ]; then
    pid="$(cat "${MO_PID_FILE}")"
fi

if [ -z "${pid}" ] || ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${MO_PID_FILE}"
    exit 0
fi

kill "${pid}"
for _ in $(seq 1 60); do
    if ! kill -0 "${pid}" 2>/dev/null; then
        rm -f "${MO_PID_FILE}"
        echo "[matrixone] stopped process ${pid}"
        exit 0
    fi
    sleep 1
done

echo "[matrixone] process ${pid} did not stop within 60s" >&2
exit 1
