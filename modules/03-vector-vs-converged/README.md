# Module 03 — Vector Database vs Converged Database

Four runnable proofs for leaf article 3 ("Vector Database vs Converged
Database"). A vector database stores embeddings and finds the nearest ones —
one capability production retrieval needs. This module proves the other four:
**filter + join to operational data, read-after-write freshness,
permission-aware retrieval, and hybrid keyword + semantic search** all run
*beside* similarity in one engine, one transaction, one optimizer, one
governance domain.

Every script executes against the live lab container and emits machine-checkable
assertions (`ASSERT:<name>:PASS|FAIL`). No screenshots, no trust-me.

This is the **deep, native showcase**: the similarity search here runs on **real
384-dimension embeddings** generated *inside the database* by Oracle's prebuilt
augmented `all-MiniLM-L12-v2` ONNX model, indexed by both a native IVF vector
index and a native **Hybrid Vector Index** — not toy vectors. See
[Infrastructure](#infrastructure-real-in-db-embeddings--hybrid-vector-index).

---

## Proof 1: `scripts/01-filtered-joined-ann.sql`

**Article claim (§4): filter + join + similarity, one statement, one plan.** A
single SQL statement finds the support tickets most semantically similar to a
natural-language probe (`unable to log in after reset`, embedded in-database by
the same model that embedded the bodies) — but only for `premium`/`vip`
customers with a recently `shipped` order. `EXPLAIN PLAN` proves `CUSTOMERS`,
`ORDERS`, and `SUPPORT_TICKETS` are all costed in **one plan tree**, with the
`VECTOR_DISTANCE` driving the sort. A dedicated store answers only the
similarity half — the segment filter is flat-metadata-only and the join to
orders is an application-side fetch against a second system.

**Optimizer honesty (scale note).** At 300 tickets the cost-based optimizer
chooses the **pre-filter** strategy — apply the selective relational predicates
first, then compute *exact* COSINE distance over the small surviving set —
because scanning 300 rows is cheaper than navigating IVF centroid partitions.
That is the optimizer doing its job (it costs pre-filter vs post-filter and exact
vs approximate, and picks the cheap plan); the IVF index is built, `VALID`, and
would drive the plan at scale. This module proves **composition and one-plan-tree
correctness, not ANN throughput** — these are correctness/colocation proofs on a
2-core / Free container, never a latency or recall benchmark. The final
assertion confirms the IVF approximate index genuinely exists and is `VALID`.

The captured plan (`DBMS_XPLAN ... BASIC`):

```
---------------------------------------------------
| Id  | Operation             | Name             |
---------------------------------------------------
|   0 | SELECT STATEMENT      |                  |
|   1 |  COUNT STOPKEY        |                  |
|   2 |   VIEW                |                  |
|   3 |    SORT ORDER BY STOPKEY|                |
|   4 |     HASH JOIN         |                  |
|   5 |      HASH JOIN        |                  |
|   6 |       TABLE ACCESS FULL | CUSTOMERS      |
|   7 |       TABLE ACCESS FULL | ORDERS         |
|   8 |      TABLE ACCESS FULL | SUPPORT_TICKETS |
---------------------------------------------------
```

Expected assertions:

```
ASSERT:plan-captured:PASS
ASSERT:plan-spans-customers:PASS
ASSERT:plan-spans-orders:PASS
ASSERT:plan-spans-vector-table:PASS
ASSERT:vector-drives-sort:PASS
ASSERT:one-plan-tree:PASS
ASSERT:ivf-index-valid:PASS
```

## Proof 2: `scripts/02-vector-read-after-write.sql`

**Article claim (§5): a committed embedding change is immediately visible to
ANN.** The script captures ticket #1's distance and rank to a semantic probe,
`UPDATE`s its `body_vec` to an unrelated embedding, `COMMIT`s, and re-runs the
identical query in the same session — the row's rank collapses (it drops out of
the top-k) *immediately*, with no reindex, no sleep, no LSN poll. It then
recomputes the original embedding from the unchanged `body` text and `COMMIT`s
again; the restored distance is identical to the original. Oracle maintains the
vector index inside the committing transaction (MVCC) — there is no replication
pipeline between models to lag. Contrast (vendor-documented, June 2026): Pinecone
is eventually consistent and requires `x-pinecone-request-lsn` polling; MongoDB
Atlas (`mongot`) replicates the index off the oplog asynchronously with no
read-after-write guarantee.

**COMMIT exception + restore.** The validator rolls SQL scripts back to leave the
domain unchanged, but this proof must `COMMIT` to show cross-statement visibility,
and `COMMIT` cannot be rolled back. So the proof is fully self-restoring: it
re-embeds the untouched `body` to recover the exact original vector, and the
helper table `m03_raw_proof` (DDL, autocommits) is dropped at the end. On success
the domain is byte-for-byte pristine (asserted).

Expected assertions:

```
ASSERT:committed-write-visible:PASS
ASSERT:rank-changed:PASS
ASSERT:restored-exact:PASS
ASSERT:teardown-clean:PASS
```

## Proof 3: `scripts/03-permission-aware-retrieval.sql`

**Article claim (§6): same vector query, different users, different rows —
governed in-engine.** A `DBMS_RLS` (Virtual Private Database) policy on
`support_tickets`, keyed to an application context, partitions the tickets
between two tenants (A owns even-numbered customers, B owns odd). The **identical**
`FETCH APPROX` vector query is run as each tenant; the result sets are **disjoint**
and each is provably governed by the policy — unauthorized rows never enter the
other tenant's top-k, query unchanged. This is the cleanest expression of the
series' "one governance domain" guarantee: the same row-level policy that governs
SQL, the document API, and graph traversal also governs vector retrieval.
Contrast: Pinecone's own access-control guide concedes the store does not enforce
permissions and must integrate an external authorizer (SpiceDB) and keep ACLs in
sync. (VPD is available in 26ai Free — Licensing guide Table 1-11, Free = Y —
overturning the stale "VPD is Enterprise-only" claim.)

**Mechanism honesty.** True OS-level multi-user auth is awkward to script as
`LAB_USER`, so the policy predicate keys off an **application context**
(`SYS_CONTEXT`), toggled between two tenant identities via
`DBMS_SESSION.SET_CONTEXT` within one session. The query text is byte-for-byte
identical across both runs; only the governed identity differs — which is the
point.

**DDL exception + teardown.** The context, context-setter procedure,
policy-predicate function, the `DBMS_RLS` policy, and the helper table are all DDL
(autocommit, not reversible by the validator rollback). Cleanup is explicit and
asserted: all are dropped before the script ends, leaving `support_tickets`
unrestricted with 300 rows.

Expected assertions:

```
ASSERT:both-tenants-nonempty:PASS
ASSERT:results-disjoint:PASS
ASSERT:governed-by-policy:PASS
ASSERT:teardown-clean:PASS
```

## Proof 4: `scripts/04-hybrid-search.sql`

**Article claim (§7): one engine fuses keyword + semantic.** The native **Hybrid
Vector Index** (`tickets_hvi`) is a single domain index combining Oracle Text and
a vector index over the ticket body. `DBMS_HYBRID_VECTOR.SEARCH` runs both a
keyword search (`text.contains`) and a semantic search (`vector.search_text`) in
**one call** and returns a single fused, ranked result set — every returned row
carries **both** a `vector_score` and a `text_score`. The proof captures the
fused top-10 and, separately, keyword-only (`CONTAINS`) and vector-only
(`VECTOR_DISTANCE` on `body_vec`) top-10, then asserts the fused set differs from
the keyword-only set (semantic recall surfaces rows lexical ranking misses).
Contrast: pgvector + `pg_search` require hand-rolled reciprocal-rank fusion in
application SQL because BM25 and vector scores are "incommensurable"; Pinecone's
sparse-dense scores are not normalized to the dense range so the app must reweight;
MongoDB's `$rankFusion` is Preview (8.0+). Anthropic's Contextual Retrieval
(Sept 2024) found adding keyword/BM25 to embeddings cut retrieval failures by up
to 67% in their evaluation — hybrid, not raw ANN, is the production stack.

The exact `DBMS_HYBRID_VECTOR.SEARCH` JSON that runs:

```json
{ "hybrid_index_name" : "tickets_hvi",
  "vector" : { "search_text" : "the box was crushed and broken in transit" },
  "text"   : { "contains"    : "damaged" },
  "return" : { "topN" : 10 } }
```

It returns a JSON array of `{ rowid, score, vector_score, text_score,
vector_rank, text_rank, chunk_text, chunk_id }` rows, unnested with `JSON_TABLE`
and joined back to `support_tickets` by `rowid`.

**DDL exception.** The helper table `m03_hybrid_proof` autocommits and is dropped
at the end (asserted); the HVI and all 300 seeded rows are untouched.

Expected assertions:

```
ASSERT:hybrid-returns-topN:PASS
ASSERT:fusion-uses-both-signals:PASS
ASSERT:fusion-differs-from-keyword:PASS
ASSERT:teardown-clean:PASS
```

The module emits **19 assertions across four scripts.**

---

## Infrastructure: real in-DB embeddings + Hybrid Vector Index

This module adds two pieces of branch-specific infrastructure (built once on
first boot, baked deterministically into the image so CI's fresh build is
reproducible):

1. **The ONNX model is baked into the image.** `docker/Dockerfile.oracle`
   downloads Oracle's official prebuilt augmented `all-MiniLM-L12-v2` ONNX model
   (the URL the 26ai docs "ONNX Pipeline Models: Text Embedding" page redirects
   to, in the `OML-ai-models` object-storage bucket; ~122.6 MB zip →
   ~133.3 MB `.onnx`, 384-dim output) to `/opt/oracle/models`. The build fails
   loudly if the URL stops resolving rather than baking a broken image.

2. **`docker/init/08-vector-model.sql`** (runs after `01`–`07`): loads the model
   as `MINILM_L12` via `DBMS_VECTOR.LOAD_ONNX_MODEL`, adds a real
   `body_vec VECTOR(384, FLOAT32)` column to `support_tickets`, embeds all 300
   ticket bodies in-database with `VECTOR_EMBEDDING(MINILM_L12 USING body AS
   data)` (~2.5 s), builds an IVF vector index (`tickets_bodyvec_ivf`,
   `NEIGHBOR PARTITIONS` / COSINE — no Vector Pool, Free-safe), and builds the
   Hybrid Vector Index (`tickets_hvi`, `VECTOR_IDXTYPE IVF MEMORY 256M`).

**Why IVF, not HNSW.** IVF (`NEIGHBOR PARTITIONS`) needs no Vector Pool /
`VECTOR_MEMORY_SIZE`, so it fits the Free container's SGA. HNSW must live in the
SGA Vector Pool; the module defaults to IVF everywhere to stay Free-safe and does
not require HNSW.

**The toy `embedding` column stays.** Module 01's deterministic
`VECTOR(8, FLOAT32)` `embedding` column and its IVF index (`ticket_vec_idx`) are
left completely untouched — module 01 still uses them. Module 03 uses the new
`body_vec` and the HVI exclusively. (Module 01's vector assertions —
`txn-vector-visible`, `plan-spans-vector` — continue to pass on the toy column.)

**Text-index collision (merge note).** A CONTEXT/SEARCH text index and the HVI's
internal text component are the same indextype, so two cannot coexist on the same
column (`ORA-29879`). The shared `05-text-vector.sql` creates `ticket_text_idx`
(a SEARCH index) on `body`; module 03 needs the richer body text for a meaningful
hybrid proof, so `08-vector-model.sql` drops `ticket_text_idx` and lets the HVI
own body's text search (the HVI exposes the same `CONTAINS(body, ...)`
capability, which proof 4's keyword-only path uses). On the eventual merge with
the module-02 branch, whose read-after-write SEARCH proof uses `ticket_text_idx`,
that proof moves to the HVI or to the `subject` column — a merge-time decision.

---

## Run It Yourself

```bash
docker compose up -d --build oracle    # first build downloads the ~122 MB model
pip install -r validator/requirements.txt
python validator/run.py
```

The validator runs every script and exits 0 only if all assertions pass.

**These proofs leave the seeded domain unchanged.** Proofs that must `COMMIT`
(read-after-write) or perform DDL (the VPD policy, the helper tables) restore or
drop everything they touch and assert the teardown, so the validator runs any
number of times with identical results.
