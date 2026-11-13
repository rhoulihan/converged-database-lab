# Module 08: What Goes Around Comes Around, and Data Independence

Runnable proofs for anchor article 8. Every script runs against the live lab
container and emits machine-checkable rows:

- `ASSERT:<name>:PASS|FAIL` is a check. The validator fails if any check fails.
- `METRIC:<name>:<value>` is a measurement. The validator stores it in
  `validator/results.json` under `"metrics"`, and the article takes its numbers
  from there. Checks look at direction and trend, never at exact numbers.

---

## What this module is for

Article 08 makes one argument: Codd's data independence, the rule that an
application should not break when the storage under it changes, can be restored
for documents. A JSON Relational Duality View puts a declarative view between
the document the app reads and writes and the tables that store it, so the
storage can change while the app stays the same.

The article is also a reply to Stonebraker and Pavlo, "What Goes Around Comes
Around... And Around...", SIGMOD Record 53(2), 2024. They make several claims
about document and key-value databases. Each scenario below answers one of
those claims with something you can run, including the cases where documents
lose. All of it runs on Oracle AI Database 26ai Free in the lab container.

## Scenario index

Quotes are from Stonebraker and Pavlo 2024, section 2.

| Scenario | Script(s) | The claim it answers | What it proves |
|---|---|---|---|
| S3 | `01` to `08` | "there is no data independence." | The same MongoDB API code reads and writes the same results while the storage under the collection moves three times: from a collection to a table behind a duality view, then to promoted columns, then to lines in their own table. Array order after the last move is not guaranteed; see the S3 section. |
| S1 | `10-s1-read-by-key.sql` | "prejoins are not necessarily faster than joins", and the "lower-level, record-at-a-time interface" | For reading one order by key, the document does no more logical reads than the best indexed join, in both a clustered and an interleaved layout. The join's cost grows with the number of lines. The duality view is a join and costs at least as much as the document. |
| S1b | `20-s1b-child-centric.sql` | "prejoins are not necessarily faster than joins" (the case where it holds) | For a query on the child side ("line items with sku X"), the decomposed tables win. The script computes how many item queries per 1,000 order reads it takes before the decomposed form does less total work, when such a crossover exists. |
| S2 | `30-s2-write-amplification.sql` | "if the join is not one-to-many, then there will be duplicated data" | Duplication is real, and its cost depends on how often the copied field changes. A tier change rewrites every embedded copy; the embedded read skips one index probe. The script computes the update rate where the two balance. |
| S4 | `40-s4-two-projections.sql` | the duplicated-data claim and "there is no data independence", together | One canonical form (three normalized tables) projected as two different documents. The customer name is stored once, a change shows up in both documents at once, and only the customer-centric view may change it. |
| S5 | `50-s5-single-collection.js` | "developers must implement joins or multi-get operations in their application" (about key-value stores) | With a partition key and a sort key, one find request returns an order header and all of its lines through an index range scan; a sort step in the database orders them. No app-side join, no multi-get. |
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
(all modules) takes about a minute, much of it the API restart in `02b`.

Numbers for the article come only from `validator/results.json`, under
`"metrics"`.

## The commit exception

The lab contract is that scripts leave the shared domain unchanged: the
validator rolls back after each SQL script. This module bends that rule, and
cleans up after itself.

- **The S3 stage scripts commit on purpose.** `02`, `04` and `06` each move the
  storage one step and `COMMIT`, because the next stage has to see the change.
  The rollback after each script would otherwise undo the move.
- **The S1, S1b and S2 scripts commit their test data.** They build their own
  `M08`-prefixed tables (DDL commits anyway) and commit the seeded rows so the
  measured statements read committed data.
- **The cutover script recycles the API tier.** `02b-cutover-recycle-api.sh`
  restarts the lab container so the MongoDB API re-reads the collection
  details. The validator opens a new SQL connection after any `.sh` script.

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
    The helper refuses them (`ORA-20802`). For a document, select
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

Expected assertions:

```
ASSERT:m08-meter-ready:PASS
ASSERT:m08-meter-cpu-ready:PASS
ASSERT:m08-meter-repeat-ready:PASS
ASSERT:m08-meter-lob-guard:PASS
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

Expected assertions:

```
ASSERT:s2-embedded-touches-N:PASS
ASSERT:s2-normalized-touches-1:PASS
ASSERT:s2-embedded-redo-gt-normalized:PASS
ASSERT:s2-embedded-read-cheaper:PASS
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

### S4: one canonical form, two documents (`scripts/40-s4-two-projections.sql`)

Stonebraker and Pavlo make two claims about document databases (section 2.3,
p.23): "if the join is not one-to-many, then there will be duplicated data", and
"there is no data independence". S4 answers both with one setup. It is a
correctness check, not a measurement.

The canonical form is three normalized tables: customers, orders, and order
lines. Each customer's name is stored once, in the customer row. Two duality
views project that one canonical form as two different documents:

| View | Document | Can it change the customer name? |
|---|---|---|
| `m08s4_cust_dv` | a customer with its `orders[]`, each with its `lines[]` | yes |
| `m08s4_ord_dv` | an order with its `lines[]` and a nested `customer {custId, name}` | no, the nested customer is read-only here |

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
  storage layout on the other. Adding the second shape took one view definition,
  not a data migration.
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
- `s4-order-view-customer-readonly`: the dictionary marks the customer table
  read-only in the order-centric view, and an attempt to change the name through
  it is refused.

Metrics:

- `s4-docs-updated`;
- `s4-order-docs-showing-new-name`;
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

## Teardown: `scripts/99-teardown.sql`

Empties and drops the meter's session table `m08_metrics`, drops the
`m08_meter` package, and then checks that nothing from this module is left in
the schema. The check lists every name the module uses, matched without regard
to case: the prefixes `M08_`, `M08B_`, `M08S2_`, `M08S4_` and `M08S5_` (which
covers the `m08s5_single` collection), and the S3 names `sales_orders`,
`SALES_ORDERS_T`, `SALES_ORDER_LINES`, `SALES_ORDERS_V0` and `probe_runs`.

Expected assertions:

```
ASSERT:s08-module-clean:PASS
```
