#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/runtime_env.sh"

matrixone_require_client
if matrixone_endpoint_ready; then
    echo "[matrixone] reusing existing server at ${MO_HOST}:${MO_PORT}"
    exit 0
fi

matrixone_require_runtime
mkdir -p "$(dirname "${MO_LOG}")" "$(dirname "${MO_PID_FILE}")"

if pid="$(matrixone_running_pid 2>/dev/null)"; then
    echo "[matrixone] process ${pid} exists; waiting for SQL endpoint"
else
    config_arg="${MO_CONFIG_RESOLVED}"
    if [ -n "${MO_HOME}" ] && [ "${MO_CONFIG_RESOLVED}" = "${MO_HOME}/etc/launch/launch.toml" ]; then
        config_arg="etc/launch/launch.toml"
    fi
    (
        if [ -n "${MO_HOME}" ]; then
            cd "${MO_HOME}"
        fi
        nohup "${MO_BIN_RESOLVED}" -launch "${config_arg}" >"${MO_LOG}" 2>&1 &
        echo "$!" >"${MO_PID_FILE}"
    )
    echo "[matrixone] started ${MO_BIN_RESOLVED}"
fi

matrixone_wait_ready "${MO_START_TIMEOUT}"
echo "[matrixone] SQL endpoint ready at ${MO_HOST}:${MO_PORT}"
