#!/usr/bin/env bash
# Build optimized, assertions-disabled binaries for the Cartesian experiment.
# Invoke with: bash build_experiment_variants.sh

set -euo pipefail

BUILD_JOBS="${BUILD_JOBS:-8}"
MAX_THREADS="${MAX_THREADS:-128}"
ARRAY_SIZES=(1 5 10 25 50 100 200 500 1000 2000 4000)

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

build_one() {
  local data_structure="$1"
  local label="$2"
  local compile_flags="$3"
  local source_binary="bin/${data_structure}.debra"
  local output_binary="bin/${data_structure}.${label}.debra"

  echo "Building ${data_structure} (${label})"
  make -B -j"${BUILD_JOBS}" "${data_structure}.debra" \
    no_optimize=0 \
    use_asserts=0 \
    has_libpapi=0 \
    max_threads="${MAX_THREADS}" \
    xargs="${compile_flags}"
  cp -f "${source_binary}" "${output_binary}"
}

for data_structure in "${FIXED_DATA_STRUCTURES[@]}"; do
  build_one "${data_structure}" fixed ""
done

for data_structure in "${ARRAY_DATA_STRUCTURES[@]}"; do
  for array_size in "${ARRAY_SIZES[@]}"; do
    build_one "${data_structure}" "a${array_size}" \
      "-DFATNODE_ARRAY_SIZE=${array_size}"
  done
done

echo
echo "Experiment binaries built:"
ls -1 bin/*.fixed.debra bin/*.a*.debra
