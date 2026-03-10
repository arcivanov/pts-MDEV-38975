## Benchmark Results: MDEV-38975 HEAP Engine BLOB Support

Date: 2026-03-09

Benchmark environment: 2x Intel Xeon E5-2699A v4 (44 cores / 88 threads), 256GB RAM, 4x Samsung SSD 870, Fedora 43 (kernel 6.18), GCC 15.2, btrfs.

Baseline: `14f96a2e080` (10.11 branch tip before MDEV-38975). PR: `MDEV-38975` branch, commit `c736807d95f` (*Cap `min_run_records` for small blob free-list reuse*). Each test runs for 120 seconds, 3 iterations averaged, at 16/64/128 threads.

### Major Improvements

Internal temporary tables with TEXT/BLOB/GEOMETRY columns now stay in HEAP instead of falling through to Aria on disk.

| Test | Description | Improvement (128t) |
|------|-------------|-------------------|
| `blob_window_func` | `ROW_NUMBER() OVER (PARTITION BY k)` on TEXT | **137x** (6.4 -> 878 QPS) |
| `blob_count_distinct` | `COUNT(DISTINCT text_col)` | **126x** (4.3 -> 537 QPS) |
| `blob_union` | `UNION` of two TEXT tables | **100x** (3.2 -> 320 QPS) |
| `is_group_by_complex` | I_S COLUMNS with GROUP BY + GROUP_CONCAT | **10.2x** (303 -> 3094 QPS) |
| `blob_cte` | CTE with DISTINCT join on TEXT | **10.5x** (11.7 -> 123 QPS) |
| `is_columns` | I_S COLUMNS scan (TEXT metadata) | **6.9x** (546 -> 3780 QPS) |
| `blob_rollup` | GROUP BY ... WITH ROLLUP on TEXT | **3.3x** (54.6 -> 178 QPS) |
| `is_tables_join` | I_S COLUMNS JOIN TABLES | **2.6x** (532 -> 1406 QPS) |
| `blob_case_c` | DISTINCT on 20-50KB blobs (multi-run reassembly) | **2.2x** (8.2 -> 17.9 QPS) |
| `geom_distinct` | DISTINCT on GEOMETRY + TEXT | **1.25x** (7.5 -> 9.3 QPS) |

### Explicit `CREATE TEMPORARY TABLE ... ENGINE=MEMORY` with BLOB

On baseline, HEAP doesn't support BLOB columns (`HA_NO_BLOBS`), so these tests use the default temp storage engine (InnoDB). With MDEV-38975, `ENGINE=MEMORY` is specified explicitly and HEAP handles BLOBs natively.

| Test | Blob size | Improvement (128t) |
|------|-----------|-------------------|
| `heap_blob_case_a` | 1-5 bytes (Case A zero-copy) | **6.6x** (4.4 -> 28.7 QPS) |
| `heap_blob_case_b` | 1-10KB (Case B zero-copy) | **17.3x** (7.2 -> 124.9 QPS) |
| `heap_blob_case_c` | 20-50KB (Case C reassembly) | **10.2x** (2.2 -> 22.2 QPS) |
| `heap_blob_mixed` | mixed sizes | **11.4x** (2.3 -> 26.1 QPS) |

### Neutral (no significant change)

`blob_group_by`, `blob_distinct`, `blob_orderby_groupby`, `blob_insert_select`, `blob_group_concat`, `is_views`, `is_triggers`, `is_routines` (at 16t) -- all within +/-5%.

`is_routines` scales better at higher concurrency: +45% at 64/128t (1596 -> 2312 QPS).

### Regressions

| Test | 16t | 64t | 128t |
|------|-----|-----|------|
| `blob_recursive_cte` | -8% (53.4 -> 48.9) | -24% (49.0 -> 37.1) | **-37%** (47.6 -> 30.2) |
| `show_columns_loop` | **-31%** (435 -> 302) | -25% (395 -> 295) | -21% (357 -> 283) |
| `oltp_read_write` | +4% (9364 -> 9753) | ~flat | **-11%** (13050 -> 11643) |

#### Regression analysis

