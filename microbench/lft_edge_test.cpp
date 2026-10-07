/**
 * Edge-case test for the LFT tree and trie variants, driven through their
 * setbench adapters (the same calls microbench/main.cpp makes).
 *
 * Built once per data structure by test_lft_edge_cases.sh, e.g.
 *   g++ ... -I../ds/Trie_FatNode_NoVC -DFATNODE_ARRAY_SIZE=1 lft_edge_test.cpp
 *
 * Checks, for several key ranges (including tiny and non-power-of-two ones):
 *   - empty structure: find / erase / keySum / validateStructure
 *   - sequential inserts, duplicate inserts, missing erases, boundary keys,
 *     erasing down to empty; find is checked against a reference for EVERY key
 *   - one key toggled many times (forces repeated Version overflow)
 *   - concurrent updates on thread-partitioned keys with a concurrent reader,
 *     then a full find-vs-reference check, keySum and validateStructure
 * Prints PASS/FAIL per case and exits non-zero on any failure.
 */
#define MICROBENCH
typedef long long test_type;

#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "errors.h"
#include "plaf.h"
int MAXKEY = 0;
#include "globals_extern.h"
#include "random_xoshiro256pp.h"
#include "adapter.h"

#define VALUE_TYPE void*
using Adapter = ds_adapter<test_type, VALUE_TYPE>;

static VALUE_TYPE const NO_VALUE = nullptr;
static int failures = 0;

static VALUE_TYPE val(test_type k) { return (VALUE_TYPE)k; }

static void report(const std::string& name, bool ok, const std::string& why) {
    if (ok) {
        std::cout << "PASS " << name << std::endl;
    } else {
        std::cout << "FAIL " << name << ": " << why << std::endl;
        ++failures;
    }
}

// Same construction as main.cpp: KEY_MIN = 0, KEY_MAX = max() - 1, keys are
// drawn from [1, MAXKEY].
static Adapter* make_adapter(int key_range, int num_threads, Random64* rngs) {
    MAXKEY = key_range;
    return new Adapter(num_threads, 0,
                       std::numeric_limits<test_type>::max() - 1, NO_VALUE,
                       rngs);
}

// Compares find() for every key in [1, K] against the reference.
static bool check_all_keys(Adapter* ds, int tid, int K,
                           const std::vector<char>& present,
                           std::string& why) {
    for (test_type k = 1; k <= K; ++k) {
        VALUE_TYPE got = ds->find(tid, k);
        VALUE_TYPE want = present[k] ? val(k) : NO_VALUE;
        if (got != want) {
            std::ostringstream os;
            os << "find(" << k << ") returned " << (long long)got
               << ", expected " << (long long)want;
            why = os.str();
            return false;
        }
    }
    return true;
}

static int64_t reference_keysum(int K, const std::vector<char>& present) {
    int64_t sum = 0;
    for (test_type k = 1; k <= K; ++k)
        if (present[k]) sum += k;
    return sum;
}

static bool check_final_state(Adapter* ds, int tid, int K,
                              const std::vector<char>& present,
                              std::string& why) {
    if (!check_all_keys(ds, tid, K, present, why)) return false;
    if (!ds->validateStructure()) {
        why = "validateStructure() failed";
        return false;
    }
    const int64_t want = reference_keysum(K, present);
    const int64_t got = ds->keySum();
    if (got != want) {
        std::ostringstream os;
        os << "keySum() = " << got << ", expected " << want;
        why = os.str();
        return false;
    }
    return true;
}

static void test_empty(int K, Random64* rngs) {
    std::string name = "empty k=" + std::to_string(K), why;
    Adapter* ds = make_adapter(K, 1, rngs);
    ds->initThread(0);
    std::vector<char> present(K + 1, 0);
    bool ok = check_final_state(ds, 0, K, present, why);
    for (test_type k = 1; ok && k <= K; ++k) {
        if (ds->erase(0, k) != NO_VALUE) {
            ok = false;
            why = "erase(" + std::to_string(k) + ") on empty succeeded";
        }
    }
    if (ok) ok = check_final_state(ds, 0, K, present, why);
    ds->deinitThread(0);
    delete ds;
    report(name, ok, why);
}

static void test_sequential(int K, Random64* rngs) {
    std::string name = "sequential k=" + std::to_string(K), why;
    Adapter* ds = make_adapter(K, 1, rngs);
    ds->initThread(0);
    std::vector<char> present(K + 1, 0);
    bool ok = true;

    // Insert odd keys plus both boundary keys.
    for (test_type k = 1; ok && k <= K; ++k) {
        if (k % 2 == 1 || k == K) {
            if (ds->insertIfAbsent(0, k, val(k)) != NO_VALUE) {
                ok = false;
                why = "insert(" + std::to_string(k) + ") reported present";
            }
            present[k] = 1;
        }
    }
    if (ok) ok = check_final_state(ds, 0, K, present, why);

    // Duplicate inserts must fail and leave the structure unchanged.
    for (test_type k = 1; ok && k <= K; ++k) {
        if (present[k] && ds->insertIfAbsent(0, k, val(k)) == NO_VALUE) {
            ok = false;
            why = "duplicate insert(" + std::to_string(k) + ") succeeded";
        }
    }
    // Erasing absent keys must fail.
    for (test_type k = 1; ok && k <= K; ++k) {
        if (!present[k] && ds->erase(0, k) != NO_VALUE) {
            ok = false;
            why = "erase(" + std::to_string(k) + ") of absent key succeeded";
        }
    }
    if (ok) ok = check_final_state(ds, 0, K, present, why);

    // Erase every other present key, then the rest (down to empty).
    for (int pass = 0; pass < 2 && ok; ++pass) {
        int seen = 0;
        for (test_type k = 1; ok && k <= K; ++k) {
            if (!present[k]) continue;
            if (pass == 1 || (seen++ % 2 == 0)) {
                if (ds->erase(0, k) == NO_VALUE) {
                    ok = false;
                    why = "erase(" + std::to_string(k) + ") of present key failed";
                }
                present[k] = 0;
            }
        }
        if (ok) ok = check_final_state(ds, 0, K, present, why);
    }
    ds->deinitThread(0);
    delete ds;
    report(name, ok, why);
}

