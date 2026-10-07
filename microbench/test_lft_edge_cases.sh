#!/bin/bash
set -uo pipefail

# ---------------------------------------------------------------------------
# Edge-case checks for the structures used by run_lft_benchmark.sh.
# Run this once on a new machine before the sweep.
#
#   Part 1 (unit): compiles lft_edge_test.cpp once per structure (array sizes
#     1 and 10 for the fat-node ones) against the real headers and adapters,
#     and checks find/insert/erase/keySum/validateStructure against a
#     reference for tiny and non-power-of-two key ranges, Version overflow,
#     and concurrent updates.
#   Part 2 (binaries): builds the sweep binaries (bash run_lft_benchmark.sh
#     build; they are reused by the sweep) and runs each at the extremes of
#     the sweep for 500 ms: maximum threads on the smallest key range, and the
#     largest key range with the largest array size.
#
# Usage (from microbench/):  bash test_lft_edge_cases.sh
# Logs go to bin/lft/test_logs/ (not part of the results).
# ---------------------------------------------------------------------------

cd "$(dirname "$0")"

UNIT_DIR="bin/lft/unit"
TEST_LOG_DIR="bin/lft/test_logs"
mkdir -p "$UNIT_DIR" "$TEST_LOG_DIR"

FIXED_STRUCTURES=(Lock_Free_Tree_Augmented Trie_Baseline)
ARRAY_STRUCTURES=(Lock_Free_Tree_Augmented_FatNodePtrs Trie_FatNode_ChildVC Trie_FatNode_ChildPtr Trie_FatNode_NoVC)
TRIE_STRUCTURES=" Trie_Baseline Trie_FatNode_ChildVC Trie_FatNode_ChildPtr Trie_FatNode_NoVC "

MAX_THREADS=28
(( $(nproc) < MAX_THREADS )) && MAX_THREADS=$(nproc)

failures=0
checks=0

# ===========================================================================
# Part 1: unit edge cases
# ===========================================================================
UNIT_FLAGS=(-std=c++17 -O2 -g -mcx16 -fopenmp
    -DMAX_THREADS_POW2=32 -DCPU_FREQ_GHZ=2.1
    "-DMEMORY_STATS=if(1)" "-DMEMORY_STATS2=if(0)" -DDEBRA_ORIGINAL_FREE)
# shellcheck disable=SC2207
INCLUDES=(-I./ -I../ $(find ../common -type d | sed 's/^/-I/'))

UNIT_CASES=()
for ds in "${FIXED_STRUCTURES[@]}"; do UNIT_CASES+=("$ds NA"); done
for ds in "${ARRAY_STRUCTURES[@]}"; do UNIT_CASES+=("$ds 1" "$ds 10"); done

echo "=== Part 1: unit edge cases (${#UNIT_CASES[@]} builds) ==="
for case_ in "${UNIT_CASES[@]}"; do
    read -r ds arr <<< "$case_"
    checks=$((checks + 1))
    exe="${UNIT_DIR}/${ds}_arr${arr}"
    log="${TEST_LOG_DIR}/unit_${ds}_arr${arr}.log"
    array_flag=()
    [[ "$arr" != NA ]] && array_flag=(-DFATNODE_ARRAY_SIZE="$arr")
    printf '[unit] %s arr=%s ... ' "$ds" "$arr"
    if ! g++ "${UNIT_FLAGS[@]}" "${array_flag[@]}" lft_edge_test.cpp -o "$exe" \
            -I"../ds/${ds}" "${INCLUDES[@]}" -lpthread -ldl -latomic > "$log" 2>&1; then
        failures=$((failures + 1))
        echo "FAIL (compile error, see $log)"
        continue
    fi
    if timeout 600 "$exe" >> "$log" 2>&1 && grep -q '^RESULT: ALL PASSED' "$log"; then
        echo "PASS ($(grep -c '^PASS' "$log") cases)"
    else
        failures=$((failures + 1))
        echo "FAIL"
        grep -E '^FAIL|Segmentation|Aborted|terminate' "$log" | head -5 | sed 's/^/    /'
        echo "    full log: $log"
    fi
done

# ===========================================================================
# Part 2: sweep binaries at the extremes
# ===========================================================================
echo
echo "=== Part 2: building sweep binaries (bash run_lft_benchmark.sh build) ==="
if ! bash run_lft_benchmark.sh build; then
    echo "FAIL: building the sweep binaries failed; Part 2 skipped."
    failures=$((failures + 1))
else
    # "binary threads key_range pct"
    RUNS=()
    for ds in "${FIXED_STRUCTURES[@]}"; do
        RUNS+=("bin/lft/${ds}.debra ${MAX_THREADS} 1000 50"
               "bin/lft/${ds}.debra 1 200000 1"
               "bin/lft/${ds}.debra ${MAX_THREADS} 200000 50")
    done
    for ds in "${ARRAY_STRUCTURES[@]}"; do
        RUNS+=("bin/lft/${ds}_arr1.debra ${MAX_THREADS} 1000 50"
               "bin/lft/${ds}_arr500.debra ${MAX_THREADS} 1000 50"
               "bin/lft/${ds}_arr500.debra 1 200000 1"
               "bin/lft/${ds}_arr500.debra ${MAX_THREADS} 200000 50")
    done

    echo
    echo "=== Part 2: ${#RUNS[@]} short runs (500 ms each) ==="
    for run in "${RUNS[@]}"; do
        read -r bin t k pct <<< "$run"
        checks=$((checks + 1))
        name=$(basename "$bin" .debra)
        log="${TEST_LOG_DIR}/run_${name}_t${t}_k${k}_${pct}pct.log"
        printf '[run] %s threads=%s k=%s workload=%spct ... ' "$name" "$t" "$k" "$pct"
        timeout --signal=KILL 900 "$bin" -nwork "$t" -nprefill "$t" -i "$pct" -d "$pct" \
            -rq 0 -rqsize 1 -k "$k" -nrq 0 -t 500 > "$log" 2>&1
        exit_code=$?
        why=""
        (( exit_code != 0 )) && why+="exit=${exit_code} "
        grep -q '^Structural validation OK\.' "$log" || why+="no 'Structural validation OK.' "
        grep -q '^total_throughput=' "$log" || why+="no throughput line "
        ds_name=${name%_arr*}
        if [[ "$TRIE_STRUCTURES" == *" ${ds_name} "* ]]; then
            tk=$(grep -m1 '^threads_final_keysum=' "$log" | cut -d= -f2)
            dk=$(grep -m1 '^ds_final_keysum' "$log" | sed 's/^ds_final_keysum=\{0,1\}//')
            [[ -n "$tk" && "$tk" == "$dk" ]] || why+="keysum mismatch (threads=${tk:-?} ds=${dk:-?}) "
        fi
        if [[ -z "$why" ]]; then
            echo "PASS throughput=$(grep -m1 '^total_throughput=' "$log" | cut -d= -f2)"
        else
            failures=$((failures + 1))
            echo "FAIL: ${why}(log: $log)"
        fi
    done
fi

echo
if (( failures == 0 )); then
    echo "ALL ${checks} CHECKS PASSED. The sweep can be started:"
    echo "  nohup bash run_lft_benchmark.sh > lft_run.out 2>&1 &"
    exit 0
fi
echo "${failures} of ${checks} CHECKS FAILED. Fix these before running the sweep."
exit 1
