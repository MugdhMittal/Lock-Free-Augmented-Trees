#!/usr/bin/env bash
# Run one task of the full experiment. The first argument is either "fixed"
# for data structures with no array-size parameter, or one array size.

set -euo pipefail

TASK_MODE="${1:?Usage: run_cartesian_sweep.sh fixed|<array-size>}"
TRIALS="${TRIALS:-3}"
TIME_MS="${TIME_MS:-5000}"
THREADS="${THREADS:-1 2 4 8 16 32 64 128}"
DS_SIZES="${DS_SIZES:-1000 10000 50000 100000 500000 1000000 2000000}"
WORKLOADS="${WORKLOADS:-1:1 25:25 33:33 50:50}"

FIXED_DATA_STRUCTURES=(
  Trie_Baseline
  Lock_Free_Tree_Augmented
  Lock_Free_Tree_NoAlloc
)
ARRAY_DATA_STRUCTURES=(
  Trie_FatNode_NoVC
  Trie_FatNode_ChildVC
  Lock_Free_Tree_Augmented_FatNodePtrs
)

read -r -a THREAD_LIST <<< "${THREADS}"
read -r -a DS_SIZE_LIST <<< "${DS_SIZES}"
read -r -a WORKLOAD_LIST <<< "${WORKLOADS}"

if [[ "${TASK_MODE}" == fixed ]]; then
  TASK_LABEL=fixed
  DATA_STRUCTURES=("${FIXED_DATA_STRUCTURES[@]}")
  ARRAY_SIZE=NA
  BINARY_LABEL=fixed
else
  if ! [[ "${TASK_MODE}" =~ ^[0-9]+$ ]] || (( TASK_MODE < 1 )); then
    echo "Array size must be a positive integer: ${TASK_MODE}" >&2
    exit 2
  fi
  TASK_LABEL="a${TASK_MODE}"
  DATA_STRUCTURES=("${ARRAY_DATA_STRUCTURES[@]}")
  ARRAY_SIZE="${TASK_MODE}"
  BINARY_LABEL="a${TASK_MODE}"
fi

CAMPAIGN_ID="${CAMPAIGN_ID:-campaign-${SLURM_ARRAY_JOB_ID:-${SLURM_JOB_ID:-local}}}"
RESULTS_ROOT="${RESULTS_ROOT:-results/cartesian/${CAMPAIGN_ID}/${TASK_LABEL}}"
CSV_PATH="${RESULTS_ROOT}/trials.csv"
METADATA_PATH="${RESULTS_ROOT}/metadata.txt"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "${RESULTS_ROOT}/raw"

{
  echo "campaign_id=${CAMPAIGN_ID}"
  echo "task_label=${TASK_LABEL}"
  echo "hostname=$(hostname)"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "slurm_job_id=${SLURM_JOB_ID:-}"
  echo "slurm_array_job_id=${SLURM_ARRAY_JOB_ID:-}"
  echo "slurm_array_task_id=${SLURM_ARRAY_TASK_ID:-}"
  echo "git_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "trials=${TRIALS}"
  echo "time_ms=${TIME_MS}"
  echo "threads=${THREADS}"
  echo "ds_sizes=${DS_SIZES}"
  echo "workloads=${WORKLOADS}"
} > "${METADATA_PATH}"

printf '%s\n' \
  'campaign_id,task_label,slurm_job_id,hostname,data_structure,array_size,trial,threads,requested_ds_size,key_range,insert_pct,delete_pct,lookup_pct,time_ms,prefill_threads,actual_prefill_size,prefill_elapsed_ms,total_ops,total_throughput,find_throughput,update_throughput,versions_created,validation,exit_code,status,raw_log' \
  > "${CSV_PATH}"