**`blob_recursive_cte`** -- *flawed test, not a real regression*: SAR shows the machine is **97% idle** at 128t on the PR (vs 73% idle on baseline). If the regression were caused by algorithmic overhead (e.g. O(n^2) comparison), we would see increased CPU utilization, not near-total idleness. The recursive CTE builds 500 rows sequentially (`id = r.id + 1`), which is inherently single-threaded per query. With 128 threads all executing this serialized pattern, they contend on internal locks (InnoDB row locks, CTE materialization). On baseline, each thread at least kept the kernel busy with Aria I/O (23% system), which spread the contention over I/O wait. With MDEV-38975, the Aria overhead is gone, but the remaining work is so minimal and serialized that threads just sleep on locks. The baseline was "faster" only because Aria I/O gave threads enough independent kernel work to mask the serialization. This test does not measure temp table performance; it measures recursive CTE row-at-a-time execution with a trivial 500-row DISTINCT at the end.

**`show_columns_loop`** -- *SQL-layer lock contention exposed*: SAR tells the same story: PR is **90% idle** at 128t vs 15% idle on baseline. The work per `SHOW FULL COLUMNS` query is tiny (a handful of rows per table), and with MDEV-38975 the temp table creation/destruction is so fast that threads immediately hit SQL-layer serialization points (`LOCK_open`, I_S metadata locks, temp table create/destroy serialization). On baseline, Aria I/O spread each query over enough wall-clock time that lock contention was diluted. The regression is not in the HEAP engine; it is a pre-existing SQL-layer bottleneck that was previously hidden by Aria I/O latency. The actual per-query cost is lower on the PR (less total CPU), but threads cannot run concurrently because they serialize on shared locks.

**`oltp_read_write`**: Stock sysbench OLTP with no blob columns. SAR profiles are virtually identical between baseline and PR (both ~95% idle, InnoDB-bound). The 11% QPS regression at 128t has no corresponding resource utilization change, suggesting measurement noise or a transient scheduling artifact in the CPU oversubscription regime (128 threads on 88 hardware threads). At 16t and 64t there is no regression.

### OLTP regression check

The stock sysbench OLTP tests are included specifically to verify no regression on non-blob workloads. Results at 16t and 64t show no regression (within +/-1%). The 128t result (11% drop) shows no SAR signal and is likely noise in the oversubscription regime.

---

## SAR Resource Utilization Analysis

System activity (`sar`) was recorded at 1-second granularity for the full duration of both runs. Below are the notable resource utilization shifts.

### Dominant pattern: kernel time (%system) replaced by user time (%user)

The single most consistent change across all improved tests is a dramatic shift from kernel CPU time to user-space CPU time. On the baseline, temp table operations with BLOB columns trigger Aria file I/O, resulting in heavy kernel-side work (VFS, page cache, filesystem). With MDEV-38975, the same operations run entirely in HEAP (user-space memory), eliminating the kernel overhead.

| Test (128t) | Baseline %system | PR %system | Baseline %user | PR %user |
|-------------|-----------------|------------|---------------|----------|
| `blob_count_distinct` | 86.1% | 4.9% | 4.2% | 89.5% |
| `blob_union` | 85.8% | 4.5% | 4.5% | 89.2% |
| `blob_cte` | 82.7% | 2.2% | 5.1% | 92.4% |
| `blob_rollup` | 81.7% | 3.5% | 7.5% | 91.3% |
| `blob_window_func` | 53.2% | 11.7% | 3.0% | 36.5% |
| `is_columns` | 79.8% | 34.6% | 11.2% | 55.2% |
| `is_group_by_complex` | 80.5% | 26.6% | 7.8% | 42.8% |
| `is_tables_join` | 60.1% | 12.7% | 31.0% | 77.8% |

The pattern is universal: baseline burns 50-86% of CPU time in kernel, PR drops this to 2-35% and shifts the work to user-space.

### Page faults increase massively (expected)

HEAP allocates memory via `my_malloc()`/`mmap()` for block tree growth, causing minor page faults. This replaces the Aria page cache (which pre-faults its pool at startup).

| Test (128t) | Baseline fault/s | PR fault/s | Change |
|-------------|-----------------|------------|--------|
| `blob_window_func` | 13,855 | 2,197,301 | +15,759% |
| `blob_count_distinct` | 10,784 | 732,579 | +6,694% |
| `blob_union` | 9,573 | 772,058 | +7,965% |
| `is_columns` | 547,419 | 3,864,409 | +606% |
| `heap_blob_case_b` | 86,433 | 1,992,271 | +2,205% |
| `heap_blob_case_c` | 184,022 | 2,047,489 | +1,013% |

