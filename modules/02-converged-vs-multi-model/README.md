# Module 02 — Converged vs Multi-Model

Three runnable proofs for leaf article 2's core claims ("multi-model is a
storage claim; converged is a guarantees claim"). Every script executes
against the live lab container and emits machine-checkable assertions
(`ASSERT:<name>:PASS|FAIL`). No screenshots, no trust-me — run them yourself.

---

## Proof 1: `scripts/01-survey-challenge.sql`

**Article claim: the academic literature's canonical multi-model query runs as
one standard SQL statement.** Lu & Holubová's ACM Computing Surveys survey of
multi-model databases (52(3) Art. 55, 2019) opens with a running example
(their Fig. 1): relational customers (Mary, credit 5000; John, 3000; William,
2000), a "knows" social graph, and orders as JSON documents — challenge query:
*"Return all product_no which are ordered by a friend of a customer whose
credit_limit>3000"*, published result `['2724f','3424g']`. The survey solves
it in ArangoDB AQL and OrientDB SQL, each a proprietary language on its own
engine. This script recreates the dataset as module-local tables plus a SQL
property graph, then answers the query in **one statement**: `GRAPH_TABLE`
(SQL/PGQ, ISO/IEC 9075-16) walks the knows-graph, `JSON_TABLE` (SQL/JSON,
SQL:2016) unnests the order lines, a relational predicate filters on
`credit_limit` — and an assertion checks the result set equals the survey's
published answer **exactly**. `EXPLAIN PLAN` then shows graph, document, and
relational access costed as ordinary row sources in a single plan tree.

**Dataset note:** the survey publishes the customers, the query, and the
result, but not the complete knows-edge topology or full order documents. The
script constructs the minimal dataset consistent with the survey's published
inputs and published result (Mary knows John and William; John's order
contains product `2724f`, William's contains `3424g`); `Order_no`,
`Product_Name`, and `Price` values are constructed placeholders in the
survey's document shape.

**DDL exception:** this script intentionally performs DDL, and DDL
autocommits — the harness rollback cannot undo it. Cleanup is therefore
explicit and asserted: every module-local object (`smm_` prefix) is dropped
before the script ends, an idempotence guard at the top clears leftovers from
interrupted runs, and the transactional `EXPLAIN PLAN` rows are deleted before
the autocommitting drops so `plan_table` is left unchanged too.

Expected assertions:

```
ASSERT:survey-result-exact:PASS
ASSERT:plan-captured:PASS
ASSERT:plan-spans-graph:PASS
ASSERT:plan-spans-relational:PASS
ASSERT:plan-spans-document:PASS
ASSERT:plan-evaluates-json:PASS
ASSERT:one-plan-tree:PASS
ASSERT:smm-tables-dropped:PASS
ASSERT:smm-graph-dropped:PASS
ASSERT:plan-table-clean:PASS
```

## Proof 2: `scripts/02-one-enforcement-domain.js`

**Article claim: one enforcement domain — the same constraint guards every
API.** The shared domain declares `CHECK (qty > 0)` on `order_items`. The
script pushes `qty: -1` through the MongoDB document API (an `updateOne` on
the `order_dv` duality view) and gets a `MongoServerError` carrying
`ORA-02290` (check-constraint violated); it then submits the same violation as
a SQL `UPDATE` through the `$sql` aggregation stage on the same connection and
gets the same `ORA-02290`. Document and rows verified unchanged after both
attempts. The constraint lives in the engine, beneath every surface — there is
no per-API validation layer to drift.

**Error-text note:** the exact `MongoServerError` message format (ORA-42692
wrapping ORA-02290 on the document path; bare ORA-02290 via `$sql`) is
observed behavior on Oracle AI Database 26ai Free as of June 2026, not a
documented contract. Assertions match only the documented element — the
ORA-02290 code.

Expected assertions:

```
ASSERT:doc-read:PASS
ASSERT:mongo-api-rejected:PASS
ASSERT:doc-unchanged:PASS
ASSERT:sql-update-rejected:PASS
ASSERT:final-state-unchanged:PASS
```

## Proof 3: `scripts/03-read-after-write-search.sql`

**Article claim: transactional read-after-write text search.** The script
inserts a support ticket containing a unique marker token, COMMITs, and
immediately finds it with `CONTAINS` — then deletes it, COMMITs, and
immediately does not. Search visibility arrives with the commit, in the same
engine, with no separate search process, change stream, or refresh interval.
The lab's `ticket_text_idx` is created with `PARAMETERS ('SYNC (ON COMMIT)')`
(`docker/init/05-text-vector.sql`), so the text index syncs inside the
committing transaction.

**Commit exception:** this script intentionally COMMITs (read-after-write can
only be shown across a real commit boundary), so the harness rollback does not
apply; explicit, asserted cleanup restores the domain. It is reseed-safe —
`ticket_id` is identity-generated and the probe row is addressed only by its
unique subject/marker, never a fixed id.

Expected assertions:

```
ASSERT:contains-finds-committed-write:PASS
ASSERT:contains-after-cleanup:PASS
ASSERT:probe-rows-gone:PASS
```

## Cross-reference: the one-optimizer proof lives in module 01

The companion article also leans on **one cost-based plan spanning graph,
document, vector, and relational** access. That evidence is module 01's
[`05-one-plan.sql`](../01-what-is-a-converged-database/scripts/05-one-plan.sql)
(`EXPLAIN PLAN` over the shared domain: `GRAPH_TABLE` + JSON predicate +
`VECTOR_DISTANCE` + relational joins in one plan tree). Leaf article 2 quotes
that proof; this module deliberately does not duplicate it — proof 1's plan
assertions here cover the survey statement specifically.

---

## Run It Yourself

```bash
docker compose up -d --build oracle
pip install -r validator/requirements.txt
python validator/run.py
```

The validator runs every script (modules 01 and 02) and exits 0 only if all
assertions pass.

**These proofs leave the seeded domain unchanged.** Two scripts in this module
are documented exceptions to the rollback contract — proof 1 performs DDL
(autocommits) and proof 3 COMMITs — so both clean up explicitly and assert the
cleanup, which keeps the validator repeatable: run it any number of times with
identical results.