combination_count=$(( ${#DATA_STRUCTURES[@]} * ${#WORKLOAD_LIST[@]} * ${#THREAD_LIST[@]} * ${#DS_SIZE_LIST[@]} * TRIALS ))
echo "Campaign: ${CAMPAIGN_ID}; task: ${TASK_LABEL}; trials: ${combination_count}"
echo "CSV: ${CSV_PATH}"

if [[ "${DRY_RUN}" == 1 ]]; then
  echo "DRY_RUN=1: no benchmark binaries were executed."
  exit 0
fi

clean_value() {
  local value="${1:-}"
  value="${value//[$'\t\r\n ']/}"
  printf '%s' "${value:-NA}"
}

value_after_equals() {
  local key="$1"
  local log_file="$2"
  grep -m1 "^${key}=" "${log_file}" | cut -d= -f2- || true
}

failures=0
run_trial() {
  local data_structure="$1"
  local workload="$2"
  local thread_count="$3"
  local ds_size="$4"
  local trial="$5"
  local insert_pct="${workload%%:*}"
  local delete_pct="${workload##*:}"
  local lookup_pct=$((100 - insert_pct - delete_pct))
  local key_range=$((ds_size * 2))
  local binary="./bin/${data_structure}.${BINARY_LABEL}.debra"
  local log_dir="${RESULTS_ROOT}/raw/${data_structure}/${TASK_LABEL}/size${ds_size}/i${insert_pct}_d${delete_pct}/t${thread_count}"
  local log_file="${log_dir}/trial${trial}.log"
  local exit_code=0
  local validation=FAIL
  local status=FAILED

  if (( lookup_pct < 0 )); then
    echo "Invalid workload ${workload}: insert + delete exceeds 100" >&2
    exit 2
  fi

  mkdir -p "${log_dir}"
  printf '[%s] %s %s size=%s i=%s d=%s t=%s trial=%s\n' \
    "$(date -u +%H:%M:%S)" "${data_structure}" "${TASK_LABEL}" \
    "${ds_size}" "${insert_pct}" "${delete_pct}" "${thread_count}" "${trial}"

  if [[ ! -x "${binary}" ]]; then
    printf 'Missing binary: %s\n' "${binary}" > "${log_file}"
    exit_code=127
  elif "${binary}" \
    -nwork "${thread_count}" \
    -nprefill "${thread_count}" \
    -prefillsize "${ds_size}" \
    -i "${insert_pct}" \
    -d "${delete_pct}" \
    -rq 0 \
    -rqsize 1 \
    -k "${key_range}" \
    -nrq 0 \
    -t "${TIME_MS}" \
    > "${log_file}" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  if grep -q '^Structural validation OK\.' "${log_file}"; then
    validation=OK
  fi
  if [[ "${exit_code}" == 0 && "${validation}" == OK ]]; then
    status=OK
  fi

  local actual_prefill_size prefill_elapsed_ms total_ops total_throughput
  local find_throughput update_throughput versions_created
  actual_prefill_size="$(value_after_equals pref_size "${log_file}")"
  prefill_elapsed_ms="$(value_after_equals prefill_elapsed_ms "${log_file}")"
  total_ops="$(value_after_equals total_ops "${log_file}")"
  total_throughput="$(value_after_equals total_throughput "${log_file}")"
  find_throughput="$(value_after_equals find_throughput "${log_file}")"
  update_throughput="$(value_after_equals update_throughput "${log_file}")"
  versions_created="$(grep '^Total versions created' "${log_file}" | tail -n1 | awk -F= '{print $2}' || true)"

  printf '%s\n' \
    "${CAMPAIGN_ID},${TASK_LABEL},${SLURM_JOB_ID:-NA},$(hostname),${data_structure},${ARRAY_SIZE},${trial},${thread_count},${ds_size},${key_range},${insert_pct},${delete_pct},${lookup_pct},${TIME_MS},${thread_count},$(clean_value "${actual_prefill_size}"),$(clean_value "${prefill_elapsed_ms}"),$(clean_value "${total_ops}"),$(clean_value "${total_throughput}"),$(clean_value "${find_throughput}"),$(clean_value "${update_throughput}"),$(clean_value "${versions_created}"),${validation},${exit_code},${status},${log_file}" \
    >> "${CSV_PATH}"

  [[ "${status}" == OK ]]
}

for data_structure in "${DATA_STRUCTURES[@]}"; do
  for workload in "${WORKLOAD_LIST[@]}"; do
    for thread_count in "${THREAD_LIST[@]}"; do
      for ds_size in "${DS_SIZE_LIST[@]}"; do
        for trial in $(seq 1 "${TRIALS}"); do
          if ! run_trial "${data_structure}" "${workload}" "${thread_count}" "${ds_size}" "${trial}"; then
            failures=$((failures + 1))
          fi
        done
      done
    done
  done
done

echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${METADATA_PATH}"
echo "failures=${failures}" >> "${METADATA_PATH}"
echo "Completed task ${TASK_LABEL}; failures: ${failures}"
echo "CSV: ${CSV_PATH}"

if (( failures > 0 )); then
  exit 1
fi