static void test_toggle(int K, int rounds, Random64* rngs) {
    std::string name = "toggle k=" + std::to_string(K) + " x" +
                       std::to_string(rounds), why;
    Adapter* ds = make_adapter(K, 1, rngs);
    ds->initThread(0);
    std::vector<char> present(K + 1, 0);
    const test_type k = (K + 1) / 2;
    bool ok = true;
    for (int i = 0; ok && i < rounds; ++i) {
        if (ds->insertIfAbsent(0, k, val(k)) != NO_VALUE) {
            ok = false;
            why = "insert failed in round " + std::to_string(i);
        } else if (ds->find(0, k) != val(k)) {
            ok = false;
            why = "find after insert failed in round " + std::to_string(i);
        } else if (ds->erase(0, k) == NO_VALUE) {
            ok = false;
            why = "erase failed in round " + std::to_string(i);
        } else if (ds->find(0, k) != NO_VALUE) {
            ok = false;
            why = "find after erase failed in round " + std::to_string(i);
        }
    }
    if (ok) {
        ds->insertIfAbsent(0, k, val(k));
        present[k] = 1;
        ok = check_final_state(ds, 0, K, present, why);
    }
    ds->deinitThread(0);
    delete ds;
    report(name, ok, why);
}

// Each worker owns the keys with (k % workers == tid), so every return value
// is deterministic even though all workers run concurrently.
static void test_concurrent(int K, int workers, int ops_per_worker,
                            Random64* rngs) {
    std::string name = "concurrent k=" + std::to_string(K) + " threads=" +
                       std::to_string(workers) + "+reader", why;
    const int reader_tid = workers;
    Adapter* ds = make_adapter(K, workers + 1, rngs);
    std::vector<char> present(K + 1, 0);
    std::atomic<bool> done{false};
    std::atomic<int> bad_returns{0};
    std::atomic<int> bad_reads{0};

    std::vector<std::thread> threads;
    for (int tid = 0; tid < workers; ++tid) {
        threads.emplace_back([&, tid]() {
            ds->initThread(tid);
            Random64 rng(tid * 7919 + 17);
            std::vector<test_type> mine;
            for (test_type k = 1; k <= K; ++k)
                if (k % workers == tid) mine.push_back(k);
            if (!mine.empty()) {
                for (int i = 0; i < ops_per_worker; ++i) {
                    test_type k = mine[rng.next() % mine.size()];
                    if (rng.next() % 2) {
                        VALUE_TYPE r = ds->insertIfAbsent(tid, k, val(k));
                        if ((r == NO_VALUE) == (bool)present[k]) ++bad_returns;
                        present[k] = 1;
                    } else {
                        VALUE_TYPE r = ds->erase(tid, k);
                        if ((r != NO_VALUE) != (bool)present[k]) ++bad_returns;
                        present[k] = 0;
                    }
                }
            }
            ds->deinitThread(tid);
        });
    }
    std::thread reader([&]() {
        ds->initThread(reader_tid);
        Random64 rng(424242);
        while (!done.load()) {
            test_type k = 1 + rng.next() % K;
            VALUE_TYPE r = ds->find(reader_tid, k);
            if (r != NO_VALUE && r != val(k)) ++bad_reads;
        }
        ds->deinitThread(reader_tid);
    });
    for (auto& t : threads) t.join();
    done = true;
    reader.join();

    bool ok = true;
    if (bad_returns) {
        ok = false;
        why = std::to_string(bad_returns.load()) +
              " insert/erase return values disagreed with the reference";
    } else if (bad_reads) {
        ok = false;
        why = std::to_string(bad_reads.load()) +
              " concurrent finds returned a value for the wrong key";
    } else {
        ds->initThread(0);
        ok = check_final_state(ds, 0, K, present, why);
        ds->deinitThread(0);
    }
    delete ds;
    report(name, ok, why);
}

int main() {
    Random64 rngs[MAX_THREADS_POW2];
    for (int i = 0; i < MAX_THREADS_POW2; ++i) rngs[i].setSeed(i + 1);

    const int small_ranges[] = {1, 2, 3, 7, 1000, 1001};
    for (int K : small_ranges) {
        test_empty(K, rngs);
        test_sequential(K, rngs);
        test_toggle(K, 2000, rngs);
    }
    test_concurrent(7, 8, 20000, rngs);
    test_concurrent(1001, 8, 50000, rngs);
    test_concurrent(20000, 8, 50000, rngs);

    std::cout << (failures ? "RESULT: FAIL (" + std::to_string(failures) +
                                 " failed)"
                           : std::string("RESULT: ALL PASSED"))
              << std::endl;
    return failures ? 1 : 0;
}
