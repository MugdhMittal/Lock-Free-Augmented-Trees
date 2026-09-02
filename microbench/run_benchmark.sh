#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Benchmark sweep for augmented trie variants (setbench)
# Loops Trie_FatNode .. Trie_FatNode_NoChain for ONE array size (compiled beforehand).
# Prompts for array_size and csv_path interactively.
# Comment out trie names / threads / sizes / workloads below as needed.
# ---------------------------------------------------------------------------

# --- Interactive inputs ---
read -rp "Enter array size (as compiled): " ARRAY_SIZE
read -rp "Enter CSV output path [default: results.csv]: " CSV_PATH
CSV_PATH="${CSV_PATH:-testing_2.csv}"

# --- Trie versions to run (comment out any you don't want this run) ---
TRIE_NAMES=(
    # Trie_Baseline
    Trie_FatNode
    Trie_FatNode_ChildVC
    Trie_FatNode_ChildVC_PadSlot
    Trie_FatNode_ChildVC_PadSlot_A64
    Trie_FatNode_ChildVC_PadVerSlot
    Trie_FatNode_ChildVC_PadVerSlot_A64
    Trie_FatNode_NoChain
    Trie_FatNode_PadFull
    Trie_FatNode_PadFull_A64
    Trie_FatNode_PadSlot
    Trie_FatNode_PadSlot_A64
    Trie_FatNode_PadVerSlot
    Trie_FatNode_PadVerSlot_A64
    # Trie_v3
    # Trie_v4
)

TRIALS=2
THREADS=(1 4 16)
DATA_SIZES=(20000)
WORKLOAD_PCTS=(1 25 50)

RQ=0
RQSIZE=1
NRQ=0
TIME_MS=2000

# Write CSV header only if file doesn't exist yet
if [[ ! -f "$CSV_PATH" ]]; then
    echo "file_executed,array_size,workload,threads,ds_size_k,time_ms,throughput,versions_created,find_prev_entries,find_ftlv_calls,upd_prev_entries,upd_ftlv_calls,avg_prev_hops_per_find,avg_prev_hops_per_update,avg_prev_hops_per_op" > "$CSV_PATH"
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
                find_prev_entriess=()
                find_ftlv_callss=()
                upd_prev_entriess=()
                upd_ftlv_callss=()
                avg_hops_finds=()
                avg_hops_upds=()
                avg_hops_ops=()


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
                    find_prev_entries=$(grep -m1 '^sum_find_prev_entries_total=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    find_ftlv_calls=$(grep -m1 '^sum_find_ftlv_calls_total=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    upd_prev_entries=$(grep -m1 '^sum_upd_prev_entries_total=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    upd_ftlv_calls=$(grep -m1 '^sum_upd_ftlv_calls_total=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    total_find=$(grep -m1 '^total_find=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    total_updates=$(grep -m1 '^total_updates=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    total_ops=$(grep -m1 '^total_ops=' "$logfile" | cut -d= -f2 | tr -d ' ' || true)
                    avg_hops_find=$(awk -v p="${find_prev_entries:-0}" -v t="${total_find:-0}" 'BEGIN { if (t > 0 && p > 0) printf "%.4f", p/t; else print "NA" }')
                    avg_hops_upd=$(awk -v p="${upd_prev_entries:-0}" -v t="${total_updates:-0}" 'BEGIN { if (t > 0 && p > 0) printf "%.4f", p/t; else print "NA" }')
                    avg_hops_op=$(awk -v fp="${find_prev_entries:-0}" -v up="${upd_prev_entries:-0}" -v t="${total_ops:-0}" 'BEGIN { if (t > 0) printf "%.4f", (fp+up)/t; else print "NA" }')

                    
                    throughputs+=("${throughput:-NA}")
                    time_mss+=("${time_ms:-NA}")
                    num_versionss+=("${num_versions:-NA}")
                    find_prev_entriess+=("${find_prev_entries:-NA}")
                    find_ftlv_callss+=("${find_ftlv_calls:-NA}")
                    upd_prev_entriess+=("${upd_prev_entries:-NA}")
                    upd_ftlv_callss+=("${upd_ftlv_calls:-NA}")
                    avg_hops_finds+=("${avg_hops_find:-NA}")
                    avg_hops_upds+=("${avg_hops_upd:-NA}")
                    avg_hops_ops+=("${avg_hops_op:-NA}")

                done

                # --- Average across trials (NA entries are ignored; NA if all trials NA) ---
                avg_throughput=$(printf '%s\n' "${throughputs[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_time_ms=$(printf '%s\n' "${time_mss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_num_versions=$(printf '%s\n' "${num_versionss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_find_prev=$(printf '%s\n' "${find_prev_entriess[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_find_ftlv=$(printf '%s\n' "${find_ftlv_callss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_upd_prev=$(printf '%s\n' "${upd_prev_entriess[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_upd_ftlv=$(printf '%s\n' "${upd_ftlv_callss[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_hops_per_find=$(printf '%s\n' "${avg_hops_finds[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_hops_per_upd=$(printf '%s\n' "${avg_hops_upds[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')
                avg_hops_per_op=$(printf '%s\n' "${avg_hops_ops[@]}" | awk '$1!="NA"{s+=$1; n++} END {print (n>0)? s/n : "NA"}')


                echo "${TRIE_NAME},${ARRAY_SIZE},${pct}pct,${nthreads},${k},${avg_time_ms},${avg_throughput},${avg_num_versions},${avg_find_prev},${avg_find_ftlv},${avg_upd_prev},${avg_upd_ftlv},${avg_hops_per_find},${avg_hops_per_upd},${avg_hops_per_op}" >> "$CSV_PATH"

            done
        done
    done
done

echo "Done. $run_count runs completed."
echo "Results appended to: $CSV_PATH"