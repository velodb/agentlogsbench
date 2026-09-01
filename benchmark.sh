#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common/benchmark_lib.sh"

usage() {
    cat <<'EOF'
Usage:
  bash benchmark.sh <command> [options]

Commands:
  prepare-dataset --size SIZE      Write lightweight manifest metadata for a downloaded size
  run-engine --engine NAME --size SIZE [--data-dir DIR|--data-glob GLOB] [--no-cleanup]
                                   Run one engine for 1m/10m/100m downloaded data
  run-all --size SIZE [--data-dir DIR|--data-glob GLOB] [--no-cleanup]
                                   Run multiple engines for one downloaded size
  render-dashboard [--output FILE] Regenerate data.generated.js for index.html
  validate                         Validate edition config, query suite, and adapter manifests
  validate-run --results-dir DIR   Validate legacy result JSON files
  score --results-dir DIR          Score legacy result JSON files
  summarize --results-dir DIR --output-dir DIR
                                   Summarize legacy result JSON files
EOF
}

require_data_glob() {
    local data_glob="$1"

    if [ -e "${data_glob}" ] || compgen -G "${data_glob}" >/dev/null 2>&1; then
        return 0
    fi

    echo "No input files matched DATA_GLOB=${data_glob}" >&2
    exit 1
}

require_download_dir() {
    local data_dir="$1"
    local size="$2"
    local file_count
    local index
    local file_name
    local missing=()

    file_count="$(dataset_file_count "${size}")"

    if [ ! -d "${data_dir}" ]; then
        echo "Downloaded dataset directory does not exist: ${data_dir}" >&2
        echo "Run: bash download.sh --size ${size}" >&2
        exit 1
    fi

    for index in $(seq 1 "${file_count}"); do
        printf -v file_name "agent_observations_%04d.ndjson.gz" "${index}"
        if [ ! -f "${data_dir}/${file_name}" ]; then
            missing+=("${file_name}")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Downloaded dataset is incomplete in ${data_dir} for size ${size}" >&2
        printf 'Missing files: %s\n' "${missing[*]}" >&2
        echo "Run: bash download.sh --size ${size}" >&2
        exit 1
    fi
}

prepare_dataset_command() {
    local size="$1"
    local data_dir="$2"
    local dataset_version="$3"
    local target_rows
    local input_files=()
    target_rows="$(dataset_row_count "${size}")"
    read -r -a input_files <<< "$(dataset_download_files "${data_dir}" "${size}")"

    python3 "${SCRIPT_DIR}/common/prepare_external_observation_dataset.py" \
        --input-files "${input_files[@]}" \
        --output-dir "${data_dir}" \
        --dataset-version "${dataset_version}" \
        --target-rows "${target_rows}"
}

run_engine_command() {
    local engine="$1"
    local size="$2"
    local data_dir="$3"
    local data_glob="$4"
    local output_prefix="$5"
    local machine_label="$6"
    local os_label="$7"
    local run_date="$8"
    local keep_runtime="$9"

    local args=(
        --size "${size}"
        --output-prefix "${output_prefix}"
        --machine "${machine_label}"
        --os "${os_label}"
        --run-date "${run_date}"
    )
    if [ -n "${data_glob}" ]; then
        args+=(--data-glob "${data_glob}")
    else
        args+=(--data-dir "${data_dir}")
    fi
    if [ "${keep_runtime}" -eq 1 ]; then
        args+=(--keep-runtime)
    fi

    bash "${SCRIPT_DIR}/${engine}/benchmark.sh" "${args[@]}"
}

