# Benchmark Scripts & Reference

---

## Time Estimate

| Parameter | Value |
|---|---|
| Run duration | 5 000 ms |
| Overhead per run (prefill + teardown) | ~7 s |
| Effective time per run | ~12 s |
| Runs per config | 2 (averaged into 1 CSV row) |
| Manual recompile window | ~90 s |

### Phase 1 — Array-size sweep (v1, v2, v3, v5)

- ARRAY_SIZE values: **1, 10, 100, 1000, 2000** — you run the script once per value
- Thread counts tested: 16, 32
- Configs per run: 4 DS × 2 threads × 3 workloads × 3 DS-sizes = **72**
- Time per run: 72 × 24 s + 90 s recompile = **~30 min per ARRAY_SIZE**
- **Phase 1 total: 5 × 30 min = ~150 min**

### Phase 2 — Thread-count sweep (v1, v2, v3, v5)

- Thread counts: **1, 2, 4, 8, 16, 24, 28, 32**
- Configs: 4 DS × 8 threads × 3 workloads × 3 DS-sizes = **288**
- Time: 288 × 24 s + 90 s recompile = **~117 min**

### Grand total: **~267 min ≈ 4 hrs 27 min**

> ⚠️ This is tight. To stay within 4 hours you have two options:
> - **Option A (recommended):** Run Phase 1 with only 3 ARRAY_SIZE values (e.g. 1, 100, 2000) → saves 60 min → total ~207 min = 3 hrs 27 min.
> - **Option B:** Drop Phase 1 thread count to just 32 → halves Phase 1 → total ~225 min = 3 hrs 45 min.

---

## Compile Commands

### Ubuntu / WSL2

```bash
# Standard compile (from microbench/)
make -j all

# Clean and recompile
make clean && make -j all

# Verify binaries exist
ls bin/ | grep -E "Trie_v[1235]"
```

> Note: ARRAY_SIZE is set in the source header (`static const int ARRAY_SIZE = N;`  
> in `Trie_v2.h`, `Trie_v3.h`, `Trie_v5.h`). Edit that value, save, then run `make -j all`.

### PowerShell (Windows)

```powershell
# Standard compile (from microbench\)
mingw32-make -j $env:NUMBER_OF_PROCESSORS all

# Clean and recompile
mingw32-make clean; mingw32-make -j $env:NUMBER_OF_PROCESSORS all

# Verify binaries
Get-ChildItem bin\ | Where-Object { $_.Name -match "Trie_v[1235]" }
```

> If `mingw32-make` is not found, try `make` — depends on your MinGW/MSYS2 install.

---

## Running the Scripts

### Ubuntu / WSL2 (bash scripts)

```bash
# Make executable once (only needed the first time)
chmod +x phase1_array_sweep.sh
chmod +x phase2_thread_sweep.sh

# Run Phase 1 (repeat for each ARRAY_SIZE after recompiling)
./phase1_array_sweep.sh

# Run Phase 2 (once, after picking the best ARRAY_SIZE)
./phase2_thread_sweep.sh
```

### PowerShell (`.ps1` scripts)

```powershell
# One-time setup — allow local scripts to run (only needed once per machine)
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# Run Phase 1
.\phase1_array_sweep.ps1

# Run Phase 2
.\phase2_thread_sweep.ps1
```

> There is no `chmod` equivalent needed in PowerShell. The `Set-ExecutionPolicy`
> command above is the only one-time step required.

---

## Workflow

### Phase 1 (repeat 5 times, once per ARRAY_SIZE)

```
1. Edit ARRAY_SIZE in Trie_v2.h / Trie_v3.h / Trie_v5.h
2. make -j all          (Ubuntu)  OR  mingw32-make -j %NUMBER_OF_PROCESSORS% all  (PowerShell)
3. ./phase1_array_sweep.sh        (Ubuntu)  OR  .\phase1_array_sweep.ps1           (PowerShell)
4. When prompted, enter the ARRAY_SIZE value you just compiled with.
5. Script runs all 4 binaries automatically. Results append to results.csv.
```

### Phase 2 (run once)

```
1. Look at results.csv — pick the ARRAY_SIZE that gave best throughput.
2. Edit + recompile with that ARRAY_SIZE (same as above).
3. ./phase2_thread_sweep.sh       (Ubuntu)  OR  .\phase2_thread_sweep.ps1          (PowerShell)
4. When prompted, enter the best ARRAY_SIZE (used as the CSV label for v2/v3/v5).
5. Script sweeps all thread counts across all 4 binaries.
```

---

## CSV Header & Output Files

**`results.csv`** — both scripts append to this same file:

```
file_executed,array_size,workload,threads,ds_size_k,time_ms,throughput,num_versions_created,validate_structure
```

- `array_size` = the ARRAY_SIZE you entered, or `NA` for Trie_v1
- `time_ms` = average of 2 runs (from `elapsed milliseconds` in output)
- `throughput` = average of 2 runs (from `total_throughput=` in output)
- `num_versions_created` = average of 2 runs (post-run `Total versions created =` — the second occurrence in the output, after the benchmark finishes)
- `validate_structure` = `OK` or `FAIL` (from `Structural validation OK.`)

**`logs/`** — every individual run is saved as:

```
logs/<binary>_arr<ARRAY_SIZE>_t<threads>_<workload>_k<ds_size>_run<1|2>.txt
```

Example:
```
logs/Trie_v2.new.debra.pnone_arr100_t16_w_heavy_k20000_run1.txt
logs/Trie_v2.new.debra.pnone_arr100_t16_w_heavy_k20000_run2.txt
```

---

## Field Parsing — How Values Are Extracted

| CSV field | Source line in output | Grep / parse |
|---|---|---|
| `time_ms` | `elapsed milliseconds          : 3000` | `grep "elapsed milliseconds"` → field after `:` |
| `throughput` | `total_throughput=173775` | `grep "^total_throughput="` → after `=` |
| `num_versions_created` | `Total versions created = 7821000` (appears twice; second is post-run) | `grep "Total versions created"` + `tail -1` → after `= ` |
| `validate_structure` | `Structural validation OK.` | presence/absence of this string |
