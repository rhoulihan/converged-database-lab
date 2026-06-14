# Module 05 — JSON, Graph, Vector, and Relational in One Database

The companion proofs for leaf article 5, _"JSON, Graph, Vector, and Relational
Data in One Database."_ This is the developer-facing, build-a-feature piece: less
"why convergence," more "here's the feature, here's the query." Every script runs
against the live lab container and emits machine-checkable assertions
(`ASSERT:<name>:PASS|FAIL`). No screenshots, no trust-me — run them yourself.

This module debuts the two data models no prior module exercised — **spatial**
and **text** — and folds them into the four the anchor's module 01 already
proved (graph, document, vector, relational) to reach a **single statement that
spans six models**, planned by one optimizer in one transaction.

---

## Image requirement — the full (non-slim) container

This module needs **Oracle Spatial** (`MDSYS`, for `SDO_GEOMETRY` /
`SDO_WITHIN_DISTANCE` / `SDO_NN` / the R-tree spatial index) **and Oracle Text**
(`CTXSYS`, for `CONTAINS`). The `gvenzl/oracle-free` **slim** and
**slim-faststart** image variants _uninstall both_. `docker/Dockerfile.oracle`
therefore builds on the **full faststart image** (`gvenzl/oracle-free:23.26.0-faststart`).
On a slim image, `docker/init/11-spatial-index.sql` and the module 05 spatial
proofs silently fail — use the full image.

## Spatial setup (branch infra) — `docker/init/11-spatial-index.sql`

The shared domain has stored `stores.location` as `SDO_GEOMETRY` (SRID 4326,
WGS84 lon/lat) since the anchor — five Texas store points plus a null-location
`Online` store. Two things are required before the SDO operators work, and this
init script adds both, idempotently, on first boot (after `01`–`08`):

1. a row in `USER_SDO_GEOM_METADATA` describing the column's dimensions + SRID
   (lon −180..180, lat −90..90, tolerance 0.5 m, SRID 4326); then
2. an R-tree spatial index — `CREATE INDEX stores_geom_idx ON stores(location)
   INDEXTYPE IS MDSYS.SPATIAL_INDEX_V2` (geodetic SRID 4326 is forced to R-tree).

The `Online` store's `NULL` location is fine — the R-tree index skips null
geometries.

**Single-geometry-probe constraint (stated plainly):** `SDO_WITHIN_DISTANCE`
must sit in the `WHERE` clause and is a single-geometry probe — a fixed reference
point (here, a downtown-Austin service center), **not** a table-to-table spatial
join. The feature framing (orders near one service center) satisfies this
naturally. Also note: the spatial operator cannot be used inside a correlated
scalar subquery (it raises `ORA-00600`); express it as a join predicate in the
main query, which is how all three scripts below use it.

---

## Proof 1: `scripts/01-six-model-feature.sql` — the headline

**Article claim (§3): one real feature, one SQL statement, six models, one
plan.** The feature is _proactive support outreach_: starting from a flagged
account, find the customers worth contacting now. One statement carries all six
models:

| Model | In the query |
|---|---|
| **Graph** | `GRAPH_TABLE` shared-device ring of flagged customer 10 (two `customer_devices` edges) |
| **Relational** | join `CUSTOMERS`/`ORDERS`/`STORES`; keep premium/vip |
| **Spatial** | `SDO_WITHIN_DISTANCE` — order placed at a store ≤ 50 km from the service center |
| **Vector** | `VECTOR_DISTANCE` on `body_vec`, probe embedded in-DB by `VECTOR_EMBEDDING(MINILM_L12 …)` |
| **Text** | `CONTAINS(body, 'login OR authentication')` via the Oracle Text index |
| **Document** | project the match as `customer_profile_dv` JSON (`JSON_VALUE` / `JSON_SERIALIZE`) |

**Tuned constants (verified live to return ≥ 1 row on the seed):** flagged
customer = `10`; radius = `50 km` from `(-97.7431, 30.2672)`; defect probe =
`'user cannot log in after password reset'`; keyword = `'login OR authentication'`.
The match is **customer 15** — premium, in customer 10's shared-device ring,
ticket 209 ("Cannot sign in after password reset"), orders at Downtown Austin
and Domain North inside the 50 km radius.

`EXPLAIN PLAN` then proves the plan is **one tree** in which each model is an
ordinary row source: the spatial `DOMAIN INDEX (STORES_GEOM_IDX)`, the graph
edge access over `CUSTOMER_DEVICES` (via its PK index — system-generated name,
resolved through `user_indexes`), the relational `CUSTOMERS`/`ORDERS` tables,
`SUPPORT_TICKETS` carrying both the `CONTAINS` filter predicate and the
`VECTOR_DISTANCE` `SORT ORDER BY STOPKEY`. One cost-based optimizer. No
federation seam. (The anchor's module 01 one-plan showed four models; this shows
six.)