render_dashboard_command() {
    local output_path="${1:-${SCRIPT_DIR}/data.generated.js}"
    bash "${SCRIPT_DIR}/generate-results.sh" --output "${output_path}"
}

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "${COMMAND}" in
    prepare-dataset)
        SIZE=""
        DATA_DIR="${DATA_DIR:-}"
        DATASET_VERSION=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --size) SIZE="$2"; shift ;;
                --data-dir) DATA_DIR="$2"; shift ;;
                --dataset-version) DATASET_VERSION="$2"; shift ;;
                *) echo "Unknown argument: $1" >&2; exit 1 ;;
            esac
            shift
        done
        SIZE="$(resolve_dataset_size "${SIZE}")"
        if [ -z "${DATA_DIR}" ]; then
            DATA_DIR="$(default_download_dir "${SCRIPT_DIR}" "${SIZE}")"
        fi
        if [ -z "${DATASET_VERSION}" ]; then
            DATASET_VERSION="agentlog-${SIZE}"
        fi
        require_download_dir "${DATA_DIR}" "${SIZE}"
        benchmark_log "benchmark" "Preparing dataset metadata for size=${SIZE} data_dir=${DATA_DIR} dataset_version=${DATASET_VERSION}"
        prepare_dataset_command "${SIZE}" "${DATA_DIR}" "${DATASET_VERSION}"
        benchmark_log "benchmark" "Dataset metadata ready under ${DATA_DIR}"
        ;;
    validate)
        python3 "${SCRIPT_DIR}/common/validate_edition.py" "$@"
        ;;
    validate-run)
        python3 "${SCRIPT_DIR}/common/validate_run_artifacts.py" "$@"
        ;;
    score)
        python3 "${SCRIPT_DIR}/common/score_benchmark.py" "$@"
        ;;
    summarize)
        python3 "${SCRIPT_DIR}/common/summarize_results.py" "$@"
        ;;
    render-dashboard)
        OUTPUT_PATH="${SCRIPT_DIR}/data.generated.js"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --output) OUTPUT_PATH="$2"; shift ;;
                *) echo "Unknown argument: $1" >&2; exit 1 ;;
            esac
            shift
        done
        benchmark_log "benchmark" "Rendering dashboard data to ${OUTPUT_PATH}"
        render_dashboard_command "${OUTPUT_PATH}"
        ;;
    run-engine|run-all)
        SIZE=""
        ENGINE=""
        ENGINES="clickhouse,doris,elastic,matrixone,opensearch,postgres,duckdb"
        DATA_DIR="${DATA_DIR:-}"
        DATA_GLOB="${DATA_GLOB:-}"
        OUTPUT_PREFIX="$(default_output_prefix)"
        MACHINE_LABEL="$(current_machine_label)"
        OS_LABEL="$(current_os_label)"
        RUN_DATE="$(current_run_date)"
        KEEP_RUNTIME=0

        while [ "$#" -gt 0 ]; do
            case "$1" in
                --size) SIZE="$2"; shift ;;
                --engine) ENGINE="$2"; shift ;;
                --engines) ENGINES="$2"; shift ;;
                --data-dir) DATA_DIR="$2"; shift ;;
                --data-glob) DATA_GLOB="$2"; shift ;;
                --output-prefix) OUTPUT_PREFIX="$2"; shift ;;
                --machine) MACHINE_LABEL="$2"; shift ;;
                --os) OS_LABEL="$2"; shift ;;
                --run-date) RUN_DATE="$2"; shift ;;
                --keep-runtime|--no-cleanup) KEEP_RUNTIME=1 ;;
                *) echo "Unknown argument: $1" >&2; exit 1 ;;
            esac
            shift
        done

        SIZE="$(resolve_dataset_size "${SIZE}")"
        if [ -z "${DATA_GLOB}" ] && [ -z "${DATA_DIR}" ]; then
            DATA_DIR="$(default_download_dir "${SCRIPT_DIR}" "${SIZE}")"
        fi
        if [ -n "${DATA_GLOB}" ]; then
            require_data_glob "${DATA_GLOB}"
        else
            require_download_dir "${DATA_DIR}" "${SIZE}"
        fi
        DATASET_FILES="$(dataset_file_count "${SIZE}")"
        benchmark_log "benchmark" "Validated dataset size=${SIZE} data_dir=${DATA_DIR:-<none>} data_glob=${DATA_GLOB:-<none>} files=${DATASET_FILES}"

        if [ "${COMMAND}" = "run-engine" ]; then
            if [ -z "${ENGINE}" ]; then
                echo "--engine is required for run-engine" >&2
                exit 1
            fi
            benchmark_log "benchmark" "Engine 1/1 ${ENGINE}: start"
            if run_engine_command "${ENGINE}" "${SIZE}" "${DATA_DIR}" "${DATA_GLOB}" "${OUTPUT_PREFIX}" "${MACHINE_LABEL}" "${OS_LABEL}" "${RUN_DATE}" "${KEEP_RUNTIME}"; then
                benchmark_log "benchmark" "Engine 1/1 ${ENGINE}: completed"
                render_dashboard_command "${SCRIPT_DIR}/data.generated.js"
                benchmark_log "benchmark" "Dashboard data refreshed"
            else
                benchmark_log "benchmark" "Engine 1/1 ${ENGINE}: failed"
                exit 1
            fi
            exit 0
        fi

        IFS=',' read -r -a ENGINE_LIST <<< "${ENGINES}"
        benchmark_log "benchmark" "Running ${#ENGINE_LIST[@]} engines: ${ENGINES}"
        failed=()
        engine_index=0
        for engine in "${ENGINE_LIST[@]}"; do
            if [ "${engine}" = "postgres" ] && [ "${SIZE}" = "100m" ]; then
                benchmark_log "benchmark" "Engine postgres: skipped for run-all size=100m; use run-engine for manual PostgreSQL 100m runs"
                continue
            fi
            engine_index=$((engine_index + 1))
            benchmark_log "benchmark" "Engine ${engine_index}/${#ENGINE_LIST[@]} ${engine}: start"
            if ! run_engine_command "${engine}" "${SIZE}" "${DATA_DIR}" "${DATA_GLOB}" "${OUTPUT_PREFIX}" "${MACHINE_LABEL}" "${OS_LABEL}" "${RUN_DATE}" "${KEEP_RUNTIME}"; then
                benchmark_log "benchmark" "Engine ${engine_index}/${#ENGINE_LIST[@]} ${engine}: failed"
                failed+=("${engine}")
                continue
            fi
            benchmark_log "benchmark" "Engine ${engine_index}/${#ENGINE_LIST[@]} ${engine}: completed"
        done
        render_dashboard_command "${SCRIPT_DIR}/data.generated.js"
        benchmark_log "benchmark" "Dashboard data refreshed"
        if [ "${#failed[@]}" -gt 0 ]; then
            printf 'run-all failed engines: %s\n' "${failed[*]}" >&2
            exit 1
        fi
        benchmark_log "benchmark" "All requested engines completed successfully"
        ;;
    *)
        usage
        exit 1
        ;;
esac
