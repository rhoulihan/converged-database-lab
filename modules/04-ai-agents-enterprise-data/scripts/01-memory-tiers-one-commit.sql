DECLARE /* Module 04 proof 1: an AI agent's four memory tiers — the canonical
   CoALA taxonomy (working/episodic/semantic/procedural; arXiv:2309.02427) — as
   FOUR data models in ONE converged engine, written in ONE transaction and read
   back JOINED across all four. The agent's memory is internally consistent
   because it is one transaction over one engine: there is no partial-write window
   where the episodic log has the turn but the semantic index does not, and no
   cross-store reconciliation. Mapped to the engine:

     episodic (past turns)   -> the SHARED `events` JSON collection (a turn doc)
     facts    (semantic mem) -> relational rows in agent_facts (key/value)
     semantic recall         -> a note + its REAL in-DB VECTOR(384) embedding in
                                agent_semantic, queried with VECTOR_DISTANCE
     entities (knowledge)    -> a property graph (agent_graph) over agent_entities
                                + agent_entity_links, traversed with GRAPH_TABLE

   The contrast (leaf-4 §2/§3): an assembled agent-memory stack writes these across
   separate stores — e.g. Mem0 Cloud uses Qdrant (vectors) + Neo4j (graph) + Redis
   (KV); LangGraph a checkpointer DB + a separate Store + that Store's vector index;
   Letta Postgres+pgvector. No shared transaction spans them, so a torn write or a
   stale vector is structurally possible, and Mem0 v3's own June-2026 post lists
   "memory staleness in high-relevance facts" as an open gap. Here all four tiers
   commit together or not at all.

   DDL / COMMIT / TEARDOWN EXCEPTION: this proof creates four module-local tables
   and a property graph (DDL, autocommitting) and issues its own COMMIT to make the
   turn durable, then reads it back. None of that is reversible by the validator's
   end-of-script rollback, so cleanup is EXPLICIT and asserted: the session's
   `events` docs are deleted + committed and every module-local object is dropped
   before the script ends. This first block clears any leftovers from an
   interrupted prior run so the setup DDL below is idempotent. */
BEGIN
  BEGIN EXECUTE IMMEDIATE 'DROP PROPERTY GRAPH agent_graph';          EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE agent_entity_links PURGE';      EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE agent_entities PURGE';          EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE agent_semantic PURGE';          EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE agent_facts PURGE';             EXCEPTION WHEN OTHERS THEN NULL; END;
  DELETE FROM events e WHERE e.data.session_id.string() = 'sess-m04'; /* episodic tier uses the shared collection */
  COMMIT;
END;
/

CREATE TABLE agent_facts (
  session_id VARCHAR2(40),
  fact_key   VARCHAR2(60),
  fact_val   VARCHAR2(200),
  PRIMARY KEY (session_id, fact_key));

CREATE TABLE agent_semantic (
  session_id VARCHAR2(40),
  note_id    NUMBER,
  note       VARCHAR2(400),
  embedding  VECTOR(384, FLOAT32),
  PRIMARY KEY (session_id, note_id));

CREATE TABLE agent_entities (
  entity_id  VARCHAR2(60) PRIMARY KEY,
  session_id VARCHAR2(40),
  label      VARCHAR2(40));

CREATE TABLE agent_entity_links (
  from_entity VARCHAR2(60),
  to_entity   VARCHAR2(60),
  session_id  VARCHAR2(40),
  rel         VARCHAR2(40),
  PRIMARY KEY (from_entity, to_entity));

CREATE PROPERTY GRAPH agent_graph
  VERTEX TABLES (
    agent_entities KEY (entity_id)
      PROPERTIES (entity_id, session_id, label))
  EDGE TABLES (
    agent_entity_links KEY (from_entity, to_entity)
      SOURCE KEY (from_entity) REFERENCES agent_entities (entity_id)
      DESTINATION KEY (to_entity) REFERENCES agent_entities (entity_id)
      PROPERTIES (rel, session_id));