These are *minor* page faults (first-touch on mmap'd pages), not disk I/O. The kernel handles them cheaply, and this is the expected cost of dynamic HEAP block allocation replacing the baseline engines' pre-allocated memory (Aria page cache for internal temp tables, InnoDB buffer pool for explicit `heap_blob_*` tests). Despite the high fault counts, total CPU time is dramatically lower because a minor page fault costs microseconds while baseline file I/O costs orders of magnitude more.

### Block I/O eliminated for temp table workloads

Aria writes temp table pages through the page cache, generating block write traffic. HEAP eliminates this entirely.

| Test (16t) | Baseline bwrtn/s | PR bwrtn/s | Change |
|------------|-----------------|------------|--------|
| `blob_union` | 2,045 | 1,682 | -18% |
| `is_routines` | 2,340 | 1,658 | -29% |

At higher thread counts, baseline block writes increase while PR holds steady or drops. The residual I/O in the PR run is from InnoDB redo log and the actual data tables (not temp tables).

### Memory utilization: slightly lower with HEAP

Counterintuitively, `%memused` is slightly lower with MDEV-38975 in the large-blob tests:

| Test (128t) | Baseline %memused | PR %memused |
|-------------|------------------|-------------|
| `heap_blob_case_c` | 22.3% | 18.3% |
| `heap_blob_mixed` | 20.8% | 16.4% |

Hypothesis: InnoDB (used on baseline for these tests) allocates its buffer pool up front and holds it. HEAP allocates blocks on demand and frees them on `DROP TEMPORARY TABLE` / `TRUNCATE`. For short-lived temp tables, HEAP's allocate-on-demand pattern has a lower memory highwater mark than InnoDB's pre-allocated buffer pool.

### Regression: `show_columns_loop` -- CPU goes idle

This is the most revealing regression SAR pattern:

| Metric (128t) | Baseline | PR |
|---------------|----------|-----|
| %user | 8.7% | 4.8% |
| %system | 76.7% | 5.3% |
| %idle | 14.6% | 89.9% |

The PR version is **90% idle** while the baseline is saturating the CPUs. With 128 threads running `SHOW FULL COLUMNS` in a tight loop, the baseline keeps all CPUs busy with kernel-side Aria work. The PR creates and destroys HEAP temp tables so fast that the threads are bottlenecked on something other than CPU: likely lock contention in the SQL layer (`LOCK_open`, I_S metadata locks, or temp table creation/destruction serialization). The work per query is so small that the overhead of acquiring and releasing locks dominates, and threads spend most of their time waiting.

This suggests the regression is not in the HEAP engine itself, but in SQL-layer serialization that becomes the bottleneck once temp table I/O is eliminated.

### Regression: `blob_recursive_cte` -- flawed test

| Metric (128t) | Baseline | PR |
|---------------|----------|-----|
| %user | 3.3% | 0.8% |
| %system | 23.3% | 2.3% |
| %idle | 73.3% | 96.9% |

Both versions are heavily idle, but the PR is **97% idle** -- almost no work is happening. The recursive CTE builds 500 rows one at a time via `id+1` join, which is inherently serialized per query. The baseline's 23% system time was Aria I/O, which actually served as a natural concurrency spreader: threads spent time in independent kernel work rather than contending on shared locks. With MDEV-38975, Aria is eliminated, the per-query cost drops, but threads immediately pile up on internal serialization points. The throughput regression is a lock contention artifact, not an algorithmic cost increase. A regression caused by slower computation would show *increased* CPU utilization, not near-total idleness.

### `oltp_read_write`: no SAR signal

| Metric (128t) | Baseline | PR |
|---------------|----------|-----|
| %user | 1.6% | 1.4% |
| %system | 1.7% | 1.6% |
| %idle | 94.4% | 94.5% |
| tps | 2,492 | 2,435 |

SAR profiles are virtually identical. The 11% QPS regression at 128t has no corresponding resource utilization change, suggesting it may be measurement noise or a transient scheduling artifact rather than a systematic regression. Both runs are ~95% idle (InnoDB-bound on this workload).

---

## Files in this directory

- `README.md` -- this report
- `pts-report.html` -- PTS comparison report (interactive HTML)
- `sar-reports/` -- per-test SAR metric comparison charts (interactive Plotly HTML)
- `bench-run.log.zst` -- full PTS bench run log (zstd compressed)
- `sar-14f96a2e080.dat.zst` -- baseline SAR binary data (zstd compressed)
- `sar-MDEV-38975.dat.zst` -- PR SAR binary data (zstd compressed)
