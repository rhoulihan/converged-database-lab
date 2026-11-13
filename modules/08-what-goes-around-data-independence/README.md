# Module 08: What Goes Around Comes Around, and Data Independence

Runnable proofs for anchor article 8. Every script runs against the live lab
container and emits machine-checkable rows:

- `ASSERT:<name>:PASS|FAIL` is a check. The validator fails if any check fails.
- `METRIC:<name>:<value>` is a measurement. The validator stores it in
  `validator/results.json` under `"metrics"`, and the article takes its numbers
  from there. Checks look at direction and trend, never at exact numbers.

---

## Harness: `scripts/00-meter.sql`

Creates the `m08_meter` package and the `m08_metrics` session table that the
later scripts use to measure work. Safe to run more than once.

- `m08_meter.snap` remembers the session's current counters.
- `m08_meter.delta('session logical reads' | 'redo size' | 'execute count')`
  returns how much that counter grew since the last `snap`.
- `m08_meter.record(name, value)` stores a named measurement.

Expected assertions:

```
ASSERT:m08-meter-ready:PASS
```

## Proofs

_To be added as the demonstration scripts land._
