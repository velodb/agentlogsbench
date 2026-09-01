#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REQUIREMENTS_FILE="${ROOT_DIR}/agentlogsbench/requirements-duckdb.txt"
cd "${ROOT_DIR}"

ensure_python_pip() {
    if python3 -m pip --version >/dev/null 2>&1
    then
        return 0
    fi

    local sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]
    then
        if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1
        then
            echo "python3-pip is required for DuckDB and sudo without password is unavailable." >&2
            return 1
        fi
        sudo_cmd=(sudo -n)
    fi

    if [ ! -f /etc/debian_version ]
    then
        echo "Automatic python3-pip installation is only implemented for Debian/Ubuntu hosts." >&2
        return 1
    fi

    "${sudo_cmd[@]}" apt-get update
    DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y python3-pip
}

if python3 -c 'import duckdb; assert callable(getattr(duckdb, "connect", None))' >/dev/null 2>&1
then
    echo "[duckdb] install done"
    exit 0
fi

ensure_python_pip
python3 -m pip install --break-system-packages --user -r "${REQUIREMENTS_FILE}"
echo "[duckdb] install done"