DECLARE /* THE PROOF TRANSACTION — one agent turn for session 'sess-m04' writes
   all four memory tiers, then a single COMMIT. Before the COMMIT we assert each
   tier is visible inside the SAME uncommitted transaction (one ASSERT per tier
   below, run after this block). The semantic note is embedded in-database by the
   same MINILM_L12 ONNX model that embeds the ticket bodies — a real 384-dim
   vector, not a placeholder. */
BEGIN
  -- episodic: the turn as a JSON document in the shared events collection
  INSERT INTO events (data) VALUES (JSON('{
    "type":"agent_turn","session_id":"sess-m04","role":"user",
    "text":"I want a refund for my damaged order 9001"}'));
  -- facts: extracted key/value facts as relational rows
  INSERT INTO agent_facts VALUES ('sess-m04','intent','refund');
  INSERT INTO agent_facts VALUES ('sess-m04','order_id','9001');
  -- semantic recall: a note + its REAL in-DB embedding
  INSERT INTO agent_semantic (session_id, note_id, note, embedding)
  VALUES ('sess-m04', 1, 'customer wants a refund for a damaged package',
          VECTOR_EMBEDDING(MINILM_L12 USING 'customer wants a refund for a damaged package' AS data));
  -- entities: a customer and an order vertex, linked by a "placed" edge
  INSERT INTO agent_entities VALUES ('cust-42','sess-m04','customer');
  INSERT INTO agent_entities VALUES ('order-9001','sess-m04','order');
  INSERT INTO agent_entity_links VALUES ('cust-42','order-9001','sess-m04','placed');
END;
/

SELECT /* tier 1 (episodic) visible inside the uncommitted transaction */
       'ASSERT:episodic-visible-in-txn:' ||
       CASE WHEN EXISTS (SELECT 1 FROM events e
                         WHERE e.data.session_id.string()='sess-m04'
                           AND e.data.type.string()='agent_turn') THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* tier 2 (facts) visible in the same transaction — both rows */
       'ASSERT:facts-visible-in-txn:' ||
       CASE WHEN (SELECT COUNT(*) FROM agent_facts WHERE session_id='sess-m04')=2 THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* tier 3 (semantic) visible — the real 384-dim embedding is present and
          recalls its own note at near-zero cosine distance */
       'ASSERT:semantic-visible-in-txn:' ||
       CASE WHEN (SELECT VECTOR_DISTANCE(embedding,
                    VECTOR_EMBEDDING(MINILM_L12 USING 'customer wants a refund for a damaged package' AS data),
                    COSINE)
                  FROM agent_semantic WHERE session_id='sess-m04' AND note_id=1) < 0.01
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* tier 4 (entities) visible — the graph hop traverses the uncommitted edge */
       'ASSERT:entity-graph-visible-in-txn:' ||
       CASE WHEN EXISTS (
              SELECT 1 FROM GRAPH_TABLE (agent_graph
                MATCH (a IS agent_entities) -[e IS agent_entity_links]-> (b IS agent_entities)
                WHERE a.entity_id='cust-42' AND b.entity_id='order-9001'
                COLUMNS (b.entity_id AS x)))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

COMMIT;

SELECT /* THE JOINED READ-BACK — one statement reconstructs the agent's full
   memory for the turn by touching all four models at once: the episodic turn doc
   (JSON), the extracted facts (relational), the nearest semantic note
   (VECTOR_DISTANCE recall), and the linked order (GRAPH_TABLE hop). One engine,
   one consistent read; an assembled stack would fan this across 3+ systems with
   no joinable, consistent view.

   This assertion fires only if every tier returns AND the tiers AGREE: the
   relational fact order_id='9001' is the SAME order the graph links to
   ('order-9001'), and the semantic note recalls at < 0.10 cosine distance to the
   turn's intent probe — the memory is internally consistent across all four
   models because all four committed in one transaction. */
       'ASSERT:joined-read-back-consistent:' ||
       CASE WHEN (
         SELECT COUNT(*) FROM (
           WITH ep AS (SELECT e.data.text.string() AS turn_text FROM events e
                       WHERE e.data.session_id.string()='sess-m04'
                         AND e.data.type.string()='agent_turn'),
                fa AS (SELECT MAX(CASE WHEN fact_key='intent'   THEN fact_val END) AS intent,
                              MAX(CASE WHEN fact_key='order_id' THEN fact_val END) AS order_id
                       FROM agent_facts WHERE session_id='sess-m04'),
                se AS (SELECT VECTOR_DISTANCE(embedding,
                              VECTOR_EMBEDDING(MINILM_L12 USING 'refund for a damaged package' AS data),
                              COSINE) AS recall_dist
                       FROM agent_semantic WHERE session_id='sess-m04'
                       ORDER BY recall_dist FETCH FIRST 1 ROWS ONLY),
                gr AS (SELECT linked_order FROM GRAPH_TABLE (agent_graph
                         MATCH (a IS agent_entities) -[e IS agent_entity_links]-> (b IS agent_entities)
                         WHERE a.entity_id='cust-42'
                         COLUMNS (b.entity_id AS linked_order)))
           SELECT 1
           FROM ep, fa, se, gr
           WHERE ep.turn_text IS NOT NULL
             AND fa.intent = 'refund'
             AND gr.linked_order = 'order-' || fa.order_id   /* facts and graph agree */
             AND se.recall_dist < 0.10                       /* semantic recall is a real match */
         )) = 1
       THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* OPTIONAL honest atomicity check: a SECOND turn whose four writes are
   rolled back leaves NOTHING behind in any tier — the same atomicity that makes
   the committed turn consistent also makes a failed turn leave no partial memory.
   We write all four tiers for 'sess-m04b', ROLLBACK, then assert each tier is
   empty for that session. */
BEGIN
  INSERT INTO events (data) VALUES (JSON('{"type":"agent_turn","session_id":"sess-m04b","role":"user","text":"second turn that will be rolled back"}'));
  INSERT INTO agent_facts VALUES ('sess-m04b','intent','cancel');
  INSERT INTO agent_semantic (session_id, note_id, note, embedding)
    VALUES ('sess-m04b', 1, 'rolled back note',
            VECTOR_EMBEDDING(MINILM_L12 USING 'rolled back note' AS data));
  INSERT INTO agent_entities VALUES ('temp-1','sess-m04b','temp');
  ROLLBACK;
END;
/

SELECT /* the rolled-back turn left no trace in any of the four tiers */
       'ASSERT:rolled-back-turn-leaves-nothing:' ||
       CASE WHEN (SELECT COUNT(*) FROM events e WHERE e.data.session_id.string()='sess-m04b') = 0
             AND (SELECT COUNT(*) FROM agent_facts    WHERE session_id='sess-m04b') = 0
             AND (SELECT COUNT(*) FROM agent_semantic WHERE session_id='sess-m04b') = 0
             AND (SELECT COUNT(*) FROM agent_entities WHERE session_id='sess-m04b') = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* TEARDOWN: remove the committed episodic doc (DELETE + COMMIT, since the
   harness rollback cannot reach a committed row) and drop every module-local
   object. All autocommitting DDL/DML — explicit by necessity. */
BEGIN
  DELETE FROM events e WHERE e.data.session_id.string() = 'sess-m04';
  COMMIT;
  EXECUTE IMMEDIATE 'DROP PROPERTY GRAPH agent_graph';
  EXECUTE IMMEDIATE 'DROP TABLE agent_entity_links PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE agent_entities PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE agent_semantic PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE agent_facts PURGE';
END;
/

SELECT /* nothing module-local survives and the shared events collection is back
          to its baseline (no sess-m04 / sess-m04b docs) — the domain is unchanged */
       'ASSERT:teardown-clean:' ||
       CASE WHEN (SELECT COUNT(*) FROM user_objects
                  WHERE object_name IN ('AGENT_FACTS','AGENT_SEMANTIC','AGENT_ENTITIES','AGENT_ENTITY_LINKS','AGENT_GRAPH')) = 0
             AND (SELECT COUNT(*) FROM events e
                  WHERE e.data.session_id.string() IN ('sess-m04','sess-m04b')) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
