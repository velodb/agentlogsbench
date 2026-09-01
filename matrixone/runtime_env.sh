#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MO_HOST="${MO_HOST:-127.0.0.1}"
MO_PORT="${MO_PORT:-6001}"
MO_USER="${MO_USER:-root}"
MO_PASSWORD="${MO_PASSWORD:-}"
MO_DB="${MO_DB:-agentlogsbench_mo}"
MO_TABLE="${MO_TABLE:-agent_observations}"
MO_STAGE_TABLE="${MO_STAGE_TABLE:-__agentlogsbench_json_stage}"
MO_LOAD_MODE="${MO_LOAD_MODE:-direct}"
MO_START_TIMEOUT="${MO_START_TIMEOUT:-300}"
MO_QUERY_TIMEOUT="${MO_QUERY_TIMEOUT:-900}"
MO_MYSQL_BIN="${MO_MYSQL_BIN:-}"
MO_HOME="${MO_HOME:-}"
MO_BIN="${MO_BIN:-}"
MO_CONFIG="${MO_CONFIG:-}"
MO_LOG="${MO_LOG:-${SCRIPT_DIR}/runtime/matrixone.log}"
MO_PID_FILE="${MO_PID_FILE:-${SCRIPT_DIR}/runtime/matrixone.pid}"

resolve_matrixone_mysql() {
    if [ -n "${MO_MYSQL_BIN}" ] && [ -x "${MO_MYSQL_BIN}" ]; then
        printf '%s\n' "${MO_MYSQL_BIN}"
        return 0
    fi
    if command -v mysql >/dev/null 2>&1; then
        command -v mysql
        return 0
    fi
    return 1
}

resolve_matrixone_bin() {
    if [ -n "${MO_BIN}" ] && [ -x "${MO_BIN}" ]; then
        printf '%s\n' "${MO_BIN}"
        return 0
    fi
    if [ -n "${MO_HOME}" ] && [ -x "${MO_HOME}/mo-service" ]; then
        printf '%s\n' "${MO_HOME}/mo-service"
        return 0
    fi
    if command -v mo-service >/dev/null 2>&1; then
        command -v mo-service
        return 0
    fi
    return 1
}

resolve_matrixone_config() {
    if [ -n "${MO_CONFIG}" ] && [ -f "${MO_CONFIG}" ]; then
        printf '%s\n' "${MO_CONFIG}"
        return 0
    fi
    if [ -n "${MO_HOME}" ] && [ -f "${MO_HOME}/etc/launch/launch.toml" ]; then
        printf '%s\n' "${MO_HOME}/etc/launch/launch.toml"
        return 0
    fi
    return 1
}

matrixone_mysql() {
    local mysql_bin
    mysql_bin="${MO_MYSQL_BIN_RESOLVED:-$(resolve_matrixone_mysql)}"
    MYSQL_PWD="${MO_PASSWORD}" "${mysql_bin}" \
        --protocol=TCP \
        --host="${MO_HOST}" \
        --port="${MO_PORT}" \
        --user="${MO_USER}" \
        "$@"
}

matrixone_require_client() {
    MO_MYSQL_BIN_RESOLVED="$(resolve_matrixone_mysql)"
    export MO_MYSQL_BIN_RESOLVED
}

matrixone_require_runtime() {
    local bin config
    bin="$(resolve_matrixone_bin)" || {
        echo "MatrixOne binary not found; set MO_HOME or MO_BIN." >&2
        return 1
    }
    config="$(resolve_matrixone_config)" || {
        echo "MatrixOne launch config not found; set MO_CONFIG or MO_HOME." >&2
        return 1
    }
    MO_BIN_RESOLVED="${bin}"
    MO_CONFIG_RESOLVED="${config}"
    export MO_BIN_RESOLVED MO_CONFIG_RESOLVED
}

matrixone_validate_identifier() {
    local name="$1"
    local value="$2"
    if [[ ! "${value}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "${name} must be a simple SQL identifier: ${value}" >&2
        return 1
    fi
}

matrixone_endpoint_ready() {
    matrixone_mysql -N -B -e 'SELECT 1' >/dev/null 2>&1
}

matrixone_wait_ready() {
    local timeout="${1:-${MO_START_TIMEOUT}}"
    local attempt
    for ((attempt = 0; attempt < timeout; attempt++)); do
        if matrixone_endpoint_ready; then
            return 0
        fi
        sleep 1
    done
    echo "MatrixOne did not become ready at ${MO_HOST}:${MO_PORT} within ${timeout}s" >&2
    return 1
}

matrixone_running_pid() {
    local pid comm cwd cmd
    while read -r pid comm; do
        [ "${comm}" = "mo-service" ] || continue
        [ -r "/proc/${pid}/cwd" ] || continue
        cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
        if [ -n "${MO_HOME}" ] && [ "${cwd}" != "$(readlink -f "${MO_HOME}" 2>/dev/null || true)" ]; then
            continue
        fi
        cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
        [[ "${cmd}" == *mo-service* && "${cmd}" == *-launch* ]] || continue
        printf '%s\n' "${pid}"
        return 0
    done < <(ps -eo pid=,comm=)
    return 1
}

matrixone_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}
