#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Benchmark sweep for augmented trie variants (setbench)
# Loops Trie_v2 .. Trie_v7 for ONE array size (compiled beforehand).
# Prompts for array_size and csv_path interactively.
# Comment out trie names / threads / sizes / workloads below as needed.
# ---------------------------------------------------------------------------

# --- Interactive inputs ---
read -rp "Enter array size (as compiled): " ARRAY_SIZE
read -rp "Enter CSV output path [default: results.csv]: " CSV_PATH
CSV_PATH="${CSV_PATH:-results_benchmark.csv}"

# --- Trie versions to run (comment out any you don't want this run) ---
TRIE_NAMES=(
    # Trie_v1
    # Trie_v2
    # Trie_v3
    # Trie_v4
    # Trie_v5
    # Trie_v6
    Trie_v7
)

TRIALS=2
THREADS=(1 2 4 8 12 16 22)
DATA_SIZES=(2000 20000 50000 100000)
WORKLOAD_PCTS=(1 25 50)

RQ=0
RQSIZE=1
NRQ=0
TIME_MS=3000

# Write CSV header only if file doesn't exist yet
if [[ ! -f "$CSV_PATH" ]]; then
    echo "file_executed,array_size,workload,threads,ds_size_k,time_ms,throughput,num_versions_created" > "$CSV_PATH"
fi

# --- Precompute total run count for progress display ---
total=$(( ${#TRIE_NAMES[@]} * ${#THREADS[@]} * ${#DATA_SIZES[@]} * ${#WORKLOAD_PCTS[@]} * TRIALS ))
run_count=0

for TRIE_NAME in "${TRIE_NAMES[@]}"; do
    BIN="./bin/${TRIE_NAME}.new.debra.pnone"

    if [[ ! -x "$BIN" ]]; then
        echo "WARNING: binary not found, skipping: $BIN" >&2
        continue
    fi

    LOG_ROOT="raw_logs_${TRIE_NAME}_arr${ARRAY_SIZE}"
    mkdir -p "$LOG_ROOT"

    for k in "${DATA_SIZES[@]}"; do
        for pct in "${WORKLOAD_PCTS[@]}"; do
            for nthreads in "${THREADS[@]}"; do

                # --- Accumulate metrics across trials for this parameter combo ---
                throughputs=()
                time_mss=()
                num_versionss=()

                for trial in $(seq 1 "$TRIALS"); do
                    run_count=$((run_count + 1))
                    logdir="${LOG_ROOT}/k${k}/${pct}pct/t${nthreads}"
                    mkdir -p "$logdir"
                    logfile="${logdir}/trial${trial}.log"

                    echo "[$run_count/$total] ${TRIE_NAME} arr=${ARRAY_SIZE} k=${k} workload=${pct}% threads=${nthreads} trial=${trial}"

                    "$BIN" \
                        -nwork "$nthreads" \
                        -nprefill "$nthreads" \
                        -i "$pct" \
                        -d "$pct" \
                        -rq "$RQ" \
                        -rqsize "$RQSIZE" \
                        -k "$k" \
                        -nrq "$NRQ" \
                        -t "$TIME_MS" \
                        > "$logfile" 2>&1

                    # --- Parse metrics from log ---
                    throughput=$(grep -m1 '^total_throughput=' "$logfile" | cut -d= -f2 || true)
                    time_ms=$(grep -m1 '^elapsed milliseconds' "$logfile" | awk -F: '{print $2}' | tr -d ' ' || true)
                    # "Total versions created" appears twice; take the LAST occurrence (post-run)
                    num_versions=$(grep '^Total versions created' "$logfile" | tail -n1 | awk -F= '{print $2}' | tr -d ' ' || true)

                    throughputs+=("${throughput:-NA}")
                    time_mss+=("${time_ms:-NA}")
                    num_versionss+=("${num_versions:-NA}")
                done

                # --- Average across trials (NA entries are ignored; NA if all trials NA) ---
                avg_throughput=$(printf '%s\n' "${throughputs[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_time_ms=$(printf '%s\n' "${time_mss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_num_versions=$(printf '%s\n' "${num_versionss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')

                echo "${TRIE_NAME},${ARRAY_SIZE},${pct}pct,${nthreads},${k},${avg_time_ms},${avg_throughput},${avg_num_versions}" >> "$CSV_PATH"

            done
        done
    done
done

echo "Done. $run_count runs completed."
echo "Results appended to: $CSV_PATH"