# Module 01 — What Is a Converged Database?

Five runnable proofs for the anchor article's core claims. Every script executes
against the live lab container and emits machine-checkable assertions
(`ASSERT:<name>:PASS|FAIL`). No screenshots, no trust-me — run them yourself.

---

## Proof 1: `scripts/01-one-transaction-every-model.sql`

**Article claim: one transaction boundary across models.** A single ACID
transaction inserts a relational order and line item, writes a JSON document to
the `events` collection table, and updates a vector embedding on a support
ticket — then rolls the whole thing back. The assertions verify all four writes
are visible *inside* the uncommitted transaction and all four are *atomically
gone* after `ROLLBACK`. In a polyglot stack that same unit of work spans three
engines and has no transaction boundary at all.

Expected assertions:

```
ASSERT:txn-relational-visible:PASS
ASSERT:txn-document-visible:PASS
ASSERT:txn-vector-visible:PASS
ASSERT:rollback-relational:PASS
ASSERT:rollback-document:PASS
ASSERT:rollback-vector:PASS
```

## Proof 2: `scripts/02-duality-roundtrip.js`

**Article claim: a document and its rows are the same data.** Through the
MongoDB API, the script reads customer 42 from the `customer_profile_dv` JSON
Duality View, updates `segment` with a plain `updateOne`/`$set`, then reads the
**relational table** through a `$sql` aggregation stage in the same session —
and the document write is already there. No sync job moved it: the document and
the rows are two projections of one stored truth. The script restores the
original value before exiting.

Expected assertions:

```
ASSERT:dv-doc-exists:PASS
ASSERT:dv-doc-updated:PASS
ASSERT:dv-sql-sees-doc-write:PASS
ASSERT:dv-restored:PASS
```

## Proof 3: `scripts/03-one-optimizer.sql`

**Article claim: one optimizer plans across models.** A single SQL statement
walks the referral property graph from customer 10 (`GRAPH_TABLE` ... `MATCH`),
joins the reachable customers to their relational rows and support tickets,
filters on status, and ranks by `VECTOR_DISTANCE` similarity — graph, relational,
and vector planned together by one cost-based optimizer. A second query proves
the seeded 4-hop referral cycle (10→11→12→13→10) with a fixed-quantifier
`MATCH` back to the starting vertex.

Expected assertions:

```
ASSERT:converged-query-returns:PASS
ASSERT:graph-cycle-found:PASS
```

## Proof 4: `scripts/04-read-your-writes.js`

**Article claim: read-your-writes across APIs.** The script inserts a uniquely
markered document through the MongoDB API and immediately counts it through SQL
(`$sql` stage) — same call stack, same second, count = 1. There is no CDC
pipeline, no search-index refresh, no replication lag window in which another
API sees stale data: both APIs read the same storage. The probe document is
deleted before exit.

Expected assertions:

```
ASSERT:read-your-writes-sql:PASS
ASSERT:probe-cleaned:PASS
```

## Proof 5: `scripts/05-one-plan.sql`

**Article claim: one cost-based optimizer produces a single plan spanning
graph, document, vector, and relational.** `EXPLAIN PLAN` captures the plan for
one statement that walks the referral graph (`GRAPH_TABLE`), joins relational
`CUSTOMERS`, anti-joins a document-model predicate on the `EVENTS` JSON
collection (`NOT EXISTS` on `e.data.type.string()`), and orders by
`VECTOR_DISTANCE` over `SUPPORT_TICKETS`. The assertions then interrogate
`PLAN_TABLE`: every model appears as an **ordinary row source in one plan
tree**. That is the proof — Oracle translates `GRAPH_TABLE` internally to
equivalent SQL, so the graph shows up as a plain `VIEW` (`CUSTOMER_GRAPH`)
reading the `REFERRALS` edge table through its primary-key index, costed by the
same optimizer that plans the joins, the JSON predicate, and the vector sort.
One cost model. No federation seam. In a polyglot stack there is no such plan,
because no component can see across the wire.

(The `REFERRALS` index name is system-generated, so the graph assertion
resolves it through `user_indexes` rather than hard-coding it. `EXPLAIN PLAN`
rows are transactional, so the harness rollback leaves `PLAN_TABLE` empty.)

Expected assertions:

```
ASSERT:plan-captured:PASS
ASSERT:plan-spans-graph:PASS
ASSERT:plan-spans-relational:PASS
ASSERT:plan-spans-document:PASS
ASSERT:plan-spans-vector:PASS
ASSERT:one-plan-tree:PASS
```

With proof 5 the module emits **20 assertions across five scripts**.

---

## Run It Yourself

```bash
docker compose up -d --build oracle
pip install -r validator/requirements.txt
python validator/run.py
```

The validator runs every script and exits 0 only if all assertions pass.

**These proofs leave the seeded domain unchanged.** The SQL scripts run inside a
transaction the harness rolls back; the JavaScript scripts restore or delete
everything they touch, so the validator can run any number of times with
identical results.
