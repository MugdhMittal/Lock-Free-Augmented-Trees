#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Benchmark sweep for the augmented trees and tries (setbench).
#   Phase 1 (trees): Lock_Free_Tree_Augmented, Lock_Free_Tree_Augmented_FatNodePtrs
#   Phase 2 (tries): Trie_Baseline, Trie_FatNode_ChildVC, Trie_FatNode_ChildPtr,
#                    Trie_FatNode_NoVC
# Step 1 compiles every binary once (one per array size for the fat-node
# structures) into bin/lft/; Step 2 runs the sweep with those binaries.
# Comment out structures / threads / sizes / workloads below as needed.
#
# Usage (from microbench/):
#   bash run_lft_benchmark.sh          # build (reusing existing binaries), then run
#   bash run_lft_benchmark.sh build    # build only
#   REBUILD=1 bash run_lft_benchmark.sh   # force a fresh build first
#
# Requirements: Linux x86-64, bash, GNU make, g++ (C++17 + OpenMP), libatomic,
# at least max(THREADS) hardware threads, and ~16 GB RAM for array size 500
# at k=200000. PAPI and NUMA are not needed (forced off at compile time).
#
# Output (only this directory needs to be pushed):
#   results/<RUN_ID>/results.csv   one averaged row per combination
#   results/<RUN_ID>/raw_logs/...  every trial's full log
#   results/<RUN_ID>/metadata.txt  machine, compiler, commit, parameters
# ---------------------------------------------------------------------------

cd "$(dirname "$0")"

# --- Structures to run (comment out any you don't want this run) ---
TREE_FIXED=(
    Lock_Free_Tree_Augmented
)
TREE_ARRAY=(
    Lock_Free_Tree_Augmented_FatNodePtrs
)
TRIE_FIXED=(
    Trie_Baseline
)
TRIE_ARRAY=(
    Trie_FatNode_ChildVC
    Trie_FatNode_ChildPtr
    Trie_FatNode_NoVC
)

ARRAY_SIZES=(1 10 100 500)
TRIALS=2
THREADS=(1 2 4 8 16 28)
DATA_SIZES=(1000 50000 200000)
WORKLOAD_PCTS=(50 25 1)

RQ=0
RQSIZE=1
NRQ=0
TIME_MS=3000

BIN_DIR="bin/lft"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
REBUILD="${REBUILD:-0}"
RUN_ID="${RUN_ID:-lft_$(date +%Y%m%d_%H%M%S)}"
RESULTS_DIR="results/${RUN_ID}"
CSV_PATH="${RESULTS_DIR}/results.csv"
METADATA_PATH="${RESULTS_DIR}/metadata.txt"
MODE="${1:-all}"

# --- Preflight ---
for tool in make g++ awk grep; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool not found: $tool" >&2
        exit 1
    fi
done

max_threads_needed=0
for t in "${THREADS[@]}"; do (( t > max_threads_needed )) && max_threads_needed=$t; done
if [[ "$MODE" != build ]] && (( $(nproc) < max_threads_needed )) && [[ "${ALLOW_OVERSUBSCRIBE:-0}" != 1 ]]; then
    echo "ERROR: this machine has $(nproc) hardware threads but THREADS goes up to ${max_threads_needed}." >&2
    echo "       Oversubscription invalidates the results; set ALLOW_OVERSUBSCRIBE=1 to run anyway." >&2
    exit 1
fi

mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
if (( mem_total_kb < 16 * 1024 * 1024 )); then
    echo "WARNING: $((mem_total_kb / 1024 / 1024)) GB RAM; array size 500 at k=200000 may need ~16 GB." >&2
fi

TIME_CMD=""
if [[ -x /usr/bin/time ]]; then
    TIME_CMD="/usr/bin/time"
else
    echo "NOTE: /usr/bin/time not found, peak_rss_kb will be NA." >&2
fi

# --- Binary list: "family|structure|array_size|binary" ---
JOBS=()
for ds in "${TREE_FIXED[@]}"; do JOBS+=("tree|${ds}|NA|${BIN_DIR}/${ds}.debra"); done
for ds in "${TREE_ARRAY[@]}"; do
    for a in "${ARRAY_SIZES[@]}"; do JOBS+=("tree|${ds}|${a}|${BIN_DIR}/${ds}_arr${a}.debra"); done
