#!/usr/bin/env bash
set -euo pipefail

bundle_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workloads=${1:-"$bundle_root/workloads.tsv"}
label=${2:-$(date +%Y%m%d_%H%M%S)}
[[ -f $workloads ]] || { printf 'Workload file not found: %s\n' "$workloads" >&2; exit 1; }
[[ $label =~ ^[A-Za-z0-9_-]+$ ]] || { printf 'Invalid run label: %s\n' "$label" >&2; exit 2; }

result_dir="$bundle_root/results/$label"
mkdir -p "$result_dir"
count=0
failures=0

while IFS=$'\t' read -r structure threads keys insert delete milliseconds prefill || \
      [[ -n ${structure:-} ]]; do
    [[ -z ${structure:-} || $structure == \#* ]] && continue
    count=$((count + 1))
    logfile="$result_dir/$(printf '%03d' "$count")_${structure}_${threads}t_${keys}k_${insert}i_${delete}d.log"
    printf '[%d] %s threads=%s keys=%s insert=%s delete=%s ms=%s prefill=%s\n' \
        "$count" "$structure" "$threads" "$keys" "$insert" "$delete" "$milliseconds" "$prefill"
    if bash "$bundle_root/run.sh" --ds "$structure" --threads "$threads" \
        --keys "$keys" --insert "$insert" --delete "$delete" \
        --ms "$milliseconds" --prefill "$prefill" >"$logfile" 2>&1 \
        && grep -Fq 'Structural validation OK.' "$logfile"; then
        printf '  PASS  %s\n' "$logfile"
    else
        failures=$((failures + 1))
        printf '  FAIL  %s\n' "$logfile" >&2
    fi
done < "$workloads"

((count > 0)) || { printf 'No workloads found in %s\n' "$workloads" >&2; exit 2; }
printf 'Completed %d workloads; %d failed.\n' "$count" "$failures"
((failures == 0))
