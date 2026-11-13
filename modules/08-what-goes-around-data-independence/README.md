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
  once, so each line lands in its own block: one block per line. This is a
  constructed upper bound for a heap table with a single-column FK index.

The document and duality-view readers serialize the document, so its bytes are
really read; a client fetch costs the same.

Expected assertions:

```
ASSERT:s1-same-content:PASS
ASSERT:s1-interleaved-spread:PASS
ASSERT:s1-doc-body-read:PASS
ASSERT:s1-doc-le-join-<layout>-k<k>:PASS     (8)
ASSERT:s1-dv-ge-doc-<layout>-k<k>:PASS       (8)
ASSERT:s1-join-grows-<layout>:PASS           (2)
ASSERT:s1-n1-execs-k<k>:PASS                 (4)
ASSERT:s1-plans-indexed:PASS
ASSERT:s1-teardown-clean:PASS
```

Metrics: `s1-{doc|join|dv|n1}-{clustered|interleaved}-k{1|10|100|1000}-reads`,
`s1-n1-k{k}-execs`, `s1-meter-overhead-reads`, `s1-meter-overhead-execs`.

### S1b: find the line items with one sku (`scripts/20-s1b-child-centric.sql`)

S1 asked for one order. S1b asks the opposite kind of question: "which line
items have sku X1?" The sku sits in exactly 20 lines spread over 20 orders.
Orders have 10, 100 or 1,000 lines, each size on its own freshly built data, in
the clustered layout. Cost is counted as in S1: logical reads on the second run,
with the meter's overhead removed.

| Reader | What it does |
|---|---|
| childtable | the line rows, through an index on `sku`. No join. |
| orderdocs-jsontable | order documents through a multivalue index on `items[*].sku`, then `JSON_TABLE` pulls out the matching item |
| orderdocs-serialized | the matching whole orders through the same index, fetched serialized, as a client would before filtering |
| itemdv | a duality view with one document per line, rooted on the line table, filtered on `sku` |

The documents get their best plan, as the join did in S1: `s1b-orderdocs-k<k>-reads`
is the cheaper of the two document readers.

**What the numbers show.** A document stored inside its row costs the same one
block as a line row. So while orders fit in their rows (10 and 100 lines here),
reading whole orders to find one item costs nothing extra. Once an order
outgrows its row and is stored out of line (1,000 lines, about 50 KB), every
match reads the whole order, and the documents do several times the work of
the child table.

**Knob 1: how often each query runs.** The script also measures S1's order read
by key on the same data (`doc` and `join`). For 1,000 order reads plus q item
queries:

```
documents : 1000*doc  + q*orderdocs
normalized: 1000*join + q*childtable
crossover : q = 1000 * (join - doc) / (orderdocs - childtable)
```

Below the crossover, documents do less total work; above it, normalized tables
do. With in-row documents there is no crossover at all
(`s1b-no-crossover-k10` and `-k100` are 1). Which way to go depends on how
often the item query runs. In order processing, item queries are usually
low-frequency reports and KPIs.

Expected assertions:

```
ASSERT:s1b-inrow-no-penalty-k<k>:PASS            (k = 10, 100)
ASSERT:s1b-outofrow-penalty-k1000:PASS
ASSERT:s1b-itemdv-close-to-childtable-k<k>:PASS  (3)
ASSERT:s1b-gap-grows-with-k:PASS
ASSERT:s1b-crossover-k1000-positive:PASS
ASSERT:s1b-same-content:PASS
ASSERT:s1b-plans-indexed:PASS
ASSERT:s1b-teardown-clean:PASS
```

Metrics: `s1b-{childtable|orderdocs|orderdocs-jsontable|orderdocs-serialized|itemdv|doc|join}-k{10|100|1000}-reads`,
`s1b-crossover-item-queries-per-1000-order-reads-k1000`, `s1b-no-crossover-k{10|100}`,
`s1b-meter-overhead-reads`.