done
for ds in "${TRIE_FIXED[@]}"; do JOBS+=("trie|${ds}|NA|${BIN_DIR}/${ds}.debra"); done
for ds in "${TRIE_ARRAY[@]}"; do
    for a in "${ARRAY_SIZES[@]}"; do JOBS+=("trie|${ds}|${a}|${BIN_DIR}/${ds}_arr${a}.debra"); done
done

# ===========================================================================
# Step 1: build every binary once
# ===========================================================================
mkdir -p "$BIN_DIR"
build_total=${#JOBS[@]}
build_count=0
echo "=== Building ${build_total} binaries into ${BIN_DIR}/ (REBUILD=${REBUILD}) ==="
for job in "${JOBS[@]}"; do
    IFS='|' read -r family ds arr bin <<< "$job"
    build_count=$((build_count + 1))
    if [[ "$REBUILD" != 1 && -x "$bin" ]]; then
        echo "[${build_count}/${build_total}] ${ds} arr=${arr}: reusing ${bin}"
        continue
    fi
    echo "[${build_count}/${build_total}] Building ${ds} arr=${arr}"
    array_flag=""
    [[ "$arr" != NA ]] && array_flag="-DFATNODE_ARRAY_SIZE=${arr}"
    build_log="${BIN_DIR}/build_$(basename "$bin" .debra).log"
    if ! make -B -j"$BUILD_JOBS" "${ds}.debra" \
            DATA_STRUCTURES="$ds" \
            bin_dir="$BIN_DIR" \
            no_optimize=0 \
            use_asserts=0 \
            has_libpapi=0 \
            has_libnuma=0 \
            max_threads=32 \
            xargs="$array_flag" > "$build_log" 2>&1; then
        echo "ERROR: build failed for ${ds} arr=${arr}; see ${build_log}:" >&2
        grep -m 20 -E "error|Error" "$build_log" >&2
        exit 1
    fi
    if [[ "$arr" != NA ]]; then
        cp -f "${BIN_DIR}/${ds}.debra" "$bin"
    fi
done

if [[ "$MODE" == build ]]; then
    echo "Build complete."
    exit 0
fi

# ===========================================================================
# Step 2: run the sweep
# ===========================================================================
mkdir -p "${RESULTS_DIR}/raw_logs"

per_structure=$(( ${#DATA_SIZES[@]} * ${#WORKLOAD_PCTS[@]} * ${#THREADS[@]} * TRIALS ))
tree_runs=0
trie_runs=0
for job in "${JOBS[@]}"; do
    IFS='|' read -r family _ _ _ <<< "$job"
    if [[ "$family" == tree ]]; then tree_runs=$((tree_runs + per_structure)); else trie_runs=$((trie_runs + per_structure)); fi
done
total=$((tree_runs + trie_runs))

{
    echo "run_id=${RUN_ID}"
    echo "started=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "hostname=$(hostname)"
    echo "cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    echo "hardware_threads=$(nproc)"
    echo "mem_total_kb=${mem_total_kb}"
    echo "gxx_version=$(g++ --version | head -n1)"
    echo "kernel=$(uname -r)"
    echo "git_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "git_dirty=$(git status --porcelain -- ../ds ../microbench/main.cpp ../microbench/Makefile 2>/dev/null | grep -q . && echo yes || echo no)"
    echo "build_flags=no_optimize=0 use_asserts=0 has_libpapi=0 has_libnuma=0 max_threads=32 reclaimer=debra"
    echo "tree_structures=${TREE_FIXED[*]} ${TREE_ARRAY[*]}"
    echo "trie_structures=${TRIE_FIXED[*]} ${TRIE_ARRAY[*]}"
    echo "array_sizes=${ARRAY_SIZES[*]}"
    echo "threads=${THREADS[*]}"
    echo "ds_sizes_k=${DATA_SIZES[*]}"
    echo "workload_pcts=${WORKLOAD_PCTS[*]}"
    echo "trials=${TRIALS}"
    echo "time_ms=${TIME_MS}"
    echo "total_runs=${total}"
} > "$METADATA_PATH"

# CSV header
trial_cols=""
for i in $(seq 1 "$TRIALS"); do trial_cols+=",throughput_trial${i}"; done
if [[ ! -f "$CSV_PATH" ]]; then
    echo "file_executed,family,array_size,workload,insert_pct,delete_pct,lookup_pct,threads,ds_size_k,time_ms,elapsed_ms,trials_ok,validation,keysum_match,throughput${trial_cols},throughput_spread_pct,find_throughput,update_throughput,total_ops,total_find,total_inserts,total_deletes,total_updates,ops_per_thread_min,ops_per_thread_max,ops_per_thread_stdev,versions_created,versions_per_update,versions_per_op,find_prev_entries,find_ftlv_calls,upd_prev_entries,upd_ftlv_calls,avg_prev_hops_per_find,avg_prev_hops_per_find_ftlv,avg_prev_hops_per_update,avg_prev_hops_per_update_ftlv,avg_prev_hops_per_op,prefill_size,prefill_ms,peak_rss_kb,object_sizes" > "$CSV_PATH"
fi

echo
echo "=== Total runs: ${total} (tree: ${tree_runs}, trie: ${trie_runs}) ==="
echo "Trees:       ${TREE_FIXED[*]} ${TREE_ARRAY[*]}"
echo "Tries:       ${TRIE_FIXED[*]} ${TRIE_ARRAY[*]}"
echo "Array sizes: ${ARRAY_SIZES[*]} (fat-node structures only)"
echo "DS sizes(k): ${DATA_SIZES[*]}"
echo "Workloads:   ${WORKLOAD_PCTS[*]} (% insert = % delete)"
echo "Threads:     ${THREADS[*]}"
echo "Trials:      ${TRIALS} x ${TIME_MS} ms"
echo "Results:     ${RESULTS_DIR}/"
echo

# --- Log parsing helpers ---
# Value after "key=" on the first matching line; empty if absent.
value_of() { grep -m1 "^$1=" "$2" | cut -d= -f2- | tr -d ' \r' || true; }
# GSTATS counter; gstats prints an empty value when the total is zero.
counter_of() {
    if grep -q "^$1=" "$2"; then
        local v; v=$(value_of "$1" "$2"); echo "${v:-0}"
    else
        echo "NA"
    fi
}
# Mean of the non-NA values in "$@"; NA if none.
mean_of() { printf '%s\n' "$@" | awk '$1!="NA" && $1!="" {s+=$1; n++} END {if (n>0) printf "%.2f", s/n; else print "NA"}'; }
# a / b with 4 decimals; NA if either is NA or b is 0.
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (a=="NA" || b=="NA" || b+0==0) print "NA"; else printf "%.4f", a/b }'; }
fmt_hms() { local s=$1; printf '%d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); }

run_count=0
failures=0
sweep_start=$(date +%s)

for job in "${JOBS[@]}"; do
    IFS='|' read -r FAMILY DS_NAME ARRAY_SIZE BIN <<< "$job"

    if [[ ! -x "$BIN" ]]; then
        echo "WARNING: binary not found, skipping: $BIN" >&2
        run_count=$((run_count + per_structure))
        failures=$((failures + per_structure))
        continue
    fi

    LOG_ROOT="${RESULTS_DIR}/raw_logs/${DS_NAME}_arr${ARRAY_SIZE}"

    for k in "${DATA_SIZES[@]}"; do
        for pct in "${WORKLOAD_PCTS[@]}"; do
            for nthreads in "${THREADS[@]}"; do

                # --- Accumulate metrics across trials for this parameter combo ---
                declare -A M=()
                metrics=(throughput find_throughput update_throughput elapsed_ms total_ops total_find total_inserts total_deletes total_updates ops_min ops_max ops_stdev versions find_prev find_ftlv upd_prev upd_ftlv prefill_size prefill_ms peak_rss)
                for m in "${metrics[@]}"; do M[$m]=""; done
                trials_ok=0
                validated=0
                keysum_ok=0
                object_sizes="NA"

                for trial in $(seq 1 "$TRIALS"); do
                    run_count=$((run_count + 1))
                    logdir="${LOG_ROOT}/k${k}/${pct}pct/t${nthreads}"
                    mkdir -p "$logdir"
                    logfile="${logdir}/trial${trial}.log"

                    printf '[%d/%d] %s arr=%s k=%s workload=%spct threads=%s trial=%s ... ' \
                        "$run_count" "$total" "$DS_NAME" "$ARRAY_SIZE" "$k" "$pct" "$nthreads" "$trial"

                    run_cmd=("$BIN"
                        -nwork "$nthreads"
                        -nprefill "$nthreads"
                        -i "$pct"
                        -d "$pct"
                        -rq "$RQ"
                        -rqsize "$RQSIZE"
                        -k "$k"
                        -nrq "$NRQ"
                        -t "$TIME_MS")
                    if [[ -n "$TIME_CMD" ]]; then
                        timeout --signal=KILL $((TIME_MS / 1000 + 900)) \
                            "$TIME_CMD" -v -a -o "$logfile" "${run_cmd[@]}" > "$logfile" 2>&1
                    else
                        timeout --signal=KILL $((TIME_MS / 1000 + 900)) \
                            "${run_cmd[@]}" > "$logfile" 2>&1
                    fi
                    exit_code=$?

                    # --- Parse metrics from log ---
                    throughput=$(value_of total_throughput "$logfile")
                    valid=no
                    grep -q '^Structural validation OK\.' "$logfile" && valid=yes
                    if [[ $exit_code -eq 0 && $valid == yes && -n "$throughput" ]]; then
                        trials_ok=$((trials_ok + 1))
                    fi
                    [[ $valid == yes ]] && validated=$((validated + 1))

                    threads_keysum=$(value_of threads_final_keysum "$logfile")
                    ds_keysum=$(grep -m1 '^ds_final_keysum' "$logfile" | sed 's/^ds_final_keysum=\{0,1\}//' | tr -d ' \r' || true)
                    [[ -n "$threads_keysum" && "$threads_keysum" == "$ds_keysum" ]] && keysum_ok=$((keysum_ok + 1))

                    M[throughput]+="${throughput:-NA} "
                    M[find_throughput]+="$(value_of find_throughput "$logfile") "
                    M[update_throughput]+="$(value_of update_throughput "$logfile") "
                    M[elapsed_ms]+="$(grep -m1 '^elapsed milliseconds' "$logfile" | awk -F: '{print $2}' | tr -d ' \r' || true) "
                    M[total_ops]+="$(value_of total_ops "$logfile") "
                    M[total_find]+="$(value_of total_find "$logfile") "
                    M[total_inserts]+="$(value_of total_inserts "$logfile") "
                    M[total_deletes]+="$(value_of total_deletes "$logfile") "
                    M[total_updates]+="$(value_of total_updates "$logfile") "
                    M[versions]+="$(counter_of sum_versions_created_total "$logfile") "
                    M[find_prev]+="$(counter_of sum_find_prev_entries_total "$logfile") "
                    M[find_ftlv]+="$(counter_of sum_find_ftlv_calls_total "$logfile") "
                    M[upd_prev]+="$(counter_of sum_upd_prev_entries_total "$logfile") "
                    M[upd_ftlv]+="$(counter_of sum_upd_ftlv_calls_total "$logfile") "
                    M[prefill_size]+="$(value_of pref_size "$logfile") "
                    M[prefill_ms]+="$(value_of prefill_elapsed_ms "$logfile") "
                    M[peak_rss]+="$(grep -m1 'Maximum resident set size' "$logfile" | awk -F: '{print $2}' | tr -d ' \r' || true) "

                    # Per-thread operation counts (inserts + deletes + finds) -> min/max/stdev
                    read -r ops_min ops_max ops_stdev < <(awk -v T="$nthreads" '
                        /^sum_num_inserts_by_thread=/  { split(substr($0, index($0,"=")+1), a, " "); for (i in a) ops[i]+=a[i]; ni=length(a) }
                        /^sum_num_deletes_by_thread=/  { split(substr($0, index($0,"=")+1), a, " "); for (i in a) ops[i]+=a[i]; nd=length(a) }
                        /^sum_num_searches_by_thread=/ { split(substr($0, index($0,"=")+1), a, " "); for (i in a) ops[i]+=a[i]; ns=length(a) }
                        END {
                            n = ni > nd ? ni : nd; n = n > ns ? n : ns
                            if (n != T) { print "NA NA NA"; exit }
                            mn = ops[1]; mx = ops[1]; s = 0
                            for (i = 1; i <= n; i++) { if (ops[i] < mn) mn = ops[i]; if (ops[i] > mx) mx = ops[i]; s += ops[i] }
                            mean = s / n; v = 0
                            for (i = 1; i <= n; i++) v += (ops[i] - mean) ^ 2
                            printf "%d %d %.2f\n", mn, mx, sqrt(v / n)
                        }' "$logfile")
                    M[ops_min]+="${ops_min:-NA} "
                    M[ops_max]+="${ops_max:-NA} "
                    M[ops_stdev]+="${ops_stdev:-NA} "

                    sizes_line=$(grep -m1 '^sizes:' "$logfile" | sed 's/^sizes: *//; s/ /;/g' | tr -d '\r' || true)
                    [[ -n "$sizes_line" ]] && object_sizes="$sizes_line"

                    now=$(date +%s)
                    elapsed=$((now - sweep_start))
                    eta=$(( elapsed * (total - run_count) / run_count ))
                    if [[ $exit_code -eq 0 && $valid == yes ]]; then
                        printf 'OK throughput=%s (elapsed %s, ETA %s)\n' "${throughput:-NA}" "$(fmt_hms $elapsed)" "$(fmt_hms $eta)"
                    else
                        failures=$((failures + 1))
                        printf 'FAILED (exit=%s, validation=%s) log=%s (elapsed %s, ETA %s)\n' \
                            "$exit_code" "$valid" "$logfile" "$(fmt_hms $elapsed)" "$(fmt_hms $eta)"
                    fi
                done

                # --- Average across trials (NA entries are ignored; NA if all trials NA) ---
                declare -A A=()
                for m in "${metrics[@]}"; do
                    # shellcheck disable=SC2086
                    A[$m]=$(mean_of ${M[$m]})
                done

                # shellcheck disable=SC2206
                tp=(${M[throughput]})
                trial_vals=""
                for v in "${tp[@]}"; do trial_vals+=",${v}"; done
                spread=$(printf '%s\n' "${tp[@]}" | awk '$1!="NA" {if (n==0||$1<mn) mn=$1; if (n==0||$1>mx) mx=$1; s+=$1; n++} END {if (n>1 && s>0) printf "%.2f", (mx-mn)/(s/n)*100; else print "NA"}')

                validation="FAIL"
                (( validated == TRIALS )) && validation="OK"
                keysum_match="NA"
                if [[ "$FAMILY" == trie ]]; then
                    keysum_match="NO"; (( keysum_ok == TRIALS )) && keysum_match="YES"
                fi

                lookup_pct=$((100 - 2 * pct))
                echo "${DS_NAME},${FAMILY},${ARRAY_SIZE},${pct}pct,${pct},${pct},${lookup_pct},${nthreads},${k},${TIME_MS},${A[elapsed_ms]},${trials_ok}/${TRIALS},${validation},${keysum_match},${A[throughput]}${trial_vals},${spread},${A[find_throughput]},${A[update_throughput]},${A[total_ops]},${A[total_find]},${A[total_inserts]},${A[total_deletes]},${A[total_updates]},${A[ops_min]},${A[ops_max]},${A[ops_stdev]},${A[versions]},$(ratio "${A[versions]}" "${A[total_updates]}"),$(ratio "${A[versions]}" "${A[total_ops]}"),${A[find_prev]},${A[find_ftlv]},${A[upd_prev]},${A[upd_ftlv]},$(ratio "${A[find_prev]}" "${A[total_find]}"),$(ratio "${A[find_prev]}" "${A[find_ftlv]}"),$(ratio "${A[upd_prev]}" "${A[total_updates]}"),$(ratio "${A[upd_prev]}" "${A[upd_ftlv]}"),$(ratio "$(awk -v a="${A[find_prev]}" -v b="${A[upd_prev]}" 'BEGIN{if(a=="NA"||b=="NA")print "NA"; else print a+b}')" "${A[total_ops]}"),${A[prefill_size]},${A[prefill_ms]},${A[peak_rss]},${object_sizes}" >> "$CSV_PATH"
                unset M A
            done
        done
    done
done

{
    echo "finished=$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "failed_runs=${failures}"
} >> "$METADATA_PATH"

echo
echo "Done. ${run_count} runs completed, ${failures} failed."
echo "Results: ${CSV_PATH}"
echo "Raw logs: ${RESULTS_DIR}/raw_logs/"