**Optimizer note (honest, mirrors module 03).** At 300 tickets / 6 stores the
CBO drives the spatial domain index for the geo probe but applies `CONTAINS` as a
functional filter and `VECTOR_DISTANCE` as a top-k sort over the small surviving
candidate set, rather than navigating the text / IVF domain indexes — a full scan
of a handful of survivors is cheaper. That is the optimizer costing every model
in one plan and picking the cheap path; the indexes are built and `VALID` and
would drive the plan at scale. This module proves **composition and one-plan-tree
correctness across six models**, not index throughput.

Expected assertions:

```
ASSERT:six-model-returns:PASS
ASSERT:plan-captured:PASS
ASSERT:plan-spans-graph:PASS
ASSERT:plan-spans-relational:PASS
ASSERT:plan-spans-spatial:PASS
ASSERT:plan-spans-text-vector-table:PASS
ASSERT:plan-contains-text-predicate:PASS
ASSERT:plan-vector-drives-sort:PASS
ASSERT:plan-contains-spatial-predicate:PASS
ASSERT:one-plan-tree:PASS
```

## Proof 2: `scripts/02-model-once-project-many.sql` (+ `02-duality-etag-conflict.js`)

**Article claim (§5): model the domain once, project the access many ways.**
`customer_profile_dv` and `order_dv` are two different JSON hierarchies over the
**same** `customers`/`orders` rows — one canonical truth, nothing stored twice;
the documents are generated on read and disassembled on write.

The SQL script proves, for one order: (a) the two projections **agree on the
shared facts** — same customer email, same order total, read through both views;
and (b) **write-through** — change `customers.segment` in SQL and the change is
immediately visible through `customer_profile_dv`, no sync step (the document is
the rows). The harness rolls back the mutation.

The `.js` companion proves **ETag optimistic concurrency** through the MongoDB
API, where each operation is its own committed statement so the conflict is
deterministic: capture a document (and its `_metadata.etag`) with `findOne`, have
another writer bump the base order row via a `$sql` stage, then `replaceOne` with
the now-stale document → rejected with **`ORA-42699`** (HTTP 412 over REST).
Optimistic concurrency without app-managed version columns. The script restores
the base row before exiting.

Expected assertions:

```
ASSERT:order-dv-shape:PASS
ASSERT:projections-agree-email:PASS
ASSERT:projections-agree-total:PASS
ASSERT:write-through-visible:PASS
ASSERT:etag-doc-captured:PASS         (02-duality-etag-conflict.js)
ASSERT:base-row-bumped:PASS           (02-duality-etag-conflict.js)
ASSERT:stale-write-rejected:PASS      (02-duality-etag-conflict.js)
ASSERT:etag-restored:PASS             (02-duality-etag-conflict.js)
```

## Proof 3: `scripts/03-spatial-point-radius.sql` — spatial standalone

**Article claim (§4): spatial is the model you forgot you had.** Spatial is a
column type and an index, and a geo predicate is just another `WHERE` clause the
same optimizer plans with everything else. The script confirms the metadata +
R-tree index are live, then runs the two canonical spatial queries and joins the
result back to relational:

- **Point-radius** — `SDO_WITHIN_DISTANCE` from the fixed downtown-Austin probe:
  exactly **2 stores** within 50 km (`Domain North` ~15 km, `Downtown Austin`
  ~0 km); **5 stores** within 400 km (all but null-location `Online`).
- **K-nearest** — `SDO_NN` with `/*+ INDEX(s stores_geom_idx) */` and
  `SDO_NN_DISTANCE(1)` ordering: nearest-first is `Downtown Austin` (0 km) then
  `Domain North` (~15 km) then `Pearl` (~116 km).
- **Spatial joined to relational** — orders placed at a store within 50 km of the
  probe (single-geometry probe, joined to `ORDERS` by `store_id`).

Expected assertions:

```
ASSERT:spatial-metadata-present:PASS
ASSERT:spatial-index-valid:PASS
ASSERT:point-radius-austin-set:PASS
ASSERT:point-radius-count:PASS
ASSERT:point-radius-wide-count:PASS
ASSERT:knn-nearest-two:PASS
ASSERT:knn-ordered-by-distance:PASS
ASSERT:spatial-join-orders:PASS
```

This module emits **26 assertions across four scripts** (10 + 4 SQL + 4 JS + 8).

---

## Run It Yourself

```bash
docker compose up -d --build oracle   # full faststart image; wait for healthy
pip install -r validator/requirements.txt
python validator/run.py
```

The validator runs every script and exits 0 only if all assertions pass.

**These proofs leave the seeded domain unchanged.** The SQL scripts run inside a
transaction the harness rolls back; the JavaScript script restores everything it
touches, so the validator can run any number of times with identical results.

Precursor: the anchor's **module 01** `05-one-plan.sql` proves the four-model
one-plan (graph + document + vector + relational); this module's
`01-six-model-feature.sql` extends it to six by adding spatial and text.
