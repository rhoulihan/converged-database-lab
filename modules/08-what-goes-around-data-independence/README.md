# Module 08: What Goes Around Comes Around, and Data Independence

Runnable proofs for anchor article 8. Every script runs against the live lab
container and emits machine-checkable rows:

- `ASSERT:<name>:PASS|FAIL` is a check. The validator fails if any check fails.
- `METRIC:<name>:<value>` is a measurement. The validator stores it in
  `validator/results.json` under `"metrics"`, and the article takes its numbers
  from there. Checks look at direction and trend, never at exact numbers.

---

## What this module is for

Stonebraker and Pavlo, "What Goes Around Comes Around... And Around...",
SIGMOD Record 53(2), 2024, predicted that relational and document systems
would converge. This module measures one converged engine: Oracle AI Database
26ai Free, in the lab container, where JSON collections, tables and duality
views live in one database and share one transaction.

Four ideas run through the scenarios:

- **A document is one stored shape the workload can pick.** The scenarios
  measure what it saves and what it costs next to tables, in logical reads,
  CPU time and bytes returned.
- **A duality view is a compatibility layer.** It keeps an app that reads and
  writes documents through a document API correct while the storage under it
  moves to tables. A duality view is a join, and the scenarios measure what it
  costs.
- **New access patterns use SQL on the physical design that serves them**: a
  covering index, a cluster, a lines table, a materialized view.
- **Every result is reported as measured**, including where the document costs
  more, and where CPU time and logical reads point in different directions.

## Scenario index

Quotes are from Stonebraker and Pavlo 2024, section 2.

| Scenario | Script(s) | Statement it tests | What it shows |
|---|---|---|---|
| S3 | `01` to `08` | "there is no data independence." | The same MongoDB API code reads and writes the same results while the storage under the collection moves three times: from a collection to a table behind a duality view, then to promoted columns, then to lines in their own table. Array order after the last move is not guaranteed; see the S3 section. |
| S1 | `10-s1-read-by-key.sql` | "prejoins are not necessarily faster than joins", and the "lower-level, record-at-a-time interface" | For reading one order by key, the document does the fewest logical reads of the indexed designs here, in a clustered and an interleaved layout. The join's cost grows with the number of lines. **In CPU time (microseconds from `v$sql`), the join and the serialized document are not separated at 1 and 10 lines in either layout or at 100 lines clustered (in elapsed time the join takes less at 1 and 10 lines); the document uses less at 100 lines interleaved and at 1,000 lines.** Returned as binary JSON instead of text, the document takes 7 to 9 microseconds at every size. The duality view is a join and costs the most CPU. (See S1 (A): a hash cluster reads fewer blocks than the document up to 100 lines.) |
| S1 (A) | `12-s1-physical-join.sql` | the same claim, and the objection that S1's join was a heap table no DBA would choose | Reruns S1's interleaved case on 20 target orders per size against a covering index, an index-organized table (IOT), a compressed IOT, an index cluster, a hash cluster, a duality view over the IOT, a hash cluster sized for each order size, a duality view over it, and the document in a hash cluster, all on the same full data, with no direction asserted. **Result: in logical reads the hash clusters beat the document up to 100 lines (2 reads against 3), and the document does the fewest reads at 1,000 lines (8). In CPU the joins are not separated from the serialized document up to 10 lines (they take less in elapsed time); the sized hash cluster uses less at 100 lines (the other co-located joins take less there only in elapsed time), and the covering index, both IOTs and the sized hash cluster at 1,000 lines.** With 20 large orders growing at once, the fixed-size clusters fall far behind in reads at 1,000 lines (64 and 118). |
| S1b | `20-s1b-child-centric.sql` | "prejoins are not necessarily faster than joins" (the case where it holds) | For a query on the child side ("line items with sku X"), the decomposed tables win. The script computes how many item queries per 1,000 order reads it takes before the decomposed form does less total work, in logical reads and in CPU. **In logical reads the crossover is 42 to 250; in CPU the order reads are not separated at 10 and 100 lines, so no crossover is stated there, and at 1,000 lines it is about 4 to 6.** |
| S2 | `30-s2-write-amplification.sql` | "if the join is not one-to-many, then there will be duplicated data" | Duplication is real, and its cost depends on how often the copied field changes. A tier change rewrites every embedded copy; the embedded read skips one index probe. The script computes the update rate where the two balance: **0.9 tier changes per 1,000 order reads in logical reads, and no crossover in CPU, where the join read uses less CPU than the embedded read (3 against 10 microseconds).** |
| Sweeps (C) | `21-s1b-selectivity-sweep.sql`, `31-s2-fanout-sweep.sql` | the S1b and S2 claims, against the objection that their crossovers come from chosen parameters | S1b's crossover is swept over 5 to 500 matching orders (at 100 and 1,000 lines per order), and S2's over a fan-out of 10 to 1,000 orders per customer. **Result: in logical reads each crossover falls about in inverse proportion to its parameter, so a single crossover is one point on a curve, not a constant, and a crossover exists at every point. In CPU there is no crossover at any point of the S2 sweep; in the S1b sweep the order reads are not separated at 100 lines, and at 1,000 lines the crossover exists at every M, 6 to 16 times lower than in logical reads.** |
| S4 | `40-s4-two-projections.sql` | the duplicated-data claim and "there is no data independence", together | One canonical form (three normalized tables) projected as two different documents. The second document shape is added after the data is loaded, with one view definition and no data migration. The customer name is stored once, a change shows up in both documents at once, and only the customer-centric view may change it. |
| S5 | `50-s5-single-collection.js` | "developers must implement joins or multi-get operations in their application" (about key-value stores) | With a partition key and a sort key, one find request returns an order header and all of its lines through an index range scan; a sort step in the database orders them. No app-side join, no multi-get. |
| S3 at scale (B) | `60` to `69` | "there is no data independence", and the objection that a view in front makes the unchanged app pay | The S3 stages again, on 20,000 orders, with the cost of each unchanged MongoDB API statement measured at each stage (logical reads and CPU per call, from `v$sql`) and its executed plan captured, with no direction asserted. Results are the same at every stage. **Result: the unchanged app never got cheaper than on the plain collection** (four of six statements got slower at stage 3 compared with stage 2). On this build, fields kept in the flex column lose their JSON-path indexes through the view (the rare-sku find: 6 reads on the collection, about 1,500 through the view); promoting a field to a real column wins back part of the cost. |
| Writes (D) | `70-writes.sql`, `71-writes-api.js` | the objection that S2 measured only one kind of write | Inserts and a one-line change (knob 3) through a collection, a duality view and plain SQL, in SQL and through the MongoDB API; etags after a customer rename; and a materialized view as a third way to keep a copy in sync. No direction asserted. **Result: a duality view insert costs about what row-by-row SQL costs, and no less in reads (about 28% more reads at k = 100), and the MongoDB API's `$set` on a duality view locks every row of the document** (1,001 rows, the order row plus its 1,000 line rows, to change one line). The document is the cheapest insert but pays for its whole size on a one-number change; a materialized view moves the fan-out, it does not remove it. In CPU (microseconds from `v$sql`), the one-line change through the duality view costs about 160 to 310 times the row update, though it writes the same redo. |
| teardown | `99-teardown.sql` | none | Drops the measurement harness and checks that no object from this module is left. |

## How to run

From the repo root:

```bash
docker compose up -d                  # wait until lab-oracle is healthy
pip install -r validator/requirements.txt
python3 validator/run.py
```

The validator runs every module in order, then every script in this module in
file-name order. The scripts depend on that order: `00` builds the meter that
later scripts use, and the S3 stages build on each other. A full validator run
(all modules) takes about sixteen minutes. Most of it is S3 at scale (B): two
API restarts (`02b` and `63`) and four stages of measured statements, where
one aggregation alone takes 1.5 to 3.5 seconds per call for 21 calls. S1
(A) takes about five minutes: four extra hash clusters with the full
data, and 20 targets per size, each timed over 100 runs.

Numbers for the article come only from `validator/results.json`, under
`"metrics"`.

**Grants on a stack that is already running.** The database grants the
scripts need are in `docker/init/01-lab-user.sql`, which runs only when the
data volume is first created. If your stack was built before a grant was added
there (for example `SELECT` on `V_$TRANSACTION`, for the writes scenario), run
the file again as SYS. It is safe to run more than once:

```bash
docker exec -i lab-oracle sqlplus -s / as sysdba < docker/init/01-lab-user.sql
```

## Build measured

Every scenario in this module was measured on one build: Oracle AI Database
26ai Free, `Release 23.26.0.0.0` (from `v$version`), in the lab image built
from `gvenzl/oracle-free:23.26.0-faststart`, with Oracle REST Data Services
`26.3.1.r3031615` serving the MongoDB API. Every statement in this README
about how the product behaves means "on this build". Plans, costs and some
behavior (for example, which predicates a duality view pushes down) can
differ on other builds.

## The commit exception

The lab contract is that scripts leave the shared domain unchanged: the
validator rolls back after each SQL script. This module bends that rule, and
cleans up after itself.

- **The S3 and S3 (B) stage scripts commit on purpose.** `02`, `04` and `06`
  (and `62`, `65` and `67` for S3 (B)) each move the
  storage one step and `COMMIT`, because the next stage has to see the change.
  The rollback after each script would otherwise undo the move.
- **The S1, S1 (A), S1b, S2, sweep (C) and writes (D) scripts commit their test data.** They build their own
  `M08`-prefixed tables (DDL commits anyway) and commit the seeded rows so the
  measured statements read committed data.
- **The cutover scripts recycle the API tier.** `02b-cutover-recycle-api.sh`
  (and `63-s3b-cutover-recycle-api.sh`, which calls it) restarts the lab
  container so the MongoDB API re-reads the collection details. The validator opens a new SQL connection after any `.sh` script.

None of this touches the shared `ORDERS`, `ORDER_ITEMS` or `order_dv`. Every
scenario drops its own objects and checks that it is clean,
`08-teardown-s3.sql` removes all S3 objects, and `99-teardown.sql` checks the
whole module. The validator can run back to back with no leftovers.

---

## Harness: `scripts/00-meter.sql`

Creates the `m08_meter` package and the `m08_metrics` session table that the
later scripts use to measure work. Safe to run more than once.

- `m08_meter.snap` remembers the session's current counters and the clock.
- `m08_meter.delta('session logical reads' | 'redo size' | 'execute count' |
  'CPU used by this session' | 'elapsed time')` returns how much that counter
  grew since the last `snap`. CPU and elapsed time are in centiseconds
  (hundredths of a second).
- `m08_meter.elapsed_cs` returns the centiseconds since the last `snap`.
- `m08_meter.record(name, value)` stores a named measurement.
- `m08_meter.measure_repeat(p_name, p_sql, p_runs => 20, p_allow_lob => FALSE)`
  measures one query many times. It takes its own `snap`, so it replaces any
  `snap` the caller took before. `p_name` can be at most 80 bytes.
  - It runs the query once to warm it up, so parsing and the first execution
    are never measured. Then it runs it `p_runs` more times.
  - Each run executes the query and fetches every row, 1,000 rows per fetch
    call (like a client with an array size of 1,000), so the cost of reading the
    rows is real.
  - JSON and LOB columns: a bare column comes back as a pointer (a locator),
    so the document or LOB body is never read and the reads are under-counted.
    The helper refuses them with an error. For a document, select
    `json_serialize(<col> returning blob)`, which builds the whole document,
    and pass `p_allow_lob => TRUE`. To read a stored LOB's bytes, use
    `dbms_lob`.
  - The meter's own cost (a `snap` and its deltas with no work in between) is
    measured once per call. It is subtracted from reads, never going below 0.
    CPU and elapsed are reported as measured, with no subtraction, because one
    overhead sample at one-centisecond resolution is just noise. All three
    overheads are recorded so they can be checked.
  - It records `<p_name>-reads-median`, `-reads-min`, `-reads-max`,
    `-cpu-cs-median`, `-cpu-cs-max`, `-elapsed-cs-median`, `-elapsed-cs-max`,
    `-overhead-reads`, `-overhead-cpu-cs` and `-overhead-elapsed-cs`. Reads
    report min and max; CPU and elapsed report max. With an even number of runs
    the median is the lower of the two middle values, so it is always a run
    that really happened.

Logical reads are exact and repeat run to run. CPU and elapsed time are not:
they are measured on a single Free container that is shared with everything
else on the host, so they are noisy and only accurate to one centisecond. That
is why the helper reports the median over 20 runs, with the max (and, for
reads, the min), instead of a single run.

**CPU in microseconds, from `v$sql`.** One centisecond is too coarse for a read
that takes 20 microseconds, so the S1, S1 (A), S1b, S2, sweep (C) and writes (D)
scripts also measure each statement the way S3 (B) does: the growth of
`v$sql` (`CPU_TIME`, `ELAPSED_TIME`, `BUFFER_GETS`, in microseconds) for that
statement's cursor over R runs, divided by R. R is 200 in S1, S1b, S2 and the
sweeps, and 100 in S1 (A) (840 windows) and in the writes (whose three order
reads use 200).

- `m08_meter.measure_us(p_name, p_sql, p_marker, p_bind, p_runs => 200,
  p_allow_lob => FALSE)`:
  - purges the statement's cursor and records how many are left
    (`tmp:<p_name>-purge-left`, 0 when the purge worked);
  - runs it once to warm up (parse and first run);
  - snapshots `v$sql` for its `sql_id`, runs it R times fetching every row,
    and snapshots again.
  - It records `<p_name>-us` (CPU microseconds per run), `-ela-us` (elapsed
    microseconds per run), `-gets` (buffer gets per run) and `-bytes`.
  - `-bytes` is what one run returns, as text: the length of a serialized
    document, or for a row set the sum over rows and columns of each value's
    length as text (numbers through `to_char`).
  - For checks it also records the executions per run and the plan hash.
- `m08_meter.measure_dml_us(p_name, p_sql, p_marker, p_vals)` does the same for
  one `UPDATE`. Each run is followed by a `COMMIT`. The `COMMIT` is not part
  of the statement's figures; the statement's own undo and redo generation
  is.
- `m08_meter.vs_purge`, `vs_begin` and `vs_end` give the same window for a
  group of statements found by their markers. The record-at-a-time reader and
  the writes use them.
- `m08_meter.measure_reads(p_name, p_sql, p_bind)` records the logical reads of
  a query's second execution (S1 (A)'s 20-target readers use it).

These figures are database-side only. They cover the statement's own parse,
execute and fetch calls, including recursive SQL it runs (a duality view's
internal statements). They leave out the client and the network.

