# Module 04 — How Converged Databases Help AI Agents Use Enterprise Data

Three runnable proofs for leaf article 4 ("How Converged Databases Help AI Agents
Use Enterprise Data"). An AI agent that only *answers* questions can tolerate
stale or over-broad data. An agent that *takes actions* — books the refund,
escalates the ticket, updates the record — cannot. The moment an agent acts, the
data behind its decision has to be **persistent** (it remembers across turns),
**fresh** (it reads what it just wrote), **governed** (it acts with the user's
permissions, not a superuser's), and **auditable** (every action is attributed).
This module proves three of those properties run natively in one engine, one
transaction, one governance domain:

1. **Memory** — the agent's four memory tiers (CoALA) as four data models in one
   transaction, read back joined.
2. **Governance** — the agent queries *as the acting user*, scoped by the engine
   on every read.
3. **Audit** — every agent query in one attributed, tamper-resistant trail.

Every script executes against the live lab container and emits machine-checkable
assertions (`ASSERT:<name>:PASS|FAIL`). No screenshots, no trust-me. The semantic
tier and the retrievals run on **real 384-dimension embeddings generated inside
the database** by Oracle's prebuilt augmented `all-MiniLM-L12-v2` ONNX model
(`MINILM_L12`) — not toy vectors.

**The model supplies the intelligence. The database supplies the ground truth.**

---

## Proof 1: `scripts/01-memory-tiers-one-commit.sql`

**Article claim (§3): four memory tiers, one engine, one transaction.** The
canonical agent-memory taxonomy (CoALA, arXiv:2309.02427) distinguishes four
memory types. This script realizes them as the four data models of the converged
engine and writes all four in **one transaction** for session `sess-m04`:

| CoALA tier | Data model | Object |
|---|---|---|
| episodic (past turns) | JSON document | the shared `events` collection |
| facts (semantic memory) | relational | `agent_facts` (key/value rows) |
| semantic recall | vector | `agent_semantic.embedding` `VECTOR(384)`, in-DB `VECTOR_EMBEDDING` |
| entities (knowledge graph) | property graph | `agent_graph` over `agent_entities` + `agent_entity_links` |

Before the single `COMMIT`, the script asserts each tier is visible **inside the
same uncommitted transaction**. After the `COMMIT`, a **single joined read-back**
reconstructs the agent's full memory by touching all four models at once — the
episodic turn doc, the relational facts, the nearest semantic note
(`VECTOR_DISTANCE` recall), and the linked order (`GRAPH_TABLE` hop) — and asserts
the tiers *agree*: the relational `order_id` is the same order the graph links to,
and the semantic note recalls at < 0.10 cosine distance. An optional atomicity
check writes a second turn, `ROLLBACK`s it, and proves it leaves no partial memory
in any tier. In an assembled stack (Mem0 = Qdrant + Neo4j + Redis; LangGraph =
checkpointer DB + Store + the Store's vector index; Letta = Postgres + pgvector)
those four writes span separate stores with no shared transaction — a torn write
or a stale vector is structurally possible.

The joined read-back returns one consistent row, e.g.:

```
turn_text    = I want a refund for my damaged order 9001
intent       = refund
order_id     = 9001
recall_dist  = 0.06       (semantic recall of the note, near-zero cosine distance)
linked_order = order-9001 (graph hop from cust-42)
```

Expected assertions:

```
ASSERT:episodic-visible-in-txn:PASS
ASSERT:facts-visible-in-txn:PASS
ASSERT:semantic-visible-in-txn:PASS
ASSERT:entity-graph-visible-in-txn:PASS
ASSERT:joined-read-back-consistent:PASS
ASSERT:rolled-back-turn-leaves-nothing:PASS
ASSERT:teardown-clean:PASS
```

**DDL / COMMIT / teardown exception.** This proof creates four module-local
tables and a property graph (DDL, autocommitting) and issues its own `COMMIT` to
make the turn durable — none of which the validator's end-of-script rollback can
undo. Cleanup is therefore explicit and asserted: the session's `events` docs are
deleted + committed and every module-local object is dropped before the script
ends. A guarded first block makes the setup idempotent across interrupted runs.

## Proof 2: `scripts/02-agent-acts-as-user.sql`

**Article claim (§4, the thesis section): the agent acts as the user, not a
superuser.** The *same* agent semantic-retrieval SQL, run under two acting
identities, returns **disjoint governed result sets** — enforced by the engine on
every read, regardless of how the agent phrased the query. This is OWASP LLM06's
mitigation verbatim ("execute actions on behalf of a user in the context of that
specific user, with minimum privileges" and "implement authorization in
downstream systems rather than relying on an LLM"), realized at the data layer.

The mechanism is a **Virtual Private Database** (`DBMS_RLS`) policy — included in
26ai Free — whose predicate keys off an application context holding the acting
end-user identity, toggled between `alice` (even-customer tickets) and `bob`
(odd-customer tickets) via `DBMS_SESSION.SET_CONTEXT`. The retrieval SQL
(`VECTOR_DISTANCE ... FETCH APPROX`) is byte-for-byte identical across both
identities; only the governed acting user differs. The two top-10 sets are
disjoint and parity-correct — the agent cannot phrase its way around the policy.

This is the VPD realization of Oracle Deep Data Security's principle (GA in 26ai):
it "eliminates the need for highly privileged, shared database connections." The
**full OAuth2 on-behalf-of token path needs OCI IAM and is described-and-cited in
the article, not run here.** The runnable proof uses VPD, which is the in-engine
enforcement Deep Sec and the managed MCP server both rely on
(`SYS_CONTEXT('MCP_SERVER_ACCESS_CONTEXT','USER_IDENTITY')`).

Object names are `m04_`-prefixed so this module never collides with module 03's
`m03_` VPD objects if both run.

Expected assertions:

```
ASSERT:both-identities-nonempty:PASS
ASSERT:identities-disjoint:PASS
ASSERT:governed-as-user:PASS
ASSERT:teardown-clean:PASS
```

**DDL / teardown exception.** Creates a context, setter procedure, predicate
function, `DBMS_RLS` policy, and a capture table — all autocommitting DDL. Every
object is dropped before the script ends; the final assertion confirms nothing
module-local survives and `support_tickets` is unrestricted at 300 rows.

## Proof 3: `scripts/03-unified-audit-trail.sql`

**Article claim (§6): one audit trail of every agent action.** When an agent acts
on enterprise data, "what did it read, as whom, when?" is a compliance question.
In a converged engine every agent-issued query — SQL, document API, vector
retrieval — lands in **one attributed, tamper-resistant trail**
(`UNIFIED_AUDIT_TRAIL`; `AUD$UNIFIED` is insert-only). The script creates an
`AUDIT POLICY` on `support_tickets`, runs the agent's vector retrieval under two
acting identities (tagged via `DBMS_SESSION.SET_IDENTIFIER` →
`CLIENT_IDENTIFIER`), then queries the trail and asserts both retrievals were
captured with their identity, the acting DB user, the object, and the full SQL
text. A real captured row:

```
EVENT_TIMESTAMP      2026-06-13 20:42:54
CLIENT_IDENTIFIER    m04run_<guid>_alice
DBUSERNAME           LAB_USER
ACTION_NAME          SELECT
OBJECT_NAME          SUPPORT_TICKETS
SQL_TEXT             SELECT ticket_id FROM support_tickets ORDER BY
                     VECTOR_DISTANCE(body_vec, VECTOR_EMBEDDING(MINILM_L12
                     USING 'refund for a damaged package' AS data), COSINE) FETCH ...
```

Assembling that across a polyglot agent stack means correlating logs from three
systems with three identity models; here it is one `SELECT` over one trail.

Expected assertions:

```
ASSERT:both-identities-audited:PASS
ASSERT:audit-attributes-user-and-object:PASS
ASSERT:audit-captures-sql-text:PASS
ASSERT:identities-distinguished:PASS
ASSERT:teardown-clean:PASS
```

**Audit-viewer access (init-10).** A least-privileged app user can neither create
an audit policy nor read `UNIFIED_AUDIT_TRAIL` by default — both are privileged
(`ORA-41732` and `ORA-00942` respectively). This branch adds
`docker/init/10-agent-audit-grants.sql`, granting `lab_user`:

- `AUDIT SYSTEM` — create + enable an `AUDIT POLICY` on its own tables.
- `AUDIT_VIEWER` — read-only on `UNIFIED_AUDIT_TRAIL` (cannot alter audit config).

That "who can read the audit trail is itself a separately-granted role" **is** the
governance story, not a workaround. (init-10 is new on `article/04`; it does not
touch the shared init-01..08.)

**Audit / determinism / no-flush exception.** Audit history rows are
**non-transactional and persist** across the validator's rollback (the trail is
append-only by design). Every assertion is therefore scoped to a **per-run nonce**
(a `SYS_GUID` stamped into an application context once per run and prefixed onto
both `CLIENT_IDENTIFIER`s), so re-runs are deterministic despite accumulated
history. 26ai Free writes the trail in **immediate mode**, so rows appear without
`DBMS_AUDIT_MGMT.FLUSH_UNIFIED_AUDIT_TRAIL` — the flush procedure is not granted
to the least-privileged `lab_user` and is **not needed** here.

---

## Described and cited (not CI-built)

**Select AI Agent (`DBMS_CLOUD_AI_AGENT`).** The article describes Oracle's
in-database agent runtime (ReAct loop, SQL/RAG/web/notification tools,
human-in-the-loop, `USER_AI_AGENT_*_HISTORY` audit views) and cites the Select AI
Capability Matrix showing it on the 23.26 on-prem line. **It is not built here:**
the `DBMS_CLOUD` family (and `DBMS_CLOUD_AI`) is *not pre-installed* in the
gvenzl/oracle-free image — `DBMS_CLOUD_AI.CREATE_PROFILE` resolves to
`PLS-00201: must be declared`. The planned negative test (asserting `ORA-20047`,
the documented on-prem HTTPS-LLM restriction) requires first installing the whole
`DBMS_CLOUD` suite via `catcon.pl` plus a wallet/cert and a network ACL — out of
scope for a deterministic CI proof. The restriction is real and cited in prose;
**this test is intentionally skipped** rather than faked, so the three core proofs
above stay clean.

**SQLcl MCP server.** Described and cited (`DBTOOLS$MCP_LOG`,
`V$SESSION.MODULE/ACTION` attribution, runs as the connected user). It is
`stdio`-only and needs an external MCP client, so it is not a CI proof; proofs 2
and 3 demonstrate the *in-database* governance and audit primitives the MCP path
relies on.

---

## Run It Yourself

```bash
docker compose up -d --build oracle          # ~8 min fresh build bakes the ONNX model
pip install -r validator/requirements.txt
python validator/run.py                       # runs every module, prints ASSERT results
```

The validator runs each script and exits 0 only if all assertions pass. **These
proofs leave the seeded domain unchanged** — the SQL scripts clean up their own
autocommitted DDL/DML (the validator's rollback cannot), so the validator runs any
number of times with identical results. The only persistent residue is the
append-only audit-trail rows from proof 3, scoped to a per-run nonce and harmless
by design.

This module emits **16 assertions across three scripts** (7 + 4 + 5).
