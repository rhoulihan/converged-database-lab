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

Expected assertions:

```
ASSERT:s1b-outofrow-penalty-k1000:PASS
ASSERT:s1b-itemdv-close-to-childtable-k<k>:PASS  (3)
ASSERT:s1b-gap-grows-with-k:PASS
ASSERT:s1b-penalty-ratio-grows:PASS
ASSERT:s1b-crossover-k<k>-positive:PASS          (each k where documents cost more per item query)
ASSERT:s1b-same-content:PASS
ASSERT:s1b-plans-indexed:PASS
ASSERT:s1b-teardown-clean:PASS
```

Metrics: `s1b-{childtable|childtable-plain|childtable-covered|orderdocs|orderdocs-jsontable|orderdocs-serialized|itemdv|doc|join}-k{10|100|1000}-reads`,
`s1b-doc-bytes-k{k}`, `s1b-crossover-item-queries-per-1000-order-reads-k{k}` (or
`s1b-no-crossover-k{k}`), `s1b-meter-overhead-reads`.

### S2: duplicated data and what it costs to keep it in sync (`scripts/30-s2-write-amplification.sql`)

Stonebraker and Pavlo point out that if the join is not one-to-many, "there will
be duplicated data". That is true. S2 measures what the duplication costs, and
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
- **A field that never changes costs nothing on the write side**, because nothing
  ever rewrites it. That is the Extended Reference pattern: copy the fields that
  never or rarely change (a name), and keep the volatile ones (a tier) behind a
  reference.
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
above it, normalized storage does. With N = 100 the crossover is about one
change per 1,000 reads, so a field that changes this often should not be
embedded. The crossover is approximate: a one-block change in any term moves it,
which is why it is recorded to one decimal. It is computed on logical reads
only. Redo is a separate cost axis, and it makes the write side worse still for
embedding. If no crossover exists, `s2-no-crossover` is 1.

Expected assertions:

```
ASSERT:s2-embedded-touches-N:PASS
ASSERT:s2-normalized-touches-1:PASS
ASSERT:s2-embedded-redo-gt-normalized:PASS
ASSERT:s2-embedded-read-cheaper:PASS
ASSERT:s2-immutable-total-cheaper:PASS
ASSERT:s2-crossover-positive:PASS
ASSERT:s2-same-content:PASS
ASSERT:s2-plans-indexed:PASS
ASSERT:s2-teardown-clean:PASS
```

`s2-same-content` checks two things, before and after the tier change:

- both models return the same order and customer fields;
- every embedded copy carries the new tier.

Metrics:

- `s2-{embedded-update-docs|normalized-update-rows}`;
- `s2-{embedded|normalized}-update-{reads|redo}`;
- `s2-embedded-read-reads`, `s2-normalized-read-{pk|covered}-reads`, and
  `s2-normalized-read-reads` (the cheaper of the two);
- `s2-crossover-updates-per-1000-reads` (or `s2-no-crossover`);
- `s2-idx-{cust-pk|cust-cov|ord-pk|ord-cov|doc-pk|doc-cust}-blevel`;
- `s2-meter-overhead-{reads|redo}`.
