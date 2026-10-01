# Portable SetBench microbenchmarks

This directory contains its own copies of the SetBench `microbench`, `common`,
`ds`, and `tools` sources. It can be copied or pulled as part of this repository
and built without a separate SetBench installation or submodule initialization.
The included Makefile selects the four fat-node structures by default. Other
copied `ds` adapters can be selected through `DATA_STRUCTURES`; only the four
default targets have been verified in the standalone bundle.

## Requirements

Use a compatible Linux x86_64 node with Bash, GNU Make, `g++` with C++17 and
OpenMP support, and the usual pthread, dl, and atomic libraries. The copied
Makefile uses `-mcx16` and `-mrtm`. PAPI and NUMA are optional; the commands
below disable both. A benchmark process uses shared-memory threads on one
node. Submit it through your site's scheduler if your system requires one.

## Compile with the Makefile

From this directory:

```bash
cd microbench
make -B -j4 has_libpapi=0 has_libnuma=0 no_optimize=0 \
  DATA_STRUCTURES='Trie_FatNode_ChildPtr Trie_FatNode_NoVC Trie_FatNode_NoVC_Optimised Lock_Free_Tree_Augmented_FatNodePtrs' \
  RECLAIMERS=debra xargs='-DFATNODE_ARRAY_SIZE=100' ds-reclaim
cd ..
```

The binaries appear in `microbench/bin/`. To compile one structure, set
`DATA_STRUCTURES` to its directory name. `FATNODE_ARRAY_SIZE` controls the
number of slots in the NoVC tries and fat-node-pointer BST; their default is
10 when the macro is omitted. `Trie_FatNode_ChildPtr` defines `ARRAY_SIZE=1`
in its own header, so that macro does not change it. Use `make -B` whenever
you change a compile-time option, because Make does not track flag changes.

## Run the binaries

One workload:

```bash
bash run.sh --ds Trie_FatNode_NoVC_Optimised --threads 8 --keys 2000 \
  --insert 25 --delete 25 --ms 3000 --prefill 0
```

Run the rows in `workloads.tsv` sequentially, saving a log for each:

```bash
bash run_workloads.sh workloads.tsv slots100
```

Edit the tab-separated rows of `workloads.tsv` to choose structures, thread
counts, key ranges, operation percentages, durations, and prefill thread
counts. The optional second argument labels the run, so rebuilding with a
different `FATNODE_ARRAY_SIZE` can use a different results directory (for
example, `slots1` or `slots500`). With no label, the runner uses a timestamp.
It reports a failure when the process fails or structural validation does not
succeed. Logs go to `results/LABEL/`. For additional SetBench
arguments on a single run, append them after `--` in `run.sh`. To compile a
different slot count, rebuild first, then run the workload again.

`microbench/bin/` and `results/` are ignored by Git. Commit and push the
sources in this directory; compile binaries on each destination system.
