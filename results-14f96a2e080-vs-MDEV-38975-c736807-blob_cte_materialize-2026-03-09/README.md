## Benchmark Results: blob_cte_materialize (MDEV-38975 Follow-up)

Date: 2026-03-09

This is a targeted re-run of the CTE materialization test only, replacing the flawed
`blob_recursive_cte` test from the full suite run. The original test was serialized
(row-at-a-time recursive CTE), producing 97% idle CPU at 128 threads and an apparent
37% regression that was actually lock contention on idle threads, not algorithmic cost.

### Test Design

`blob_cte_materialize` uses a non-recursive CTE with dual reference (forces
materialization into a HEAP temp table), then self-joins on `k` with blob comparison:

```sql
WITH cte AS (SELECT text_col, text_col2, k FROM blob_data WHERE id <= 10000)
SELECT SQL_NO_CACHE SUM(LENGTH(a.text_col) + LENGTH(b.text_col2))
FROM cte a JOIN cte b ON a.k = b.k
WHERE a.text_col > b.text_col
```

This exercises:
- HEAP blob chain **writes** (~20K blobs materialized into temp table)
- HEAP blob chain **reads** (~100K reads via nested loop join)
- Blob **data comparison** (~50K pairs via `a.text_col > b.text_col`)

### Environment

2x Intel Xeon E5-2699A v4 (44 cores / 88 threads), 256GB RAM, 4x Samsung SSD 870,
Fedora 43 (kernel 6.18), GCC 15.2, btrfs.

Baseline: `14f96a2e080` (10.11 branch tip before MDEV-38975).
PR: `MDEV-38975` branch, commit `c736807d95f`.
Each test: 120 seconds, 3 iterations averaged, at 16/64/128 threads.

### Results

| Threads | Baseline (QPS) | MDEV-38975 (QPS) | Delta |
|---------|---------------|-------------------|-------|
| 16 | 12.48 | 12.18 | -2.4% |
| 64 | 16.22 | 15.84 | -2.3% |
| 128 | 17.94 | 18.35 | +2.3% |

**No regression.** All deltas are within noise (< 3%).

### SAR Profile (128 threads)

| Metric | Baseline | MDEV-38975 | Delta |
|--------|----------|------------|-------|
| %user | 93.9% | 93.9% | 0.0% |
| %system | 0.6% | 0.6% | +0.9% |
| %idle | 5.5% | 5.5% | +0.2% |

Both builds are fully CPU-bound at 128 threads with identical SAR profiles. This
confirms the test is exercising actual computation (blob materialization and comparison),
not serializing on locks like the old `blob_recursive_cte` test did.

### Conclusion

The CTE materialization path with blob columns shows no performance regression from
MDEV-38975. The HEAP engine's blob continuation chain write, read, and comparison
operations perform equivalently to baseline Aria-based temp table I/O for this workload.

### Files

- `composite.xml` — PTS raw result data
- `pts-report.html` — PTS comparison report
- `bench-run.log` — full PTS console output
- `sar-14f96a2e080.dat.zst` — SAR recording (baseline)
- `sar-MDEV-38975.dat.zst` — SAR recording (MDEV-38975)
- `sar-reports/` — interactive SAR comparison charts (Plotly HTML)