**Resolution.** On this stack `CPU_TIME` in `v$sql` moves in steps of about one
millisecond (the operating system's CPU accounting). A call shorter than that
usually shows CPU equal to its elapsed time to the microsecond; a longer call
shows CPU up to about a millisecond above or below its elapsed time. For a
window over one short statement the error stays about one millisecond in
total, so per run it is about 1,000 / R microseconds: 5 at R = 200, 10 at
R = 100. That is the step used below. Windows over longer calls, or over many
statements per run, can be off by a few milliseconds in total (the
record-at-a-time reader at 100 and 1,000 lines, and the one-line change
through the duality view, which takes about 3 ms per call); none of those
feeds a close ranking. For short statements the `-us` figure is therefore in
effect database-side elapsed time. Two readers are ranked in CPU only when the
gap between their ranges is larger than one step; the ranges already hold the
run-to-run spread. Otherwise the text says "not separated".

**Which runs.** Every figure in this README is from four validator runs on
these scripts, in November 2026: three back to back and one on a freshly built
database. A range ("21 to 24") means the runs differed; a single figure means
all four agreed.

A note on the document readers. They serialize the document to JSON text,
which is what a client that asks for text receives. That serialization is CPU
the join readers do not spend: they return values, not text. S1 and S2 also time the same
document returned as OSON, the binary form a driver that reads the JSON type
receives (`s1-doc-oson-*`, `s2-embedded-read-oson`), to show how much of the
document's CPU is the serialization.

Expected assertions:

```
ASSERT:m08-meter-ready:PASS
ASSERT:m08-meter-cpu-ready:PASS
ASSERT:m08-meter-repeat-ready:PASS
ASSERT:m08-meter-lob-guard:PASS
ASSERT:m08-meter-json-always-rejected:PASS
ASSERT:m08-meter-lob-guard-null-safe:PASS
ASSERT:m08-meter-us-ready:PASS
```

`json-always-rejected` and `lob-guard-null-safe` check the guard's edges: a
bare JSON column is refused even with `p_allow_lob => TRUE`, and
`p_allow_lob => NULL` counts as `FALSE`. `us-ready` runs `measure_us` on a
small table: CPU and elapsed are not negative, the query ran once per run,
the purge left no cursor, and the bytes equal the result's text length
computed in SQL.

## Proofs

### S3: the same MongoDB API code while storage moves (`scripts/01` to `scripts/08`)

The app code is the probe in `01-collection-baseline.js`; `03`, `05` and `07`
run it again, byte for byte, after each storage move and compare every read and
write result with the stage-0 baseline.

| Stage | Script | Storage under the collection name `sales_orders` |
|---|---|---|
| 0 | `01-collection-baseline.js` | a plain collection |
| 1 | `02-move-to-flex-view.sql` | a table with one JSON column, behind a duality view |
| 2 | `04-promote-columns.sql` | `customer` and `status` promoted to real columns |
| 3 | `06-move-lines-to-table.sql` | order lines moved to their own table |

`02b-cutover-recycle-api.sh` restarts the lab container after the first move.
Switching a collection to a duality view of the same name is a deployment
event: the API tier must be restarted so it reads the new collection details.
The later moves (view to view) need no restart.

**Array order.** The stage-3 probe passes because the database happens to
return each order's lines in the same order the app wrote them. In this lab the
lines came back sorted by `lineId`, and the probe's `lineId`s ascend in the
order they were written, so the two orders agree. That order is not
guaranteed once an array lives in a table: a duality view cannot sort a nested
array. `07b-stage3-array-order.js` writes an order whose lines are out of
`lineId` order, checks that the same lines come back, and reports (as a metric,
not a check) whether their order survived. An app that relies on array order
should carry an ordering field in the document and sort by it.

Expected assertions:

```
ASSERT:s3-stage0-captured:PASS
ASSERT:s3-normalizer-detects-change:PASS
ASSERT:s3-stage1-rows:PASS
ASSERT:s3-api-recycled:PASS
ASSERT:s3-stage-identical:PASS      (03, 05 and 07)
ASSERT:s3-stage2-columns:PASS
ASSERT:s3-stage3-lines:PASS
ASSERT:s3-stage3-items-same-set:PASS
ASSERT:s3-teardown-clean:PASS
```

Metric: `s3-stage3-order-preserved` (1 if the inserted order came back, else 0).

### S1: read one order by key (`scripts/10-s1-read-by-key.sql`)

One order and all of its lines are read four ways. Cost is counted as logical
reads (buffer visits), measured on the second run of each read, with the
meter's own overhead removed.

| Reader | What it does |
|---|---|
| doc | one document from a JSON collection table, found through its `_id` index |
| join | the order row joined to its line rows through the `order_id` index |
| dv | the same document shape through a duality view, which is a join underneath |
| n1 | the record-at-a-time interface: one query for the key list, then one fetch per line |

The `n1` reader is the access style Stonebraker and Pavlo describe as "a
lower-level, record-at-a-time interface" (SIGMOD Record 2024, section 2.3). The
short label `n1` stays in the metric names.

Target orders have 1, 10, 100 and 1,000 lines, in two layouts:

- **clustered:** each order's lines are inserted together. This shows what
  physical clustering buys.
- **interleaved:** lines arrive round-robin across 200 orders that are open at
  once, so the lines of one order land about one block apart: about one block
  per line. This is a
  constructed upper bound for a heap table with a single-column FK index.

The document and duality-view readers serialize the document, so its bytes are
really read; a client fetch costs the same.

**CPU time and bytes.** Each reader is also timed with
`m08_meter.measure_us` (see the harness): for every target, 200 runs, CPU and
elapsed microseconds per read from `v$sql`, and the bytes one read returns.
"doc as OSON" is a sensitivity probe: the same document returned as binary
JSON (OSON, what a driver that reads the JSON type receives) instead of text.
Logical reads are the second-execution reads; every cell is a range over the
four runs.

| layout | k | doc: reads / CPU us | doc as OSON: CPU us | join: reads / CPU us | dv: reads / CPU us | n1: reads / CPU us | bytes, doc / join |
|---|---|---|---|---|---|---|---|
| clustered | 1 | 3 / 9 | 7 | 7 / 4 | 7 / 19 to 24 | 11 / 4 to 6 | 112 / 38 |
| clustered | 10 | 3 / 11 to 16 | 6 to 7 | 7 / 6 to 7 | 7 / 34 to 39 | 47 / 22 to 27 | 544 / 380 |
| clustered | 100 | 3 / 35 to 40 | 7 to 8 | 7 / 33 to 36 | 7 / 209 to 214 | 407 / 237 to 244 | 4,954 / 3,890 |
| clustered | 1000 | 8 / 274 to 285 | 7 to 9 | 15 to 16 / 312 to 347 | 15 to 16 / 2,339 to 2,463 | 4,015 to 4,016 / 2,221 to 2,377 | 49,954 / 39,890 |
| interleaved | 1 | 3 / 9 to 10 | 7 to 8 | 7 / 3 to 4 | 7 / 19 to 22 | 11 / 4 to 6 | 113 / 39 |
| interleaved | 10 | 3 / 11 to 12 | 7 to 8 | 15 / 8 to 9 | 15 / 36 to 38 | 55 / 29 to 35 | 545 / 390 |
| interleaved | 100 | 3 / 35 to 40 | 7 to 8 | 94 to 95 / 56 to 62 | 94 to 95 / 248 to 253 | 494 to 495 / 252 to 267 | 4,955 / 3,990 |
| interleaved | 1000 | 8 / 276 to 285 | 7 to 8 | 894 / 600 to 635 | 894 / 2,746 to 2,858 | 4,894 / 2,581 to 2,881 | 49,955 / 40,890 |

- **Logical reads: the document reads the fewest blocks.** 3 up to 100 lines
  and 8 at 1,000, against 7 to 16 for the clustered join and about one block
  per line for the interleaved join.
- **CPU (200 runs, about 5 microseconds of resolution).** At 1 and 10 lines,
  in both layouts, the join and the serialized document are not separated (3
  to 9 against 9 to 16 microseconds; the gaps are at most one step). At 100
  lines clustered they are not separated either (33 to 36 against 35 to 40).
  At 100 lines interleaved and at 1,000 lines the document uses less (35 to 40
  against 56 to 62; 274 to 285 against 312 to 635). In database-side elapsed
  time, which has no such step, the join takes less than the document at 1
  and 10 lines in both layouts (3 to 9 against 9 to 12).
- **Most of the document's CPU above 10 lines is making text.** Returned as
  OSON, the same document takes 7 to 9 microseconds at every size. At 1 and
  10 lines that is not separated from the join. At 1,000 lines the document
  is stored out of the row, and the probe returns a pointer to it without
  reading the body (3 buffer gets against the serialized reader's 8), so
  there its figure leaves out the body read and is only a lower bound.
- **The duality view is a join that also builds the document on every
  read.** It uses about 2 to 3 times the document's CPU at 1 line (19 to 24)
  and about 8 to 10 times at 1,000 lines (2,339 to 2,858 microseconds).
- **Bytes.** As text, the document is larger than the row set: it carries
  every field name, while the row set repeats the order fields on every line.
  112 against 38 bytes at one line, about 25% more at 100 and 1,000 lines.

Expected assertions:

```
ASSERT:s1-same-content:PASS
ASSERT:s1-interleaved-spread:PASS
ASSERT:s1-doc-body-read:PASS
ASSERT:s1-join-grows-<layout>:PASS           (2)
ASSERT:s1-n1-execs-k<k>:PASS                 (4)
ASSERT:s1-us-measured:PASS
ASSERT:s1-us-plans-indexed:PASS
ASSERT:s1-us-purge-effective:PASS
ASSERT:s1-plans-indexed:PASS
ASSERT:s1-teardown-clean:PASS
```

- `doc-body-read` and `join-grows` are fairness checks: they show that the
  document reader really reads the body and that the join really reads the
  lines. They are not a comparison between designs.
- `us-measured`: every timed cursor ran in every one of its 200 runs (the
  record-at-a-time reader k + 1 statements per run).
- `us-plans-indexed`: each timed cursor, parsed for its own target, has an
  index step and no full scan.
- `us-purge-effective`: every purge left no cursor, so every window measured
  a freshly parsed cursor.
- The directions are reported, not asserted. `s1-doc-le-join-<layout>-k<k>`
  and `s1-dv-ge-doc-<layout>-k<k>` are METRIC rows: 1 when the document does
  no more logical reads than the join (or the view at least as many as the
  document), else 0.

Metrics:

- `s1-{doc|join|dv|n1}-{clustered|interleaved}-k{1|10|100|1000}-reads`;
- the same readers with `-us`, `-ela-us`, `-gets` and `-bytes` (CPU and
  elapsed microseconds per run, `v$sql` buffer gets per run, bytes returned),
  and `s1-doc-oson-<layout>-k<k>-{us|ela-us|gets|bytes}`;
- `s1-doc-le-join-<layout>-k<k>`, `s1-dv-ge-doc-<layout>-k<k>` (1 or 0);
- `s1-n1-k{k}-execs`, `s1-meter-overhead-reads`, `s1-meter-overhead-execs`.

Before its teardown, S1 copies its interleaved `doc` and `join` reads to
`ref:s1-*` rows in the session table, so `12-s1-physical-join.sql` can check
that its heap baseline reproduces them. That script removes the rows.

### S1 physical variants (A) (`scripts/12-s1-physical-join.sql`)

A fair objection to S1: its join reads a heap table through a single-column
`order_id` index, so in the interleaved layout every line is its own block.
Oracle has physical designs that keep an order's lines together whatever order
they arrive in. This script measures seven join designs, including
the heap baseline and a duality view over the IOT, plus three hash-cluster
arms: the join in a hash cluster sized for each order size, a duality view
over it, and the document itself in a hash cluster. It builds its own data
(prefix `M08A_`) with S1's interleaved recipe and loads every line table in
that same interleaved order, so any clustering comes from the physical design,
not from the load order.

**Twenty targets per order size.** One target per size can be a lucky or an
unlucky one. The load holds 20 target orders at each size (1, 10, 100 and
1,000 lines), each in its own slot of the round-robin, and every reader is
measured on all 20. Target 1 at each size is S1's (the same ids and slots as
before). The other 19 change the load in one way that matters: 20 orders of
each size now grow at the same time, where before one order of each size grew
among 196 small ones. The single-target metrics (`s1a-<reader>-k<k>-reads`)
are still target 1's, on this load.

| Reader | Storage | Plan, as measured |
|---|---|---|
| doc | JSON collection table | one document by its `_id` index, serialized so the body is read |
| heap | heap table, index on `order_id` | order by primary key, then an index range scan and one table block per line (S1's interleaved join) |
| cov | heap table, covering index `(order_id, line_id, sku, qty)` | order by primary key, then an index range scan; the line table is never visited |
| iot | index-organized table (IOT), primary key `(order_id, line_id)` | order by primary key, then a range scan of the IOT, whose rows live in the index sorted by order |
| iotc | the same IOT with key compression (`COMPRESS 1`), moved online after the load so its leaf blocks are packed | as iot. It changes two things at once (compression and the post-load move), so its gain over iot at 1,000 lines cannot be credited to either one alone |
| clu | index cluster on `order_id` holding the order and line tables | two index probes: the order row through its own primary key index, then the lines through the cluster index (`TABLE ACCESS CLUSTER`) |
| hash | hash cluster on `order_id` holding the order and line tables | no index probe: both tables are reached by hashing the key (`TABLE ACCESS HASH` on each) |
| dv | duality view over the iot tables | the iot join, built into a document (a join, measured as one) |
| hashk | a hash cluster sized for the order size k (at most one block per key), holding the full data | as hash (`TABLE ACCESS HASH` on each table, no index) |
| hdv | duality view over the hashk tables | the hashk join, built into a document |
| hdoc | the document in a single-table hash cluster keyed by order id, stored as OSON in a `RAW(2000)` column; 1 and 10 lines only | `TABLE ACCESS HASH`, no index; serialized like doc |

Sizing. The index cluster is `SIZE 512`: a typical 10-line order is about 10
line rows of roughly 40 bytes plus its header row, so about 500 bytes per key
and about 15 orders per 8 KB block. The hash cluster is `SIZE 512 HASHKEYS
22000`: the same bytes per key, and about one hash key per order (the data has
19,860 orders, `s1a-orders`; Oracle rounds `HASHKEYS` up to a prime). In both
clusters the 100-line and 1,000-line orders chain extra blocks onto their key.

The fixed `SIZE 512` suits orders of about 10 lines, so the hash-cluster arms
add one cluster per order size, sized for it (hashk, hdv): `SIZE` is the bytes
of the k-line order (its order row and line rows, from `vsize` plus a few bytes
of row overhead), plus 10%, rounded up to 256 bytes, at most one 8 KB block.
That gives 256, 512, 3,584 and 8,192 bytes for 1, 10, 100 and 1,000 lines
(`s1a-hashk-k<k>-size`). Each holds the full data, the same every other
reader sees: every order and line, the lines loaded in the same interleaved
order, with `HASHKEYS 22000` as for the fixed cluster (`s1a-hashk-k<k>-orders`
= `s1a-orders`). At 1,000 lines the one-block cap holds only about a quarter of
the order (31,915 bytes, `s1a-k1000-order-bytes`), so even the cluster sized
for it chains blocks onto the key. Loading the 100-line and 1,000-line
clusters takes about two minutes of each run.

The document in a hash cluster (hdoc) is limited by what a clustered table can
hold on this build: it takes neither a JSON column nor a LOB column. So the
document is stored as OSON in a `RAW(2000)` column, checked `IS JSON FORMAT
OSON`, the largest binary column a clustered table accepts here. A 10-line
document is 442 bytes of OSON and fits; a 100-line document is 3,442 bytes
(`s1a-doc-k<k>-oson-bytes`) and does not, so hdoc is measured at 1 and 10
lines only, one cluster per size, sized like hashk and holding every order
document that fits: all orders but the 40 large targets
(`s1a-hdoc-k<k>-docs`). Nothing else was tuned.

A hash cluster must be sized in advance. `HASHKEYS` and `SIZE` are fixed when
the cluster is created, and here they were set knowing the final order count
(19,860), which is the hash design's best case. If the orders grow past that,
keys collide or chain extra blocks, and reads go up. The space is also taken up
front: about 1,400 blocks here (22,000 keys of 512 bytes in 8 KB blocks),
before the first order arrives. A cluster sized for 1,000-line orders takes a
whole block per key. These are operational costs the read counts do not
show.

Statistics are gathered without histograms (`SIZE 1`). With the default
(`SIZE AUTO`), a histogram on `order_id` appears or not depending on when the
database last flushed its column-usage data, and when it appears the optimizer
reads the heap table's 1,000-line order with a full table scan (about 1,000
reads instead of about 900). Without histograms every reader gets the same
keyed plan on every run, and the plan checks below hold it there. This choice
favors the join side: it keeps the heap join on its cheaper plan.

Every reader returns the same content: the order and all of its lines. Reads
are counted on the second run with the meter overhead removed, as in S1. CPU
and elapsed time come from `m08_meter.measure_us` (100 runs per target,
microseconds from `v$sql`). The older one-centisecond figures from
`measure_repeat` (k = 100 and 1,000, target 1) are still recorded; at that
resolution they do not separate the readers.

**What it shows.** The four runs. Each cell is the median over the 20
targets (a range when the runs differed), with the lowest and highest target
over all four runs in brackets. The last column is target 1 alone
(the single-target metrics; for hashk, hdv and hdoc only CPU is recorded
there).

1 line per order:

| reader | reads: median (targets) | CPU us: median (targets) | bytes | target 1: reads / CPU us |
|---|---|---|---|---|
| doc | 3 (3) | 9 to 10 (7 to 11) | 113 | 3 / 10 |
| heap | 7 (7) | 4 (4) | 39 | 7 / 4 |
| cov | 6 (6) | 4 (3 to 4) | 39 | 6 / 4 |
| iot | 6 (6) | 4 (3 to 4) | 39 | 6 / 4 |
| iotc | 6 (6) | 4 (4) | 39 | 6 / 4 |
| clu | 6 (6) | 4 (4) | 39 | 6 / 4 |
| hash (SIZE 512) | 2 (2) | 3 (3 to 4) | 39 | 2 / 3 to 4 |
| dv (over iot) | 6 (6) | 20 to 21 (16 to 30) | 195 | 6 / 20 to 30 |
| hashk (sized for k) | 2 (2 to 6) | 3 (3 to 5) | 39 | - / 3 to 4 |
| hdv (over hashk) | 2 (2 to 6) | 19 (16 to 22) | 195 | - / 18 to 19 |
| hdoc | 1 (1 to 3) | 9 (7 to 11) | 113 | - / 9 to 10 |

10 lines per order:

| reader | reads: median (targets) | CPU us: median (targets) | bytes | target 1: reads / CPU us |
|---|---|---|---|---|
| doc | 3 (3) | 12 (12 to 20) | 546 | 3 / 12 |
| heap | 15 (15) | 9 to 10 (7 to 15) | 400 | 15 / 9 to 10 |
| cov | 6 (6 to 7) | 6 (6 to 7) | 400 | 6 / 6 |
| iot | 6 (6 to 7) | 6 (6 to 7) | 400 | 6 / 6 |
| iotc | 6 (6 to 7) | 6 (6 to 7) | 400 | 6 / 6 |
| clu | 6 (6) | 6 (6 to 7) | 400 | 6 / 6 |
| hash (SIZE 512) | 2 (2) | 5 (5 to 7) | 400 | 2 / 5 |
| dv (over iot) | 6 (6 to 7) | 34 to 35 (34 to 44) | 628 | 6 / 34 to 42 |
| hashk (sized for k) | 2 (2) | 5 (5 to 6) | 400 | - / 5 to 6 |
| hdv (over hashk) | 2 (2) | 32 to 33 (26 to 43) | 628 | - / 32 to 33 |
| hdoc | 1 (1 to 3) | 11 (7 to 19) | 546 | - / 11 |

100 lines per order:

| reader | reads: median (targets) | CPU us: median (targets) | bytes | target 1: reads / CPU us |
|---|---|---|---|---|
| doc | 3 (3) | 35 to 36 (35 to 45) | 4,956 | 3 / 35 to 36 |
| heap | 95 (95 to 96) | 61 to 63 (60 to 74) | 4,090 | 96 / 61 to 64 |
| cov | 7 (6 to 7) | 26 to 27 (23 to 37) | 4,090 | 7 / 26 to 27 |
| iot | 7 (6 to 8) | 27 to 28 (26 to 35) | 4,090 | 7 / 26 to 28 |
| iotc | 6 (6 to 7) | 27 to 28 (25 to 43) | 4,090 | 6 / 27 to 28 |
| clu | 6 (6) | 26 to 27 (26 to 33) | 4,090 | 6 / 26 to 27 |
| hash (SIZE 512) | 2 (2 to 6) | 24 to 25 (16 to 35) | 4,090 | 2 / 24 to 25 |
| dv (over iot) | 7 (6 to 8) | 205 to 215 (205 to 227) | 5,038 | 7 / 205 to 215 |
| hashk (sized for k) | 2 (2) | 24 (24 to 35) | 4,090 | - / 24 to 25 |
| hdv (over hashk) | 2 (2) | 204 (194 to 216) | 5,038 | - / 194 to 206 |

1000 lines per order:

| reader | reads: median (targets) | CPU us: median (targets) | bytes | target 1: reads / CPU us |
|---|---|---|---|---|
| doc | 8 (8) | 277 to 284 (274 to 294) | 49,956 | 8 / 274 to 287 |
| heap | 899 (898 to 900) | 708 to 721 (688 to 797) | 41,890 | 898 / 711 to 759 |
| cov | 16 (15 to 17) | 240 to 253 (226 to 258) | 41,890 | 14 / 238 to 253 |
| iot | 14 (11 to 26) | 253 (242 to 265) | 41,890 | 24 / 252 to 263 |
| iotc | 11 (11 to 12) | 248 to 262 (242 to 272) | 41,890 | 11 / 253 to 263 |
| clu | 64 to 65 (54 to 71) | 276 to 286 (274 to 297) | 41,890 | 63 to 66 / 275 to 295 |
| hash (SIZE 512) | 118 (108 to 126) | 273 to 276 (263 to 286) | 41,890 | 124 / 275 to 286 |
| dv (over iot) | 13 (11 to 25) | 2,319 to 2,449 (2,309 to 2,499) | 50,038 | 24 / 2,309 to 2,469 |
| hashk (sized for k) | 12 (12) | 226 (214 to 243) | 41,890 | - / 214 to 236 |
| hdv (over hashk) | 10 (10) | 2,270 to 2,331 (2,259 to 2,571) | 50,038 | - / 2,260 to 2,341 |

- **Logical reads.** Up to 100 lines the hash clusters read 2 blocks, the
  document in a hash cluster 1, and the document 3. The covering index, the
  IOTs, the index cluster and the duality views over them read 6 or 7, and the
  heap join about one block per line. At 1,000 lines the document reads 8; the
  next best are the duality view over the sized hash cluster (10), the
  compressed IOT (11) and the sized hash cluster (12).
- **Many large orders growing at once hurt the fixed-size clusters.** With 20
  orders of 1,000 lines growing together, their overflow blocks interleave:
  the index cluster reads 64 to 65 (median) blocks and the `SIZE 512` hash
  cluster 118, against 11 and 14 on the earlier load with one
  large order. The plain IOT varies by target (11 to 26), and so does the
  duality view over it. The compressed IOT, moved after the load, does not.
- **CPU (100 runs per target, about 10 microseconds of resolution).** The
  readers are told apart in CPU only where the gap is larger than that:
  - at 1 and 10 lines no join is separated from the document in CPU (3 to 10
    microseconds against 9 to 12). In database-side elapsed time, which has
    no such step, every co-located join and the heap join take less than the
    document (3 to 10 against 9 to 12), and the document in a hash cluster is
    not separated from it;
  - at 100 lines the sized hash cluster uses less CPU than the document (24
    against 35 to 36); the fixed hash cluster (24 to 25), the covering index,
    the IOTs and the index cluster (26 to 28) are not separated in CPU, and
    all of them take less in elapsed time;
  - at 1,000 lines the covering index, both IOTs and the sized hash cluster
    use less CPU than the document (226 to 262 against 277 to 284); the index
    cluster and the fixed hash cluster are not separated from it;
  - the duality views use the most CPU at every size (about 2 times the
    document at 1 line, about 8 to 9 times at 1,000 lines).
  The document as OSON, in S1, takes 7 to 9 microseconds, so the comparison
  depends on whether the client asks for text.
- **The document in a hash cluster** reads 1 block for most targets (up to 3)
  and uses 9 to 11 microseconds (median; 7 to 19 over the targets); it is not
  separated from the collection
  document at the sizes where it fits.
- **Twenty targets against one.** Up to 100 lines, every reader's median
  equals target 1 within a read or two. At 1,000 lines the medians differ
  from target 1 for the IOT (14 against 24) and the duality view over it (13
  against 24).

Every design that gets close to the document stores the lines by order,
chosen for this one access pattern, which is the same choice the document
makes. Not tried here: a cluster where the order row is also read through
the cluster key instead of its own primary key index, larger `SIZE` values
for the fixed clusters, partitioning by `order_id`, and caching layers (the
result cache or the In-Memory column store). The script asserts no direction
between the document and any join.

Expected assertions:

```
ASSERT:s1a-same-content-k<k>:PASS            (4) all 8 readers, same rows, all 20 targets
ASSERT:s1a-same-content-new-arms:PASS        hashk, hdv and hdoc return the document's rows for every target
ASSERT:s1a-t20-plans:PASS                    every timed cursor (840) ran its access path, no full scan
ASSERT:s1a-t20-measured:PASS                 every timed cursor ran once per run; 20 targets per reader and k
ASSERT:s1a-t20-purge-effective:PASS          every purge left no cursor
ASSERT:s1a-plan-clu:PASS                     TABLE ACCESS CLUSTER on the line table
ASSERT:s1a-plan-cov:PASS                     covering index range scan, no TABLE ACCESS on the line table
ASSERT:s1a-plan-dv:PASS                      INDEX RANGE SCAN on the IOT primary key
ASSERT:s1a-plan-hash:PASS                    TABLE ACCESS HASH on both tables, no INDEX step
ASSERT:s1a-plan-iot:PASS                     INDEX RANGE SCAN on the IOT primary key
ASSERT:s1a-plan-iotc:PASS                    INDEX RANGE SCAN on the compressed IOT's primary key
ASSERT:s1a-plans-indexed:PASS                keyed access everywhere, no full scans
ASSERT:s1a-heap-matches-s1-k<k>:PASS         (4) heap within 5 reads of S1's join, doc within 2 of S1's doc
ASSERT:s1a-clu-colocated:PASS
ASSERT:s1a-teardown-clean:PASS
```

`s1a-heap-matches-s1-k<k>` needs S1's `ref:s1-*` rows, so it fails if this
script runs without `10-s1-read-by-key.sql` before it in the same session (or
if a `.sh` script, after which the validator reconnects, runs between them).

Metrics:

- `s1a-{doc|heap|cov|iot|iotc|clu|hash|dv}-k{1|10|100|1000}-reads` (second-run reads, target 1);
- `s1a-{reader}-k{k}-{us|ela-us|bytes}` (target 1, from `measure_us`; every reader including hashk, hdv and hdoc);
- `s1a-{reader}-k{k}-t20-{reads|us}-{median|min|max}`, `-t20-ela-us-median`, `-t20-bytes-median` and `-t20-targets` (over the 20 targets);
- `s1a-hashk-k{k}-size`, `s1a-hdoc-k{1|10}-size`, `s1a-k{k}-order-bytes`, `s1a-doc-k{k}-oson-bytes`, `s1a-orders`;
- `s1a-{reader}-k{100|1000}-{reads-median|cpu-cs-median|cpu-cs-max|elapsed-cs-median|elapsed-cs-max|overhead-reads}`
  (from `measure_repeat`);
- `s1a-{heap|clu|hash}-k{k}-blocks` (distinct blocks holding the target's lines);
- `s1a-meter-overhead-reads`.

### S1b: find the line items with one sku (`scripts/20-s1b-child-centric.sql`)

S1 asked for one order. S1b asks the opposite kind of question: "which line
items have sku X1?" The sku sits in exactly 20 lines spread over 20 orders.
Orders have 10, 100 or 1,000 lines, each size on its own freshly built data, in
the clustered layout. Cost is counted as in S1: logical reads only (buffer
visits; not parse CPU or bytes sent to the client), on the second run, with the
meter's overhead removed.

Each side gets its best available plan. The cheaper of its two readers is the
one that counts (`s1b-childtable-k<k>-reads`, `s1b-orderdocs-k<k>-reads`).

| Reader | What it does |
|---|---|
| childtable-plain | the line rows, through an index on `sku`. No join. |
| childtable-covered | an index on `(sku, line_id, qty)` answers alone, with no row visits |
| orderdocs-jsontable | order documents through a multivalue index on `items[*].sku`, then `JSON_TABLE` pulls out the matching item |
| orderdocs-serialized | the matching whole orders through the same index, fetched serialized, as a client would before filtering |
| itemdv | a duality view with one document per line, rooted on the line table, filtered on `sku` |

The serialized document reader is the cheaper document reader in logical
reads, but it returns whole orders to find 20 pairs.

**What the numbers show.** With a covering index, the decomposed form answers
the child-centric query in a few reads, whatever the order size. The order
documents pay about one block per matching order while each document fits in
its row (10 and 100 lines here), and more once it is stored out of the row
(1,000 lines, about 50 KB; `s1b-doc-bytes-k<k>` records the size). The item
duality view reads the same covering index as the child table.

**Knob 1: how often each query runs.** The script also measures S1's order read
by key on the same data (`doc` and `join`). For 1,000 order reads plus q item
queries, where every order read hits a k-line order:

```
documents : 1000*doc  + q*orderdocs
normalized: 1000*join + q*childtable
crossover : q = 1000 * (join - doc) / (orderdocs - childtable)
```

Below the crossover, documents do fewer logical reads in total; above it,
normalized tables do. Whether the item query's cost matters depends on how
often it runs, and the crossover puts a number on that. It is approximate: a
one-block change in any term moves it. In order processing, item queries are
usually low-frequency reports and KPIs. If a crossover does not exist at some
size, `s1b-no-crossover-k<k>` is 1.

**CPU time and bytes.** Every reader is timed again with
`m08_meter.measure_us` (200 runs, microseconds from `v$sql`, its own marker,
the same text and hints), and the crossover is computed a second time with
CPU microseconds in place of logical reads
(`s1b-crossover-item-queries-per-1000-order-reads-k<k>-us`, or
`s1b-no-crossover-k<k>-us` = 1), each side again the cheaper of its two
readers, this time in CPU. Logical reads are the counted second execution;
every cell is a range over the four runs.

| k | reader | reads | CPU us | bytes |
|---|---|---|---|---|
| 10 | childtable-plain | 22 to 23 | 11 | 200 |
| 10 | childtable-covered | 2 | 4 | 200 |
| 10 | orderdocs-jsontable | 22 | 95 to 101 | 200 |
| 10 | orderdocs-serialized | 22 | 91 to 98 | 10,771 |
| 10 | itemdv | 2 | 4 | 200 |
| 10 | doc | 3 | 11 to 12 | 538 |
| 10 | join | 6 | 6 | 374 |
| 100 | childtable-plain | 23 | 11 | 220 |
| 100 | childtable-covered | 2 | 4 | 220 |
| 100 | orderdocs-jsontable | 22 | 594 to 614 | 220 |
| 100 | orderdocs-serialized | 22 | 567 to 581 | 98,971 |
| 100 | itemdv | 2 | 4 | 220 |
| 100 | doc | 3 | 34 to 35 | 4,948 |
| 100 | join | 8 | 33 to 37 | 3,884 |
| 1000 | childtable-plain | 22 | 10 to 11 | 240 |
| 1000 | childtable-covered | 2 | 4 | 240 |
| 1000 | orderdocs-jsontable | 222 | 5,730 to 7,114 | 240 |
| 1000 | orderdocs-serialized | 122 | 5,364 to 5,619 | 998,971 |
| 1000 | itemdv | 2 | 4 | 240 |
| 1000 | doc | 8 | 276 to 285 | 49,948 |
| 1000 | join | 13 to 14 | 305 to 310 | 39,884 |

| k | crossover, logical reads | crossover, CPU us |
|---|---|---|
| 10 | 150 | none |
| 100 | 250 | 1.76 to 3.55 in 2 runs, none in 2 |
| 1000 | 42 to 50 | 3.56 to 6.32 |

- **The item query costs the documents far more CPU than reads suggest.**
  The child table answers in about 4 microseconds at every size. The order
  documents take about 90 to 100 microseconds at 10 lines, about 570 to 610
  at 100 and about 5,400 to 7,100 at 1,000: every matching order is read and
  serialized (or scanned by `JSON_TABLE`) whole, and the serialized reader
  returns 10,771 to 998,971 bytes to deliver 20 pairs (200 to 240 bytes from
  the child table).
- **The order read by key, in CPU (200 runs, about 5 microseconds of
  resolution).** At 10 lines they are not separated in CPU (6 against 11 to
  12, a gap of one step); in elapsed time the join takes less. At 100 lines
  they are not separated (33 to 37 against 34 to 35). At 1,000 lines the
  document uses less (276 to 285 against 305 to 310).
- **So the crossover in CPU:** at 10 and 100 lines the order reads are not
  separated, so no crossover is stated (at 10 lines no run computed one; at
  100 lines two runs computed 1.76 and 3.55, and two none). At 1,000 lines it
  is 3.56 to 6.32 item queries per 1,000 order reads in all four runs,
  against 42 to 50 in logical reads.

Expected assertions:

```
ASSERT:s1b-same-content:PASS
ASSERT:s1b-plans-indexed:PASS
ASSERT:s1b-us-measured:PASS
ASSERT:s1b-us-purge-effective:PASS
ASSERT:s1b-us-plans-indexed:PASS
ASSERT:s1b-teardown-clean:PASS
```

Directions are reported, not asserted. These are METRIC rows, 1 or 0:
`s1b-outofrow-penalty-k1000` (the order documents read more than twice the
child table), `s1b-itemdv-close-to-childtable-k<k>` (the item view reads at
most twice the child table), `s1b-gap-grows-with-k` and
`s1b-penalty-ratio-grows` (the documents' read ratio over the child table is
larger at k = 1,000 than at k = 10 or 100), and `s1b-crossover-k<k>-positive`
(at a k where the documents read more per item query, the crossover is above
zero).

Metrics: `s1b-{childtable|childtable-plain|childtable-covered|orderdocs|orderdocs-jsontable|orderdocs-serialized|itemdv|doc|join}-k{10|100|1000}-reads`,
the same names with `-us` (CPU microseconds per run; for `childtable` and
`orderdocs` the cheaper of the two readers) and, for each measured reader,
`-ela-us`, `-gets` and `-bytes`;
`s1b-doc-bytes-k{k}`, `s1b-crossover-item-queries-per-1000-order-reads-k{k}` (or
`s1b-no-crossover-k{k}`) and the same with `-us` for the CPU crossover;
the METRIC directions listed above; `s1b-meter-overhead-reads`.

### S2: duplicated data and what it costs to keep it in sync (`scripts/30-s2-write-amplification.sql`)

Stonebraker and Pavlo point out (section 2.3, p.23): "if the join is not
one-to-many, then there will be duplicated data". That is true. S2 measures what the duplication costs, and
shows that the answer depends on how often the copied data changes.

Each order embeds a snapshot of its customer, `{custId, name, tier}` (the Extended
Reference pattern). Customer 1 has N = 100 orders, spread out over time among
20,000 orders of other customers.

| Model | How it is stored |
|---|---|
| embedded | order documents in a JSON collection table, each carrying the customer snapshot, with an index on the embedded `custId` |
| normalized | an orders table with a plain `cust_id` column (indexed) that points to one customer row |

**Two kinds of cost.**

- **Logical reads** count buffer visits: how many blocks a statement looks at. They
  measure the work of finding and changing data.
- **Redo** counts the bytes of change log the database writes so every change can
  be recovered. It measures write volume: log disk, network to standbys, and
  backups.

Each statement is measured on its second run, with the meter's own overhead
removed.

| Measurement | Embedded | Normalized |
|---|---|---|
| one tier change | rewrite every document that embeds the customer (`JSON_TRANSFORM`, found through the `custId` index) | update one customer row by primary key |
| one order read with its customer fields | the document by `_id`, serialized so its body is really read | the order row joined to its customer row by key |

The normalized read is measured on two plans, and the cheaper one counts:

- **primary keys:** the order row, then the customer row;
- **covering indexes:** both answered from index entries alone. The order index
  holds every order column, so it works like an index-organized orders table.

The normalized tier change also pays to maintain the customer covering index,
because that index holds `tier`.

**Sizing.** The customer table has 100,000 rows. With a toy-sized customer table,
the normalized read's extra index probe hides inside one index block. At
100,000 customers the index has a realistic depth. `s2-idx-<name>-blevel`
records the depth of every index used.

**What the numbers show.**

- **A field that changes is expensive to duplicate.** One tier change rewrites N
  documents embedded, and one row normalized. It costs far more logical reads
  and far more redo.
- **Reads go the other way.** The embedded order already holds the customer
  fields, so it skips the second index probe the join needs. The join is never
  free; it is one more lookup on every read.

**Knobs 2 and 3: how often writes happen, and which fields they change.** With
logical reads as the work unit for reads and updates alike, for 1,000 order
reads plus q customer tier changes:

```
embedded  : 1000*emb_read  + q*emb_update_reads
normalized: 1000*norm_read + q*norm_update_reads
crossover : q = 1000 * (norm_read - emb_read) / (emb_update_reads - norm_update_reads)
```

Below q tier changes per 1,000 order reads, embedding does less work in total;
above it, normalized storage does. The measured value is
`s2-crossover-updates-per-1000-reads` in `validator/results.json`. It is
recorded to one decimal because it is below 1, and a whole number would show it
as 1 or 0. It is computed on logical reads only.

The crossover is sensitive. The read advantage is one logical read: the customer
index probe the embedded read avoids. That advantage is zero when the customer
index has a single level, which is why a 50-row customer table tied. The
crossover scales directly with that gap: one block less erases it, one block
more doubles it.

By the same reasoning (derived, not measured separately): embedding a field pays
whenever the field changes less often than the crossover. An immutable field
changes zero times, below any positive crossover. That is the Extended Reference
pattern: copy the fields that never or rarely change (a name), and keep the
volatile ones (a tier) behind a reference. Redo is a separate cost axis, and it makes the write side worse still for
embedding. If no crossover exists, `s2-no-crossover` is 1.

**CPU time.** The reads are timed with `m08_meter.measure_us` and the two
updates with `m08_meter.measure_dml_us` (200 runs each, microseconds from
`v$sql`; each update run alternates SILVER and GOLD and is committed after the
statement, and the update's CPU includes its undo and redo generation). The
crossover is computed again with CPU microseconds in place of logical reads,
`s2-crossover-updates-per-1000-reads-us` (or `s2-no-crossover-us` = 1). Logical
reads are the counted second execution; every cell is a range over the four
runs.

| statement | reads | CPU us | bytes |
|---|---|---|---|
| embedded-read | 3 | 10 | 97 |
| embedded-read-oson | - | 8 | 134 |
| normalized-read-pk | 6 | 3 | 25 |
| normalized-read-covered | 4 | 3 | 25 |
| embedded-update | 1,094 to 1,096 | 2,795 to 2,923 | - |
| normalized-update | 7 | 9 to 12 | - |
| crossover (tier changes per 1,000 order reads) | 0.90 | none | |

- **In CPU the embedded read costs more than the join.** The embedded order
  takes 10 microseconds and the normalized join 3. The embedded read saves an
  index probe in logical reads, but returning a document costs more CPU than
  returning a row. Returned as OSON instead of text
  (`s2-embedded-read-oson`), it takes 8, which is not separated from the
  join's 3 at this resolution.
- **So in CPU there is no crossover** (`s2-no-crossover-us` = 1 in all four
  runs): the normalized form uses less CPU for the read and for the tier
  change (9 to 12 microseconds against about 2,800 to 2,900 for 100
  documents). Measured in
  logical reads, the crossover is 0.9 tier changes per 1,000 order reads.

Expected assertions:

```
ASSERT:s2-embedded-touches-N:PASS
ASSERT:s2-normalized-touches-1:PASS
ASSERT:s2-same-content:PASS
ASSERT:s2-plans-indexed:PASS
ASSERT:s2-us-measured:PASS
ASSERT:s2-us-purge-effective:PASS
ASSERT:s2-teardown-clean:PASS
```

Directions are reported, not asserted: `s2-embedded-redo-gt-normalized`,
`s2-embedded-read-cheaper` and `s2-crossover-positive` are METRIC rows, 1 or
0 (in logical reads and redo).

`s2-same-content` checks two things, before and after the tier change:

- both models return the same order and customer fields;
- every embedded copy carries the new tier.

Metrics:

- `s2-{embedded-update-docs|normalized-update-rows}`;
- `s2-{embedded|normalized}-update-{reads|redo}`;
- `s2-embedded-read-reads`, `s2-normalized-read-{pk|covered}-reads`, and
  `s2-normalized-read-reads` (the cheaper of the two);
- `s2-crossover-updates-per-1000-reads` (or `s2-no-crossover`), and the same
  with `-us` for the CPU crossover;
- `s2-{embedded-read|embedded-read-oson|normalized-read-pk|normalized-read-covered|embedded-update|normalized-update}-{us|ela-us|gets}`,
  `-bytes` for the reads, and `s2-normalized-read-us` (the cheaper of the two);
- the METRIC directions listed above;
- `s2-idx-{cust-pk|cust-cov|ord-pk|ord-cov|doc-pk|doc-cust}-blevel`;
- `s2-meter-overhead-{reads|redo}`.

### Sweeps (C): how much the S1b and S2 crossovers depend on their parameters (`scripts/21-s1b-selectivity-sweep.sql`, `scripts/31-s2-fanout-sweep.sql`)

A fair objection to S1b and S2: each crossover was computed at one chosen
parameter. S1b fixed the item query at 20 matching orders, and S2 fixed the
fan-out at N = 100 orders per customer. These two scripts sweep those
parameters and report what happens. Nothing was tuned per point.

Both scripts gather statistics with a histogram on every indexed column
(`FOR ALL COLUMNS SIZE 1 FOR ALL INDEXED COLUMNS SIZE 254`), so the optimizer
knows how many rows each sku or customer has and is free to pick a different
plan at each point. In the S1b sweep this informs only the child-table side:
the multivalue index's row estimate stays 1 whatever M is (its hidden column
gets no usable histogram), so the order-document plans are chosen without it. The item readers and the embedded update carry no hints.
Each point uses its own literal (sku `XM5`, `XM20`, ... or customer 1, 2, 3),
so each point gets its own cursor and plan. The executed plan of every
measured statement is captured with `dbms_xplan.display_cursor(...,
'ALLSTATS LAST')` and printed as `PLAN:` rows (the validator ignores them; run
the script alone to see them). Reads are counted on the second execution, with
the meter's overhead removed, as in S1b and S2.

**S1b sweep (prefix `M08C1_`).** One data load per order size: 2,000 filler
orders of 10 lines and 500 matching orders of k lines (k = 100, then k =
1,000), clustered. The swept skus are nested: `XM500` is in one line of every
matching order, `XM100` in every 5th, `XM20` in every 25th and `XM5` in every
100th, so M = 5, 20, 100 and 500 matching orders. The readers are S1b's final
design: the child table (no hint; the optimizer picks the covering index
`(sku, line_id, qty)` at every M), the order documents (the cheaper of the
`JSON_TABLE` reader and the serialized reader, both through the multivalue
index), and S1's order read by key (`doc` and `join`), which does not depend on
M. At every point the serialized reader is the cheaper document reader, so it
is the one that counts. (The `JSON_TABLE` reader's second execution is
sometimes re-parsed by statistics feedback, because the multivalue index's
row estimate is 1; that adds about 12 reads to its count at k = 100, M = 100
and 500. Its `measure_repeat` medians, 102 and 503, equal the serialized
reader's.)

At k = 1,000 the plan `Buffers` column does not show the documents' full cost.
Plan buffers cover row sources only. The out-of-row LOB bodies are read while
the documents are serialized, outside any row source, so the serialized
reader's plan shows 8, 23, 103 and 149 buffers at M = 5, 20, 100 and 500
against 33, 123, 603 and 2,649 session logical reads, and the k = 1,000 `doc`
plan shows 3 against 8. The session-level reads are the cost, and they are
what the tables below use. The visible evidence is in the `JSON_TABLE` plan,
where the LOB reads land in a row source: its `JSONTABLE EVALUATION` step
shows 2,500 buffers at M = 500.

The crossover formula is S1b's, rounded to two decimals:

```
q = 1000 * (join - doc) / (orderdocs - childtable)
```

Logical reads over the four runs. A range means the runs differed; the
article takes its numbers from `validator/results.json`.

| k | M | childtable | orderdocs | doc | join | crossover q (item queries per 1,000 order reads) |
|---|---|---|---|---|---|---|
| 100 | 5 | 2 | 7 | 3 | 6 | 600 |
| 100 | 20 | 2 | 22 | 3 | 6 | 150 |
| 100 | 100 | 2 | 102 | 3 | 6 | 30 |
| 100 | 500 | 4 | 503 | 3 | 6 | 6.01 |
| 1000 | 5 | 3 | 33 | 8 | 14 | 200 |
| 1000 | 20 | 3 | 123 | 8 | 14 | 50 |
| 1000 | 100 | 3 | 603 | 8 | 14 | 10 |
| 1000 | 500 | 5 | 2,649 | 8 | 14 | 2.27 |

The k = 1,000 join read was 14 in all four runs. One read more in the
numerator would move every k = 1,000 crossover by about 15% (200 to 233 at
M = 5, 2.27 to 2.65 at M = 500), as S1b warned. The k = 100 figures were the
same in all four runs.

**How strongly it depends on M: about in inverse proportion.** The child table
answers from the covering index in 2 to 5 reads whatever M is. The order
documents pay about one block per matching order at k = 100 (the document fits
in its row, about 5 KB) and about five to six blocks per matching order at
k = 1,000 (about 50 KB, stored out of the row). So the denominator grows about
linearly with M, the numerator does not change, and the crossover falls about
as 1/M: 100 times more matching orders gives a crossover about 100 times
lower (600 to 6.01 at k = 100, 200 to 2.27 at k = 1,000). The S1b crossover at 20
matching orders is one point on this curve, not a constant. What does not
change is the direction: at every point a crossover exists, and above it the
normalized tables do fewer reads.

The numerator is the order read by key against the heap order-plus-lines
join, as in S1b. Against the best physical join measured in S1 (A), the hash
cluster, the order read does not favor documents at k up to 100 (the hash
cluster reads 2 blocks against the document's 3), so at k = 100 there would
be no crossover: the normalized side wins both queries. At k = 1,000 the
document still wins the order read (S1 (A)). This was not re-measured here;
see the S1 (A) section. (At M = 20 the k = 100 crossover here is 150,
against 250 in S1b: S1b's join read 8 blocks on its data and this one reads 6.
A two-block change in the numerator moves the crossover by that much.)

**S2 sweep (prefix `M08C2_`).** One data load: S2's 100,000 customers, and
21,110 orders. Customers 1, 2 and 3 have N = 10, 100 and 1,000 orders, spread
evenly through the order ids; every other order belongs to its own customer.
The models and statements are S2's. The normalized read is measured on both
plans (primary keys, covering indexes) and the cheaper counts; the embedded
update has no hint, and the optimizer, which sees 1,000 rows for customer 3 in
the histogram, still picks the `custId` index at every N. The crossover formula
is S2's, on logical reads, with redo reported separately. The embedded update
reads move by a few blocks from run to run (1,098 to 1,100 at N = 100), so the
second decimal of the crossover is not stable:

```
q = 1000 * (norm_read - emb_read) / (emb_update_reads - norm_update_reads)
```

| N | docs touched | embedded update reads | embedded update redo (bytes) | normalized update reads / redo | emb_read | norm_read | crossover q (tier changes per 1,000 order reads) |
|---|---|---|---|---|---|---|---|
| 10 | 10 | 124 to 126 | 13,904 to 13,972 | 7 / 784 | 3 | 4 | 8.40 to 8.55 |
| 100 | 100 | 1,098 to 1,100 | 125,868 to 125,936 | 7 / 784 | 3 | 4 | 0.91 to 0.92 |
| 1000 | 1,000 | 10,219 to 10,233 | 1,168,944 to 1,169,396 | 7 / 784 | 3 | 4 | 0.10 |

**How strongly it depends on N: about in inverse proportion.** The embedded update
costs about 10 to 13 reads and about 1,170 to 1,400 bytes of redo per embedded copy (more per copy at
smaller N), so
its cost grows linearly with N, while the read advantage stays at one logical
read (the customer index probe the embedded read skips) at every N. The
crossover therefore falls as 1/N: about 8.4 to 8.6 tier changes per 1,000 order reads
at N = 10, 0.91 to 0.92 at N = 100 (S2's 0.9) and 0.10 at N = 1,000. A customer with ten
times more orders can change its tier ten times less often before embedding
stops paying. S2's number holds only at N = 100. What does not change is the
direction: a crossover exists at every N.

**The crossovers in CPU time.** Every point is timed again with
`m08_meter.measure_us` (reads) and `m08_meter.measure_dml_us` (updates): 200
runs, microseconds from `v$sql`, each timed cursor checked to run the same plan
as its counted cursor (`s1c-us-same-plan`, `s2c-us-same-plan`). The crossovers
are computed again with CPU microseconds in place of logical reads
(`...-crossover-...-us`, or `...-no-crossover-us` = 1). Ranges over the four
runs; "none" means no crossover in that run.

| k | M | childtable CPU us | orderdocs CPU us | doc CPU us | join CPU us | crossover, reads | crossover, CPU |
|---|---|---|---|---|---|---|---|
| 100 | 5 | 2 to 3 | 143 to 148 | 35 to 36 | 32 to 37 | 600 | 7.14 in 1 run, none in 3 |
| 100 | 20 | 4 | 559 to 583 | 35 to 36 | 32 to 37 | 150 | 1.73 in 1 run, none in 3 |
| 100 | 100 | 12 to 14 | 2,772 to 2,862 | 35 to 36 | 32 to 37 | 30 | 0.36 in 1 run, none in 3 |
| 100 | 500 | 49 to 53 | 14,105 to 14,564 | 35 to 36 | 32 to 37 | 6.01 | 0.07 in 1 run, none in 3 |
| 1000 | 5 | 2 to 3 | 1,347 to 1,396 | 276 to 286 | 305 to 323 | 200 | 13.74 to 34.97 |
| 1000 | 20 | 4 | 5,364 to 5,529 | 276 to 286 | 305 to 323 | 50 | 3.53 to 8.77 |
| 1000 | 100 | 11 to 12 | 27,255 to 27,677 | 276 to 286 | 305 to 323 | 10 | 0.69 to 1.73 |
| 1000 | 500 | 49 to 54 | 136,247 to 141,143 | 276 to 286 | 305 to 323 | 2.27 | 0.14 to 0.35 |

| N | embedded read CPU us | normalized read CPU us | embedded update CPU us | normalized update CPU us | crossover, reads | crossover, CPU |
|---|---|---|---|---|---|---|
| 10 | 9 | 2 to 3 | 312 to 357 | 14 | 8.40 to 8.55 | none |
| 100 | 9 | 3 | 2,789 to 2,961 | 14 to 16 | 0.91 to 0.92 | none |
| 1000 | 9 | 3 | 30,685 to 30,957 | 14 to 17 | 0.10 | none |

- **S1b sweep.** In CPU the order documents pay about 28 to 30 microseconds
  per matching order at 100 lines and about 270 to 280 at 1,000 lines,
  against 2 to 54 for the child table. At 100 lines the order read by key is not separated
  between the join and the document (32 to 37 against 35 to 36), so no
  crossover in CPU is stated at any M (one run computed one at every M, the
  other three none). At 1,000 lines the document
  uses less CPU for the order read (276 to 286 against 305 to 323), and a
  crossover in CPU exists at every M in all four runs: 14 to 35 item queries
  per 1,000 order reads at M = 5, falling to 0.14 to 0.35 at M = 500, against
  200 and 2.27 in logical reads. Its numerator is a gap of 19 to 47
  microseconds, so the CPU values move by up to about two and a half times
  between runs.
- **S2 sweep.** In CPU the embedded read costs more than the join at every N
  (9 microseconds against 3), so there is no crossover in CPU at any N: the
  normalized form uses less CPU for both the read and the tier change. The
  embedded update's CPU grows with N (about 310, 2,900 and 31,000
  microseconds at N = 10, 100 and 1,000); the normalized update stays at 14
  to 17.
- **What changes and what does not.** In logical reads each crossover falls
  about in inverse proportion to its parameter and exists at every point. In
  CPU, the S2 crossovers disappear at every N, and the S1b crossovers exist
  only at 1,000 lines, where they are 6 to 16 times lower than in logical
  reads.

**Time.** CPU and elapsed medians come from 20 timed runs. For the S1b sweep
they are from `m08_meter.measure_repeat` for the item readers at M = 100 and
500; for the S2 sweep, from a loop of 20 embedded updates at N = 100 and 1,000,
each committed after it is measured. Those loops also record
`s2c-n{N}-embedded-update-timed-reads-median` for audit only: with a commit
after every run its value moves widely between runs (8,840 to 11,521 at
N = 1,000 over the four runs, the low one on the freshly built database), so the crossover uses the counted second
execution, never this figure. At the meter's one-centisecond
resolution the child table reads 0 cs everywhere, the order documents 2 cs at
k = 100, M = 500 (1 to 2 cs) and 3 to 15 cs at k = 1,000, and the embedded update 0 cs at
N = 100 and 3 cs at N = 1,000. Each timed copy runs the same plan as the
counted cursor (`s1c-timed-same-plan`, `s2c-timed-same-plan`).

Expected assertions:

```
ASSERT:s1c-same-content-k<k>-m<M>:PASS       (8) childtable, jsontable and the client-filtered serialized orders return the same M pairs
ASSERT:s1c-plans-captured:PASS               every measured statement has an ALLSTATS plan with Buffers
ASSERT:s1c-plans-indexed:PASS                no full table scan; the order-document readers use the multivalue index at every M
ASSERT:s1c-childtable-covered:PASS           the child-table reader uses the covering index with no line-table visit at every M
ASSERT:s1c-timed-same-plan:PASS              each measure_repeat copy ran the counted cursor's plan
ASSERT:s1c-crossover-recorded:PASS           a positive crossover or s1c-k<k>-m<M>-no-crossover at every point
ASSERT:s1c-us-measured:PASS                  every timed cursor ran once per run
ASSERT:s1c-us-purge-effective:PASS           every purge left no cursor
ASSERT:s1c-us-same-plan:PASS                 each timed cursor ran the counted cursor's plan
ASSERT:s1c-teardown-clean:PASS
ASSERT:s2c-embedded-touches-N-n<N>:PASS      (3) docs touched = N, normalized rows touched = 1
ASSERT:s2c-same-content-n<N>:PASS            (3) same fields before and after, every copy carries the new tier
ASSERT:s2c-plans-captured:PASS               every measured statement has an ALLSTATS plan with Buffers and an index step
ASSERT:s2c-reads-indexed:PASS                no full table scan on the reads; the covering read visits no table
ASSERT:s2c-timed-same-plan:PASS              each timed update ran the counted cursor's plan
ASSERT:s2c-crossover-recorded:PASS           a positive crossover or s2c-n<N>-no-crossover at every N
ASSERT:s2c-us-measured:PASS                  every timed cursor ran once per run
ASSERT:s2c-us-purge-effective:PASS           every purge left no cursor
ASSERT:s2c-us-same-plan:PASS                 each timed cursor ran the counted cursor's plan
ASSERT:s2c-teardown-clean:PASS
```

No assertion checks the direction of any crossover or how it moves with M or N.

Metrics:

- `s1c-k{100|1000}-m{5|20|100|500}-{childtable|orderdocs|orderdocs-jsontable|orderdocs-serialized}-reads`;
- `s1c-k{k}-{doc|join}-reads`, `s1c-k{k}-doc-bytes`;
- `s1c-k{k}-m{M}-crossover-item-queries-per-1000-order-reads` (or `s1c-k{k}-m{M}-no-crossover`);
- `s1c-k{k}-m{100|500}-{reader}-{reads-median|reads-min|reads-max|cpu-cs-median|cpu-cs-max|elapsed-cs-median|elapsed-cs-max|overhead-*}` (from `measure_repeat`);
- `s2c-n{10|100|1000}-{embedded-update-docs|normalized-update-rows}`, `s2c-n{N}-{embedded|normalized}-update-{reads|redo}`;
- `s2c-n{N}-embedded-read-reads`, `s2c-n{N}-normalized-read-{pk|covered}-reads`, `s2c-n{N}-normalized-read-reads`;
- `s2c-n{N}-crossover-updates-per-1000-reads` (or `s2c-n{N}-no-crossover`);
- `s2c-n{100|1000}-embedded-update-{timed-reads-median|cpu-cs-median|cpu-cs-max|elapsed-cs-median|elapsed-cs-max}`;
- `s2c-idx-{cust-pk|cust-cov|ord-pk|ord-cov|doc-pk|doc-cust}-blevel`, `s1c-meter-overhead-reads`, `s2c-meter-overhead-{reads|redo}`;
- from `measure_us` / `measure_dml_us`: `s1c-k{k}-m{M}-{reader}-{us|ela-us|gets|bytes}`, `s1c-k{k}-{doc|join}-{us|ela-us|gets}` (and `s1c-k{k}-join-bytes`), `s1c-k{k}-m{M}-orderdocs-us`; `s2c-n{N}-{statement}-{us|ela-us|gets}`, `-bytes` for the reads, `s2c-n{N}-normalized-read-us`;
- the CPU crossovers `s1c-k{k}-m{M}-crossover-item-queries-per-1000-order-reads-us` (or `s1c-k{k}-m{M}-no-crossover-us`) and `s2c-n{N}-crossover-updates-per-1000-reads-us` (or `s2c-n{N}-no-crossover-us`).

### S4: one canonical form, two documents (`scripts/40-s4-two-projections.sql`)

Stonebraker and Pavlo make two claims about document databases (section 2.3,
p.23): "if the join is not one-to-many, then there will be duplicated data", and
"there is no data independence". S4 tests both with one setup. It is a
correctness check, not a measurement.

The canonical form is three normalized tables: customers, orders, and order
lines. Each customer's name is stored once, in the customer row. Two duality
views project that one canonical form as two different documents. The
customer-centric view is created before the data is loaded; the order-centric
view is created after the data is loaded and committed, the way a second
application would arrive later:

| View | Document | Can it change the customer name? |
|---|---|---|
| `m08s4_cust_dv` | a customer with its `orders[]`, each with its `lines[]` | yes |
| `m08s4_ord_dv` | an order with its `lines[]` and a nested `customer {custId, name}` | no, the nested customer is read-only here |

When the order-centric view is created, the script checks that it returns all
8 stored orders at once, with their 16 lines and the right customer names, and
that creating it changed nothing stored: the same tables, the same columns
(system-generated ones included) and the same hash over every row, before and
after.

Customer 1 has 5 orders. The script changes customer 1's name once, through the
customer-centric view (`JSON_TRANSFORM` on the document). Then it reads all 5
order documents through the order-centric view. Every one shows the new name at
once. There is no sync job and no fan-out update, because there is only one copy
of the name to change.

**What it proves.**

- **No duplicated data.** The order-centric document shows the customer's name,
  but the name is not copied into any order. A scan of every text and JSON
  column in the S4 tables finds the new name exactly once (`s4-name-copies`),
  and the order and line tables have no name column at all.
- **Data independence.** One canonical form serves two document shapes. Neither
  application has to know how the data is stored, and neither shape forces a
  storage layout on the other. Adding the second shape over data that was
  already stored took one view definition, not a data migration
  (`s4-second-view-after-load`).
- **Clear ownership of each change.** The order-centric view can show the name
  but cannot change it. The database refuses the attempt; only the
  customer-centric view changes the name.

The cost is real: each order document is assembled by a join on every read.
S1, S1b and S2 measure that join. S4 shows what the join buys: one copy of the
name, and any number of document shapes over it.

Expected assertions:

```
ASSERT:s4-one-row-changed:PASS
ASSERT:s4-order-view-reflects:PASS
ASSERT:s4-no-copies:PASS
ASSERT:s4-order-view-shape:PASS
ASSERT:s4-second-view-after-load:PASS
ASSERT:s4-order-view-customer-readonly:PASS
ASSERT:s4-teardown-clean:PASS
```

- `s4-one-row-changed`: the view update changed one document, and exactly one
  customer row holds the new name.
- `s4-order-view-reflects`: all 5 order documents showed the old name before the
  change, and all 5 show the new name after it.
- `s4-no-copies`: the new name is stored exactly once, and orders and lines have
  no name column.
- `s4-order-view-shape`: the order document has its own fields plus
  `customer.name` and no `orders` array; the customer document has an `orders`
  array of 5 and no nested customer. The two projections really are different
  shapes.
- `s4-second-view-after-load`: the order-centric view, created after the data
  was loaded and committed, returns all 8 orders with their 16 lines and each
  order's customer name, and the tables, columns and rows are the same before
  and after it was created.
- `s4-order-view-customer-readonly`: the dictionary marks the customer table
  read-only in the order-centric view, and an attempt to change the name through
  it is refused.

Metrics:

- `s4-docs-updated`;
- `s4-order-docs-showing-new-name`;
- `s4-order-view-docs-after-load`;
- `s4-name-copies`.

### S5: one request for a parent and all its children (`scripts/50-s5-single-collection.js`)

Stonebraker and Pavlo say about key-value stores (section 2.2): "If an
application requires multiple fields in a record, then KV stores are probably a
bad idea", and that "developers must implement joins or multi-get operations in
their application". S5 shows the single-collection design answering that
through the MongoDB API. It is a correctness check, not a measurement.

The pattern is vendor-neutral document modeling theory. It works in any store
that can read a range of items by a partition key and a sort key.

Every document in the collection `m08s5_single` carries two keys:

| Field | Order header | Line item |
|---|---|---|
| `_id` | `ORD#7` | `ORD#7#LINE#001` |
| `pk` (partition key) | `ORD#7` | `ORD#7` |
| `sk` (sort key) | `#ORDER` | `LINE#001` |
| `type` | `order` | `line` |

The header and its lines share one partition key, so together they form one
item collection. The sort key puts the header first, because `#` sorts before
`L`, and line numbers are zero-padded so `LINE#010` sorts after `LINE#009`. An
index on `{pk: 1, sk: 1}` finds the item collection.

The script seeds 3 orders with 5, 10 and 25 lines, inserted out of order and
interleaved across orders. It then reads each order with one find command,
`{find: "m08s5_single", filter: {pk: "ORD#7"}, sort: {sk: 1}}`, sent as a raw
command so the script can see the server's reply. The reply carries a cursor
id. An id of 0 means the server sent every document in that first reply and
closed the cursor, so no follow-up request (getMore) is needed.

**What it proves.**

- **One request, the whole order.** For every order, the first reply to one
  find holds the header and every line, already in order, and its cursor id is
  0. The app does no join and no multi-get.
- **The database does the work.** The plan reads the `{pk, sk}` index by range
  scan; nothing scans the whole table. The index locates the item collection,
  and a separate sort step in the database orders it: the plan is a multivalue
  index range scan followed by a sort on `sk`. The result order does not depend
  on how the documents were written.

Because each line is its own document, it can also be inserted, changed or
deleted on its own, without rewriting the order. S5 does not check that; it is
a property of the layout.

Expected assertions:

```
ASSERT:s5-one-find-returns-all:PASS
ASSERT:s5-types:PASS
ASSERT:s5-sorted:PASS
ASSERT:s5-index-used:PASS
ASSERT:s5-no-cross-talk:PASS
ASSERT:s5-teardown-clean:PASS
```

- `s5-one-find-returns-all`: for each of the 3 orders, the first reply to one
  find command holds all 1 + k documents, and its cursor id is 0.
- `s5-types`: each result holds exactly one `order` and k `line` documents.
- `s5-sorted`: each result starts with the `#ORDER` header, followed by
  `LINE#001` up to `LINE#k` in order. The sort order is checked, not assumed.
- `s5-index-used`: `explain()` shows an index range scan on `pk_1_sk_1` and no
  full scan.
- `s5-no-cross-talk`: a find for one order returns no documents from another.
- `s5-teardown-clean`: the collection is gone at the end.

Metrics:

- `s5-requests` (requests needed to read one order: 1 for the find, plus one
  per getMore; the largest over the 3 orders);
- `s5-docs-returned-k25` (documents that one request returned for the 25-line
  order).

### S3 at scale (B): what the unchanged app pays at each stage (`scripts/60` to `scripts/69`)

S3 shows that the same app code gets the same results while the storage
moves, on 8 orders, and measures no cost. This runs the same four stages on a
separate collection, `m08b3_orders`, with 20,000 orders, and measures what each
unchanged app statement costs at each stage.

The build is the one named under "Build measured" above; every statement below
about how the product behaves means "on this build".

**Data** (`60-s3b-seed.js`). 20,000 orders, seeded through the MongoDB API with
`insertMany` in batches of 1,000 from a fixed-seed generator, so every run
loads the same data. Each order has 5 to 15 lines `{lineId, sku, qty}` (200,050
lines in all; `lineId` is unique across orders), a `customer` (2,000 values), a
`status` (5 values; `open` is about 10%) and a `ship` address. There are 500
skus: `SKU-HOT` is 1.5% of all lines (on 2,795 orders), `SKU-RARE` is on
exactly 3 orders, and the other 498 are skewed toward the low numbers.

**Stages and indexes.** Each stage gets the indexes a DBA would add for the
statements' predicates.

| Stage | Script | Storage under `m08b3_orders` | Indexes |
|---|---|---|---|
| 0 | `60` | a plain collection | `createIndex` on `items.sku` and on `status`; the API builds both as multivalue indexes |
| 1 | `62` | a table with one JSON column (`data`), behind a duality view | a multivalue index on `data.items[*].sku.string()` and a function-based B-tree on `json_value(data, '$.status')` (a different shape from the stage-0 `status` index) |
| 2 | `65` | `customer` and `status` promoted to columns | a B-tree on the `status` column (the JSON `status` index is dropped); the multivalue sku index stays |
| 3 | `67` | lines moved to `M08B3_LINES`, keyed by `line_id`; `order_id` is a NOT NULL foreign key, not selected | a B-tree on `M08B3_LINES.sku` and the foreign key index on `order_id` (the multivalue sku index is dropped) |

**Statistics.** After every load or move, `dbms_stats.gather_table_stats` with
`method_opt => 'FOR ALL COLUMNS SIZE AUTO FOR ALL INDEXED COLUMNS SIZE 254'`:
an explicit histogram on every indexed column, so the optimizer sees the skew
in `status` and `sku`. The default, gathered right after a load, builds no
histograms, because no query has used the columns yet. The metrics
`s3b-stage<N>-hist-<index>` record which of the module's own indexes have a
histogram: all of them except the multivalue indexes, whose columns cannot
carry one.

`63-s3b-cutover-recycle-api.sh` restarts the API tier after the 0 to 1 move,
as in S3, and checks that the four measuring scripts are identical. The
stage-0 indexes are made on the empty collection, before the load: on this
build, `createIndex` on a loaded collection fails ("specified length too long
for its datatype"), because
`MAX_STRING_SIZE` is `STANDARD`. The stage-3 lines are loaded by one
`INSERT ... SELECT`, so each order's lines sit together, which is the friendly
layout for the view's join (S1 measures the interleaved one).

**The app statements** (in `61`, `64`, `66` and `68`, which are byte-identical
and work out the stage from the schema):

| Name | Statement |
|---|---|
| `byid` | `find({_id: 12345})` |
| `status` | `find({status: 'open'})` (2,057 documents) |
| `sku-hot` | `find({'items.sku': 'SKU-HOT'})` (2,795 documents) |
| `sku-rare` | `find({'items.sku': 'SKU-RARE'})` (3 documents) |
| `agg-status` | `aggregate([{$match: {status: 'open'}}, {$group: {_id: '$customer', n: {$sum: 1}}}])` |
| `agg-unwind` | `aggregate([{$unwind: '$items'}, {$group: {_id: '$items.sku', q: {$sum: '$items.qty'}}}])` |

**How it is measured.** For each statement at each stage: `explain()` through
the MongoDB API gives the SQL the API generated, its `sql_id` and the plan.
The statement's cursors are purged (`dbms_shared_pool.purge`, checked: no
cursor of that `sql_id` is left afterwards), so each one is parsed for its own
value; `SKU-HOT` and `SKU-RARE` share one SQL text and
would otherwise share one plan. Then one warm-up run and 20 measured runs, each
fetching every result document. Buffer gets (logical reads), CPU and elapsed
time are the growth of `v$sql` for that `sql_id` over the 20 runs, divided by
20. **These are database-side numbers only:** they leave out the API tier and
the network. Finally the cursor is purged again and run once with
`statistics_level = ALL`, and `dbms_xplan.display_cursor(..., 'ALLSTATS LAST')`
gives the executed plan with rows and buffers per step; its plan hash must
match the measured cursor's. The API sends the same SQL text at every stage
(the `sql_id` does not change), because it queries the name `m08b3_orders`,
whatever is behind it.

**Cheaper, the same, or slower.** Both logical reads and CPU per call count,
each compared with the stage named. Reads within about 1%, and CPU within
about 10% or under 0.1 ms per call, count as unchanged. A statement is
*cheaper* when one of the two goes down and the other does not go up, *slower*
when one goes up and the other does not go down, and *the same* when neither
changes. When one goes down and the other up, the text names both.

**Results.** Ranges over the four runs; the article takes its numbers from
`validator/results.json`. Logical reads per call, with CPU per call in
milliseconds in brackets:

| Statement | Stage 0 (collection) | Stage 1 (view, JSON column) | Stage 2 (promoted columns) | Stage 3 (lines table) |
|---|---|---|---|---|
| `byid` | 3 (0.01 to 0.03) | 3 (0.05 to 0.09) | 3 (0.04 to 0.07) | 9 (0.06 to 0.08) |
| `status` | 1,200 to 1,202 (2.5 to 3.1) | 1,526 to 1,528 (462 to 465) | 1,526 to 1,528 (44 to 51) | 7,380 to 7,416 (72 to 74) |
| `sku-hot` | 1,387 to 1,388 (2.9 to 3.0) | 1,530 to 1,533 (492 to 495) | 1,530 to 1,533 (489 to 495) | 9,913 to 9,938 (103 to 108) |
| `sku-rare` | 6 (0.01 to 0.02) | 1,508 (426 to 433) | 1,508 (423 to 428) | 30 (0.08 to 0.14) |
| `agg-status` | 1,173 to 1,174 (11.6 to 12.1) | 1,508 (463 to 468) | 1,508 (57 to 58) | 20,137 to 20,324 (1,115 to 1,128) |
| `agg-unwind` | 1,577 to 1,634 (1,462 to 1,476) | 1,508 (2,354 to 2,404) | 1,508 (2,341 to 2,387) | 17,224 to 17,420 (3,384 to 3,460) |

**Direct-SQL controls** (same four runs; SQL sent straight to the tables, not
app statements):

| Stage | Control | Reads per call | CPU ms | Executed plan |
|---|---|---|---|---|
| 1 | the API's `status` predicate, `json_exists(data, '$?(@.status.stringOnly() == $B0)')`, on `M08B3_ORDERS_T` | 1,517 to 1,518 | 9.5 to 10.1 | full scan |
| 1 | `json_value(data, '$.status') = 'open'` on `M08B3_ORDERS_T` | 1,517 to 1,518 | 3.8 to 5.9 | full scan (the function index is not chosen for 10% of the rows) |
| 1 | the API's `items.sku` predicate on `M08B3_ORDERS_T`, `SKU-RARE` | 6 | 0.01 to 0.02 | multivalue index range scan on `M08B3_T_SKU_MVI` |
| 1 | `json_exists(data, '$.items[*]?(@.sku.string() == $B0)')`, `SKU-RARE` | 6 | 0.01 to 0.04 | the same index |
| 3 | `select sku, sum(qty) from m08b3_lines group by sku` | 878 | 6.8 to 7.1 | full scan of `M08B3_LINES`, hash group by |
| 3 | `select ... from m08b3_lines where sku = 'SKU-RARE'` | 6 | 0.002 to 0.003 | index range scan on `M08B3_LINES_SKU_IX` |

**Plain reading.**

- **No statement is cheaper at any later stage than on the plain collection.**
  The best any of them does is tie (`byid` at stages 1 and 2: the same 3
  reads, CPU under 0.1 ms per call). `agg-unwind` at stages 1 and 2 is mixed:
  about 4 to 8% fewer reads (1,508 against 1,577 to 1,634), but about 60% more
  CPU.
- **Stage 0 to 1, the day-one cost of putting a view in front: four of six
  statements got slower on both reads and CPU; `agg-unwind` is mixed (about 4 to 8%
  fewer reads, 1,577 to 1,634 down to 1,508, but about 60% more CPU, about 1.5
  to about 2.4 seconds); `byid` stayed the same.** On this build, MongoDB API
  filters on fields stored in the flex column are applied to the constructed
  document and cannot use indexes on the underlying column; fields mapped to
  real columns (here only `_id`) are pushed down. The executed plan is a full
  scan of `M08B3_ORDERS_T` with `JSON_EXISTS2(JSON_OBJECT(...))` as the
  filter, so every one of the 20,000 documents is built per call. The
  controls prove the view is the blocker for `items.sku`: the same predicate
  sent straight to the table uses the multivalue index and reads 6 blocks, the
  same as the collection, against 1,508 through the view. For `status` the
  direct control also scans the table (the optimizer does not pick the
  function index for 10% of the rows), so there the view adds CPU, not reads:
  about 10 ms direct against about 460 ms through the view, for about the
  same reads (1,517 to 1,528).
- **Stage 1 to 2: `status` and `agg-status` got cheaper; the other four stayed
  the same.** With `status` a real column, the filter is pushed down to
  `"T"."STATUS"=:1`, so no document is built to test it. CPU falls about
  tenfold (`status` from about 460 ms to 44 to 51 ms, `agg-status` from
  about 465 ms to about 57 ms). Reads do not change: even with a
  frequency histogram on `status`, the optimizer scans the table rather than
  use the B-tree for 2,057 of 20,000 rows. A covering B-tree on
  `(status, customer)` for `agg-status` was tried by hand: its plan stayed a
  full scan, because the generated SQL reads the whole document (`DATA`) from
  the view, so it was not kept.
- **Stage 2 to 3: `sku-rare` got cheaper on both; `sku-hot` is mixed (CPU
  down, about 490 to about 105 ms; reads up, about 1,530 to about 9,925); the
  other four got slower.** The executed plans account for every read (their
  per-step buffer counts come from one earlier plan-capture run, so totals can
  differ from the table by a few reads for small counts and about 1% for large
  ones):
  - `items.sku` is now pushed down to the lines table. `sku-rare` uses the
    `sku` B-tree (6 reads), then the order's primary key (8), then builds each
    of the 3 documents' `items` array from `M08B3_LINES_ORDER_IX`. That last
    step runs two per-order line lookups (two `SORT GROUP BY` subqueries, 8
    reads each), so the total is 30 reads, against 1,508 at stage 2 and 6 on
    the collection. `sku-hot` becomes a hash semi-join of full scans of the
    lines (878) and the orders (1,535), plus the two lookups for 2,795 orders
    (3,785 each): about 9,910 to 9,940 reads, but about 105 ms of CPU against
    about 490.
  - `byid` and `status` now build each order's `items` from the lines table,
    with the same two lookups per order: `byid` 3 + 3 + 3 = 9 reads; `status`
    1,528 for the scan plus 2 x 2,927 for 2,057 orders.
  - `agg-status` lost the `status` pushdown it had at stage 2. Its `FILTER`
    tests `JSON_EXISTS2` on a document that includes the lines subquery, so
    the lines lookup runs for all 20,000 orders (15,841 reads), plus 2,894 for
    the 2,057 matches and 1,508 for the scan: about 20,140 to 20,320 reads, 1.1
    seconds.
  - `agg-unwind` is not pushed down to a `GROUP BY` on `M08B3_LINES`. The plan
    scans the orders (1,508 reads) and runs `JSON EXPAND ARRAY EVALUATION`
    20,000 times over the built `items` arrays, which reads each order's lines
    (15,842): about 17,220 to 17,420 reads, 3.4 to 3.5 seconds. The same answer in SQL straight
    against the lines table (control) reads 878 blocks in 7 ms.

So the app keeps working, unchanged, at every stage, and gets the same results
(S3 and these checks). It does not get faster here. On this build, with these
indexes and statistics, every move away from the plain collection made most
unchanged statements cost more, and a promoted column won back part of what
the view cost on day one. The duality view is a join, and it is measured as
one. What the later moves do buy is shown by the controls: once the lines are
a table, new SQL can answer the sku questions from it directly (6 reads for
`SKU-RARE`, 878 for the whole per-sku total). The data independence here is
that the storage can move without breaking the app, not that the move makes
the unchanged app cheaper.

Expected assertions:

```
ASSERT:s3b-seeded:PASS
ASSERT:s3b-stage1-rows:PASS
ASSERT:s3b-measure-copies-identical:PASS
ASSERT:s3b-api-recycled:PASS
ASSERT:s3b-stage2-columns:PASS
ASSERT:s3b-stage3-lines:PASS
ASSERT:s3b-stage<N>-plans-captured:PASS            (N = 0 to 3)
ASSERT:s3b-stage<N>-executed-plan-matches:PASS
ASSERT:s3b-stage<N>-measured:PASS
ASSERT:s3b-stage<N>-purge-effective:PASS
ASSERT:s3b-stage<N>-same-results:PASS
ASSERT:s3b-stage<N>-normalizer-detects-change:PASS
ASSERT:s3b-all-stages-same-results:PASS
ASSERT:s3b-all-stages-plans-captured:PASS
ASSERT:s3b-teardown-clean:PASS
```

- `same-results`: each statement's result, normalized (no `_metadata`, keys
  sorted, numbers as plain numbers, every array sorted, so array and result
  order do not count), hashes the same as at stage 0, with the same count.
- `plans-captured`: every statement's `explain()` gave a `sql_id`, generated
  SQL and a plan.
- `executed-plan-matches`: every statement's and every control's `ALLSTATS
  LAST` plan has row and buffer counts, and its plan hash equals the measured
  cursor's.
- `purge-effective`: after every purge, `v$sql` holds no cursor of that
  `sql_id`, so the next run is parsed fresh.
- `measured`: each measured `sql_id` (statements and controls) executed at
  least once per call, so the `v$sql` numbers belong to it.
- `measure-copies-identical`: `61`, `64`, `66` and `68` have the same MD5.
  They are copies because mongosh reads each script from stdin inside the
  container, where `load()` cannot reach the module folder.
- `normalizer-detects-change`: a changed document does not hash the same.
- No check compares costs between stages.

Metrics: `s3b-<statement>-stage<N>-gets`, `-cpu-us` and `-ela-us` (per call;
CPU and elapsed in microseconds) for the six statements and four stages; the
same for the controls as `s3b-ctl-<control>-stage<N>-...`; and
`s3b-stage<N>-hist-<index>` (1 if the index's column has a histogram).
Large read counts repeat within about 1% from run to run, with one exception:
`agg-unwind` at stage 0 read 1,634 in one run against 1,577 in the other
three. Small counts can move by a few reads. CPU and elapsed time are noisy on this
shared container, so read them as sizes, not exact values.

The executed plans need two grants beyond the earlier ones, in
`docker/init/01-lab-user.sql`: `SELECT` on `V_$SQL_PLAN_STATISTICS_ALL` (read
by `dbms_xplan.display_cursor`) and `EXECUTE` on `DBMS_SHARED_POOL` (the
purge).

### Writes (D): writes through views, knob 3, etags, and a materialized view (`scripts/70-writes.sql`, `scripts/71-writes-api.js`)

S2 measured one kind of write: a customer field copied into many orders. That
left four questions open. What does it cost to write through a duality view?
What does a small change to a large document cost (knob 3: which fields the
writes change; Liu and Houlihan, *The Elements of Data*, forthcoming)? When a
customer is renamed, does every order document that shows the customer get a
new etag? And what about letting the database keep the copy in sync, with a
materialized view? These two scripts measure all four and report what happens.
No check compares costs.

**How it is measured.** Logical reads, redo bytes and CPU come from the
session statistics, taken around one write plus its `COMMIT`. The `COMMIT` is
inside every window for two reasons: the materialized view refreshes at
`COMMIT`, and a small transaction keeps its redo in a private buffer until
`COMMIT`, so a window that closed earlier showed 0 redo for some writes. Each
write runs once to warm up, then 20 more times; the tables show the median of
the 20. Samples are kept in memory during a loop and stored after it, so no
measured `COMMIT` carries another write. The meter's own overhead is removed
from reads and redo. Session statistics include recursive SQL, so the duality
view's own statements and the materialized view's refresh are counted; those
statements are also listed from `v$sql` (executions, rows and buffer gets per
call, with their text) as `wr-vs-*` metrics and `PLAN` rows. The session CPU
statistic is at or below 1 centisecond for nearly every write here, so CPU is
also taken in microseconds from `v$sql` (table 6 below). The executed plan of
every measured statement is printed as `PLAN` rows. Every figure is a range
over the four runs: a range ("21 to 24") means the runs differed, a single
figure means all four agreed. Large read counts repeat within about 2%; redo medians move by up to
about 9% (the positional knob-3 change: 27,592 to 30,024 bytes); small read
counts move by a few in any run.

**The indexes are not the same on both sides.** The collection has one index,
on `_id`. The orders and lines tables have a primary key each and an index on
the lines' `ord_id` (needed for the join). Every insert into the tables
maintains three indexes; every insert into the collection maintains one. That
is each model's minimal setup, and it favors the collection on inserts.

**1. Insert an order with k lines.** Four ways to store the same order: one
document into a JSON collection table; the same document through a duality
view over an orders table and a lines table; plain SQL, one order row plus k
line rows in one `FORALL` (one array insert); and plain SQL, one order row
plus k single-row `INSERT`s in a loop. Order ids are handed out in call order,
so every insert lands at the right edge of the indexes.

| k | collection: reads / redo | duality view | plain SQL, array | plain SQL, row by row |
|---|---|---|---|---|
| 10 | 6 / 1,288 to 1,332 | 98 / 7,988 to 8,044 | 15 / 2,584 to 2,628 | 76 / 7,988 to 8,016 |
| 100 | 8 / 3,908 | 918 to 920 / 76,672 to 76,812 | 18 to 21 / 10,864 to 10,984 | 716 to 717 / 77,984 to 78,028 |

The document insert is one row and one index entry, so it is the cheapest.
The array insert keeps the plain SQL lines to about 100 bytes of redo each.
The duality view costs about what the row-by-row SQL insert costs, and no less
in reads: about 28% more reads (918 to 920 against 716 to 717) and about 2%
less redo at k = 100 (76,672 to 76,812 against 77,984 to 78,028 bytes). Yet `v$sql` shows the
view sending its lines as one statement per document
(`wr-vs-ins-dv-k100-insert-line-execs-per-call` = 1, rows per call
100, 727 to 729 gets per call). That statement
returns each row's etag (`RETURNING ... sys_row_etag(...)`), and it is
processed at row-by-row cost, not at array cost. These numbers do not show
why. Writing through the view is the convenient path, not the cheap one, and
the cost grows with the number of child rows.

**2. Knob 3: change one line's qty in a 1,000-line order.** The document is
38,952 bytes as JSON text and 24,406 bytes as OSON
(`wr-k3-doc-oson-bytes`, the document encoded again as OSON, not the stored
LOB's length); its row holds only a 138-byte LOB locator, so the
body is stored out of the row. Every run writes a new 3-digit value, so every
change has the same length.

| Path | Reads | Redo (bytes) |
|---|---|---|
| collection, `JSON_TRANSFORM`, line found by `lineId` | 31 to 33 | 27,592 to 27,604 |
| collection, `JSON_TRANSFORM` by position (`$.lines[499]`) | 31 to 34 | 27,592 to 30,024 |
| collection, whole document replaced | 23 to 24 | 29,440 to 29,836 |
| duality view, the `lineId` `JSON_TRANSFORM` | 29 to 31 | 588 |
| lines table, one-row `UPDATE` | 6 | 588 |

The duality view writes exactly what the one-row `UPDATE` writes (the same
redo in each run), because it changes only the line row whose value changed:
`v$sql` shows one etag read of the document and one etag-checked line update
per call. It reads more to get there: it rebuilds the order's 1,000 lines to
find the change (the plan shows the line index range scan returning 1,000
rows). The collection writes a little more redo than its stored size for a
change of one number, whether the line is found by a filter or by position,
and about the same as replacing the whole document: on this stack, with this
out-of-row document, `JSON_TRANSFORM` did not make a smaller, partial update.
That is knob 3 in one line: a small change to a large embedded document pays
for the document's size, not the change's. A few collection runs cost far
more (up to 877 reads and 322,180 bytes of redo across the four runs), probably LOB space
management (not checked); the median ignores them.

**3. The same change through the MongoDB API** (`71`): `updateOne` with a
positional `$set` (`{'lines.$.qty': q}`), on a collection and on a duality
view of the same shape. The API does not send one `UPDATE`. For both targets
it reads the whole document with `SELECT ... FOR UPDATE`, applies the `$set`
in the API tier, and writes the whole document back. Per call, from `v$sql`
(statements and their gets) and from `v$mystat` (the session totals, read
through `$sql` in the API's own session; the session id was the same before
and after):

| Target | Statements per call (gets each) | Reads (session) | Redo (session) |
|---|---|---|---|
| collection | select for update (15.0), document update (17.1 to 65.9) | 35.1 to 86.8 | 39,418 to 54,339 |
| duality view | select for update (2,050.0 to 2,051.0), two etag reads (10 to 11, 14 to 16), line update (4.0 to 4.1), view update (44.1 to 48.0) | 2,095.6 to 2,100.0 | 223,772 to 224,926 |

The duality view still changes only one line row, but the API's read with
`FOR UPDATE` locks every row of the order. `70` measures that read alone in
SQL, with its `COMMIT`:

| `SELECT ... FOR UPDATE` of order 1 | Reads | Redo (bytes) | Undo records (about one per locked row) |
|---|---|---|---|
| collection | 8 | 548 | 1 |
| duality view | 1,038 to 1,039 | 223,544 | 1,002 |

On the view, the read locks the order row and all 1,000 line rows, and each
lock writes redo: that is most of the API's redo for the view. That is 1,001
locked rows and 1,002 undo records, so the count is about one per locked row,
not exactly one; the extra record was not traced. The undo count is read from
`v$transaction` before the `COMMIT`, inside the measured window, so the reads
of that small query are part of both rows' figures. Through SQL the
same change cost 29 to 31 reads and 588 bytes. The API's read-modify-write is
the cost here, not the view. On the collection, in two of the four runs, the API
wrote about 1.8 times the redo of the SQL whole-document replace (54,054 to
54,339 against 29,440 to 29,836), with the document update at 47.8 to 65.9
gets per call, although its lock costs little and its write is one
statement. In the other two runs it wrote 39,418 to 39,714, with the document
update at 17.1 to 17.2 gets per call. Neither difference is explained. An app that changes one
line of a large order will do better with SQL (`JSON_TRANSFORM` through the
view, or a row update) than with a positional `$set`.

**4. Etags after a rename (the S4 shape).** Two duality views over customers,
orders and lines: a customer-centric one, and an order-centric one with a
nested, read-only customer `{custId, name}`. The script records each order
document's `_metadata.etag`, renames customer 1 once through the customer
view, and reads the order documents again.

- All 5 of customer 1's order documents have a new etag
  (`wr-s4d-etags-changed`); customer 2's 3 orders do not
  (`wr-s4d-other-etags-changed` = 0). The rename itself wrote one row
  (768 bytes of redo and 84 to 86 reads, commit included).
- A write to order 1 with the etag read before the rename is refused with the
  etag mismatch error (`wr-s4d-stale-write-rejected` = 1), and changes
  nothing.

So the rename does not rewrite any order: the etag is computed from the rows
when the document is read, and the nested customer's fields are part of it by
default. The effect is on concurrency, not on storage. A client that read an
order before the rename and writes it back afterwards gets a conflict and
must read again, even though nothing in the order itself changed. That is the
same rule as for any other change to a document the client holds, and it is
the safe default. A view can leave fields out of the etag (the `NOCHECK`
annotation); this script does not measure that.

Two controls show the check works: a fresh read written back is accepted, and
a write with the etag from before the writer's own change is refused.

**5. A materialized view arm.** S2's data shape (100,000 customers, 20,100
orders, customer 1 has 100). One order is read with its customer's name and
tier, and customer 1's tier changes, three ways:

- embedded: order documents carrying the customer snapshot, as in S2;
- normalized: the order and customer tables, read with a join;
- materialized view: the normalized tables plus `M08D_ORD_CUST_MV`, a join
  materialized view (order plus customer name and tier) with materialized view
  logs, `REFRESH FAST ON COMMIT`. 26ai Free accepted FAST ON COMMIT for this
  shape (`wr-mv-fast-on-commit` = 1), and the dictionary reports the
  refreshes as fast (`wr-mv-refresh-method` = FAST, `wr-mv-last-refresh-type` =
  FAST, `wr-mv-staleness` = FRESH). Its rowid columns are indexed,
  as the documentation advises.

The normalized tier change was measured before the logs existed, so it pays
no log cost. The MV starts with customer 1 at SILVER; its 121 tier changes (a
warm-up, 20 counted and 100 CPU runs) start with GOLD, and after every `COMMIT` the script checks that all 100 of
customer 1's MV rows show the new tier (checked: every one).

| Arm | Order read: reads | Tier change + COMMIT: rows | reads | redo (bytes) |
|---|---|---|---|---|
| embedded | 3 | 100 documents | 1,001 | 157,444 |
| normalized (join) | 6 | 1 row | 6 | 600 |
| materialized view | 3 | 1 row, then 100 view rows at COMMIT | 1,981 to 2,010 | 177,796 to 178,476 |

The materialized view reads like the embedded document (one index probe and
one row) and stays correct after every `COMMIT`. But it moves the fan-out, it
does not remove it. Per `COMMIT`, `v$sql` shows the refresh deleting customer
1's 100 view rows (787.1 to 790.3 gets) and inserting 100 new ones
(870.3 to 898.2 gets), plus the log row written and cleared. That costs more reads
and more redo than updating the 100 embedded copies directly. The database
keeps the copy in sync, so the app cannot forget a copy, and the cost of the
copy is still paid on every change. Only the normalized form pays for the
change once.

**6. CPU per write.** After the 20 counted runs, each write runs 100 more
times; `wr-<write>-us` is the growth of `v$sql` over those 100, for the
write's own statements, divided by 100 (about 10 microseconds per run of
resolution; see the harness). No parse is counted. A write through a duality view or
with an MV log runs its internal statements inside the write, and they are
part of its figure; the `v$sql` buffer gets of the view writes match their
session logical reads (`wr-ins-dv-k100-gets` 933 to 937 against 918 to 920 reads), so
the figure includes them. The `COMMIT` is not a statement, so it is not in
these figures, but each statement's undo and redo generation is. The
materialized view's refresh runs inside the `COMMIT`; its statements are
listed separately (`wr-vs-mv-refresh-<statement>-us-per-call`) and added to
the update in `wr-mv-upd-mv-total-us`. The three order reads of part 5 are
timed with `measure_us` (200 runs). Reads and redo are in tables 1 to 5; this
table gives CPU and elapsed only, over the four runs.

| write or read | k | CPU us | elapsed us |
|---|---|---|---|
| insert, collection | 10 | 37 to 43 | 37 to 43 |
| insert, collection | 100 | 49 to 54 | 49 to 54 |
| insert, duality view | 10 | 120 to 159 | 120 to 193 |
| insert, duality view | 100 | 733 to 969 | 737 to 2,156 |
| insert, plain SQL array | 10 | 38 to 64 | 38 to 66 |
| insert, plain SQL array | 100 | 144 to 159 | 144 to 160 |
| insert, plain SQL row by row | 10 | 75 to 80 | 75 to 80 |
| insert, plain SQL row by row | 100 | 749 to 777 | 758 to 22,294 |
| knob 3, collection, by lineId | | 856 to 865 | 848 to 894 |
| knob 3, collection, by position | | 707 to 768 | 1,143 to 1,521 |
| knob 3, collection, whole document | | 106 to 113 | 668 to 2,654 |
| knob 3, duality view | | 2,882 to 3,081 | 2,918 to 3,088 |
| knob 3, lines table | | 10 to 18 | 10 to 18 |
| SELECT FOR UPDATE, collection | | 20 to 27 | 20 to 27 |
| SELECT FOR UPDATE, duality view | | 6,346 to 6,431 | 8,659 to 10,293 |
| tier change, embedded | | 2,739 to 2,855 | 4,482 to 4,851 |
| tier change, normalized | | 11 | 11 |
| tier change, materialized view (update only) | | 97 to 105 | 97 to 105 |
| tier change, materialized view, with its refresh at COMMIT | | 6,739 to 6,919 | |
| order read, embedded | | 9 | 9 |
| order read, normalized (join) | | 3 | 3 |
| order read, materialized view | | 2 | 2 |

- **Inserts.** At 100 lines the document insert uses the least CPU (49 to 54
  microseconds). The array insert of the plain SQL rows uses about 3 times
  that (144 to 159); the duality view and the row-by-row SQL insert use about
  14 to 20 times (733 to 969 and 749 to 777), and those two overlap. At 10
  lines the collection and the array insert overlap (37 to 43 and 38 to 64).
- **Knob 3, one line in a 1,000-line order.** The row update uses 10 to 18
  microseconds. The collection's `JSON_TRANSFORM` uses about 710 to 870, and
  replacing the whole prepared document about 105 to 115. Through the duality
  view the same change uses about 2,900 to 3,100 microseconds, about 160 to
  310 times the row update, although it writes exactly the row update's redo:
  the view rebuilds the 1,000-line document to find the line.
- **`SELECT ... FOR UPDATE`** of the order takes 20 to 27 microseconds on the
  collection and about 6,350 to 6,430 on the view, which locks 1,001 rows.
- **The materialized view.** The tier change itself uses about 100
  microseconds, and its refresh at `COMMIT` about 6,600 to 6,800 more
  (deleting and inserting customer 1's 100 view rows): about 6,700 to 6,900
  in all, about 2.4 to 2.5 times the CPU of updating the 100 embedded copies
  directly (about 2,700 to 2,900) and about 610 to 630 times the normalized
  update (11).
- **The order read.** The normalized join (3 microseconds) and the
  materialized view (2) use less CPU than the embedded document (9), which is
  serialized to text.

**What it shows.** Writes are where the shape of the stored data shows up
most. A document is the cheapest thing to insert and the most expensive thing
to change a little of. Rows are cheap to change and cost more to insert. A
duality view changes exactly the rows that changed, but costs more reads than
a plain row update to find them, and its inserts cost about what row-by-row
SQL costs (no less in reads). The MongoDB API's read-modify-write makes both targets pay for the
whole document, and on a view it locks every child row. Etags make a rename
visible to every client that holds a nesting document, without rewriting any
of them. A materialized view keeps a copy in sync for you, at about the price
of keeping it in sync yourself.

Expected assertions:

```
ASSERT:wr-insert-same-content:PASS
ASSERT:wr-k3-change-visible:PASS
ASSERT:wr-s4d-rename-visible:PASS
ASSERT:wr-s4d-etag-controls:PASS
ASSERT:wr-mv-reflects-commit:PASS
ASSERT:wr-mv-refresh-fast:PASS
ASSERT:wr-plans-captured:PASS
ASSERT:wr-us-measured:PASS
ASSERT:wr-us-purge-effective:PASS
ASSERT:wr-teardown-clean:PASS
ASSERT:wr-api-one-doc-per-call:PASS
ASSERT:wr-api-change-visible:PASS
ASSERT:wr-api-statements-found:PASS
ASSERT:wr-api-teardown-clean:PASS
```

- `insert-same-content`: for every k and run, the order read back as the
  collection document, the duality-view document and the table rows (from
  both plain SQL paths) has the same customer, status, total, line count and
  lines (number, sku, qty).
- `k3-change-visible`: each knob-3 path ran 121 times (a warm-up, 20 counted
  runs and 100 CPU runs), recorded 20 counted samples, and its last run
  changed one row or document; the last value shows in the collection, the
  view and the lines table; the line next to it is unchanged; both documents
  still have 1,000 lines; the view update landed in the line row; the
  positional path addressed line 1500; and both `FOR UPDATE` arms recorded 20
  counted samples (of 121 runs each).
- `s4d-rename-visible`: the rename changed one customer document, all 5 order
  documents show the new name, and the etag results were recorded.
- `s4d-etag-controls`: a fresh document is accepted and a document changed
  since it was read is refused with the etag error.
- `mv-reflects-commit`: the MV started at SILVER, every one of the 121 tier
  changes showed on all 100 of customer 1's MV rows right after its `COMMIT`,
  and after the last (GOLD) the MV matches the tables; each arm changed the
  expected number of rows.
- `mv-refresh-fast`: when FAST ON COMMIT was accepted, the dictionary's last
  refresh type is FAST.
- `plans-captured`: all 19 measured statements have an executed plan with
  buffers, none scanned a whole table, and all four `v$sql` windows found
  statements.
- `api-one-doc-per-call`: every `updateOne` matched and modified one document.
- `api-change-visible`: the last value shows through the API and in SQL for
  both targets, and the other 999 lines are unchanged.
- `api-statements-found`: the `v$sql` window found exactly the statements the
  API runs: 2 for the collection, 5 for the view.

Metrics (all `wr-*`): `wr-ins-<path>-k<k>-...`, `wr-k3-<path>-...`,
`wr-fu-<target>-...` and `wr-mv-upd-<arm>-...` with `-reads-median`,
`-reads-max`, `-redo-median`, `-redo-max`, `-cpu-cs-median`, `-cpu-cs-max` and
`-elapsed-cs-median`; `wr-fu-<target>-undo-records`; `wr-mv-read-<arm>-...`
from the meter's `measure_repeat`; `wr-k3-doc-*` (text, OSON and in-row
bytes); `wr-s4d-*`; `wr-mv-fast-on-commit`, `wr-mv-refresh-method`,
`wr-mv-last-refresh-type`, `wr-mv-staleness`;
`wr-vs-<window>-<statement class>-execs-per-call`, `-rows-per-call` and
`-gets-per-call` for the recursive statements (over the window's 21 calls),
and `-us-per-call` and `-ela-us-per-call` (over the 20 calls after the
warm-up); `wr-<write>-us`, `-ela-us` and `-gets` (`v$sql`, per counted run)
for every write in tables 1 to 5, and `wr-mv-upd-mv-total-us`; and from `71`,
`wr-api-<target>-statements`, `wr-api-<target>-<statement class>-execs-per-call`
and `-gets-per-call`, `-vsql-gets-per-call`, `-vsql-cpu-us-per-call`,
`-same-session`, `-session-reads-per-call`, `-session-redo-per-call` and
`-session-cpu-cs-per-call`. The `v$sql` sum for the duality view counts the
view update's recursive line update twice (once inside the view update's own
gets), so the session figure is the one to quote. The undo-record count needs
one more grant, in `docker/init/01-lab-user.sql`: `SELECT` on `V_$TRANSACTION`
(the undo records of the open transaction). On a stack built before that grant
was added, apply it as shown under "Grants on a stack that is already running"
in How to run.

Cursor purges are made visible: `wr-purge-failures` counts the purges in `70`
that raised an error (0 when none did; it does not look for cursors left
behind), and `wr-api-<target>-purge-left` counts the target's cursors still in
`v$sql` after the purge in `71` (0 when it worked). Neither is an assertion:
the counts are taken as growth over a window, so a cursor that survives a
purge does not change them. The marked write cursors are purged once before
the CPU windows, and `wr-us-purge-effective` checks that none is left.

## Teardown: `scripts/99-teardown.sql`

Empties and drops the meter's session table `m08_metrics`, drops the
`m08_meter` package, and then checks that nothing from this module is left in
the schema. The check lists every name the module uses, matched without regard
to case: the prefixes `M08_`, `M08A_`, `M08B_`, `M08B3_`, `M08C1_`, `M08C2_`, `M08D_` (with the materialized view log tables `MLOG$_M08D_*` and `RUPD$_M08D_*`), `M08S2_`,
`M08S4_` and `M08S5_` (which covers the `m08s5_single` collection, and `M08B3_` the
`m08b3_orders` and `m08b3_runs` collections), and the S3 names `sales_orders`,
`SALES_ORDERS_T`, `SALES_ORDER_LINES`, `SALES_ORDERS_V0` and `probe_runs`.

Expected assertions:

```
ASSERT:s08-module-clean:PASS
```
