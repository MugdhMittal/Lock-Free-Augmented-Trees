#!/usr/bin/env bash
# Merge the per-task CSV files produced by a completed Slurm campaign.
# Invoke with: bash merge_cartesian_csvs.sh <campaign-id>

set -euo pipefail

CAMPAIGN_ID="${1:?Usage: merge_cartesian_csvs.sh <campaign-id>}"
CAMPAIGN_ROOT="results/cartesian/${CAMPAIGN_ID}"
OUTPUT_CSV="${CAMPAIGN_ROOT}/trials.csv"

mapfile -t CSV_FILES < <(find "${CAMPAIGN_ROOT}" -mindepth 2 -name trials.csv -type f | sort)
if (( ${#CSV_FILES[@]} == 0 )); then
  echo "No task CSV files found under ${CAMPAIGN_ROOT}" >&2
  exit 1
fi

head -n1 "${CSV_FILES[0]}" > "${OUTPUT_CSV}"
for csv_file in "${CSV_FILES[@]}"; do
  tail -n +2 "${csv_file}" >> "${OUTPUT_CSV}"
done

echo "Merged ${#CSV_FILES[@]} task CSV files."
echo "Rows (including header): $(wc -l < "${OUTPUT_CSV}")"
echo "Output: ${OUTPUT_CSV}"
