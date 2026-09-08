#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common/benchmark_lib.sh"

SIZE=""
OUTPUT_ROOT="${OUTPUT_ROOT:-${SCRIPT_DIR}/common/downloads}"
S3_BASE_URL="${S3_BASE_URL:-https://s3.us-east-1.amazonaws.com/bench-dataset/agentlogs}"
FILE_PATTERN="${FILE_PATTERN:-agent_observations_%04d.ndjson.gz}"
FORCE=0

usage() {
    cat <<'EOF'
Usage:
  bash download_proxy.sh --size 1m|10m|100m [--output-root DIR] [--s3-base-url URL] [--force]

Proxy:
  Uses http_proxy/https_proxy (or their uppercase variants) from the
  environment. If only http_proxy is set, it is also used for HTTPS downloads.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --size)
            SIZE="$2"
            shift
            ;;
        --output-root)
            OUTPUT_ROOT="$2"
            shift
            ;;
        --s3-base-url)
            S3_BASE_URL="$2"
            shift
            ;;
        --force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# The default dataset URL is HTTPS. wget and curl normally select a
# scheme-specific proxy for HTTPS, so map http_proxy to https_proxy when the
# caller did not provide one. Respect no_proxy and any existing HTTPS proxy.
HTTP_PROXY_VALUE="${http_proxy:-${HTTP_PROXY:-}}"
HTTPS_PROXY_VALUE="${https_proxy:-${HTTPS_PROXY:-}}"
ALL_PROXY_VALUE="${all_proxy:-${ALL_PROXY:-}}"
if [ -z "${HTTPS_PROXY_VALUE}" ] && [ -n "${HTTP_PROXY_VALUE}" ]; then
    export https_proxy="${HTTP_PROXY_VALUE}"
    export HTTPS_PROXY="${HTTP_PROXY_VALUE}"
elif [ -z "${HTTPS_PROXY_VALUE}" ] && [ -n "${ALL_PROXY_VALUE}" ]; then
    export https_proxy="${ALL_PROXY_VALUE}"
    export HTTPS_PROXY="${ALL_PROXY_VALUE}"
fi

SIZE="$(resolve_dataset_size "${SIZE}")"
FILE_COUNT="$(dataset_file_count "${SIZE}")"
TARGET_DIR="${OUTPUT_ROOT}"

mkdir -p "${TARGET_DIR}"

missing=0
for index in $(seq 1 "${FILE_COUNT}"); do
    printf -v file_name "${FILE_PATTERN}" "${index}"
    if [ ! -f "${TARGET_DIR}/${file_name}" ] || [ "${FORCE}" -eq 1 ]; then
        missing=1
    fi
done

if [ "${missing}" -eq 0 ]; then
    echo "[download] ${SIZE} already present under ${TARGET_DIR}, skipping"
    exit 0
fi

for index in $(seq 1 "${FILE_COUNT}"); do
    printf -v file_name "${FILE_PATTERN}" "${index}"
    target_path="${TARGET_DIR}/${file_name}"
    if [ "${FORCE}" -eq 0 ] && [ -f "${target_path}" ]; then
        echo "[download] ${file_name} already exists, skipping"
        continue
    fi
    url="${S3_BASE_URL%/}/${file_name}"
    echo "[download] ${url}"
    if command -v wget >/dev/null 2>&1; then
        wget --continue --progress=dot:giga --output-document="${target_path}" "${url}"
    elif command -v curl >/dev/null 2>&1; then
        curl -fL -C - --retry 5 --retry-delay 2 "${url}" -o "${target_path}"
    else
        echo "download_proxy.sh requires wget or curl" >&2
        exit 1
    fi
done

cat <<EOF
[download] done
size=${SIZE}
output_dir=${TARGET_DIR}
file_count=${FILE_COUNT}
EOF
