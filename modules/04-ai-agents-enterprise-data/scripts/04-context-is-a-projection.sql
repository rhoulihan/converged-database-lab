DECLARE /* Module 04 proof 4: CONTEXT IS A PROJECTION.
   An agent's context window is not its memory. Memory is the canonical, persistent
   model of what the agent knows; context is a purpose-built PROJECTION of that
   memory for this agent, this conversation, and this moment (UMT: model once,
   project many ways). This proof builds ONE canonical memory store and projects it
   into an application-ready context document with a JSON Relational Duality View.

   Jeremy Daly's framing (leaf-4): memory retrieval is inherently multimodel — it
   needs relational structure (ownership/governance), flexible JSON (scope/tags),
   vector (semantic recall), graph (relationships/provenance), and time (recency,
   superseded beliefs) — often in the SAME retrieval. These are not five copies;
   they are access patterns and projections over one canonical store.

   SHARED-FIXTURE PATTERN (proofs 4-6): unlike proofs 1-3 (each self-contained),
   proofs 4, 5 and 6 demonstrate DIFFERENT projections of the SAME canonical memory,
   so this script creates and COMMITs the canonical model once; proof 6 tears it
   down. This block clears any leftovers from an interrupted run so setup is
   idempotent. All DDL autocommits; the seed is explicitly committed. */
BEGIN
  BEGIN EXECUTE IMMEDIATE 'DROP VIEW mem_context_dv';                         EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PROPERTY GRAPH mem_graph';                    EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE mem_relate PURGE';                      EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE mem_provenance PURGE';                  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE mem_memory PURGE';                      EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE mem_source PURGE';                      EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

-- canonical memory: relational ownership + native JSON scope + temporal validity +
-- a real in-DB vector, all on one row. "Who may see this?" is relational
-- (session_id); "when is this relevant?" is flexible JSON (scope) — Jeremy's split.
CREATE TABLE mem_source (
  source_id   VARCHAR2(20) PRIMARY KEY,
  kind        VARCHAR2(20),                 -- conversation | document | observation
  ref         VARCHAR2(200),
  occurred_at TIMESTAMP);

CREATE TABLE mem_memory (
  memory_id     VARCHAR2(20) PRIMARY KEY,
  session_id    VARCHAR2(40),               -- relational ownership / security boundary
  kind          VARCHAR2(20),               -- belief | decision | fact | risk
  statement     VARCHAR2(400),
  scope         JSON,                        -- flexible retrieval scope/tags (native JSON)
  valid_from    TIMESTAMP,
  valid_to      TIMESTAMP,                   -- NULL = still believed
  superseded_by VARCHAR2(20),               -- the memory that replaced this belief
  -- embedding: semantic recall, generated in-DB by the MINILM_L12 ONNX model
  embedding     VECTOR(384, FLOAT32));

CREATE TABLE mem_provenance (              -- memory <- derived from -> source
  memory_id VARCHAR2(20),
  source_id VARCHAR2(20),
  PRIMARY KEY (memory_id, source_id));

CREATE TABLE mem_relate (                  -- memory -> relates to -> memory
  from_mem VARCHAR2(20),
  to_mem   VARCHAR2(20),
  rel      VARCHAR2(40),
  PRIMARY KEY (from_mem, to_mem));

-- one property graph over the same canonical rows: provenance + relationships
CREATE PROPERTY GRAPH mem_graph
  VERTEX TABLES (
    mem_memory KEY (memory_id) LABEL memory PROPERTIES (memory_id, statement, kind),
    mem_source KEY (source_id) LABEL source PROPERTIES (source_id, ref))
  EDGE TABLES (
    mem_provenance KEY (memory_id, source_id)
      SOURCE KEY (memory_id) REFERENCES mem_memory (memory_id)
      DESTINATION KEY (source_id) REFERENCES mem_source (source_id)
      LABEL derived_from,
    mem_relate KEY (from_mem, to_mem)
      SOURCE KEY (from_mem) REFERENCES mem_memory (memory_id)
      DESTINATION KEY (to_mem) REFERENCES mem_memory (memory_id)
      LABEL relates_to PROPERTIES (rel));

-- a context document projected from the canonical memory, generated not stored:
-- each memory with its native JSON scope and its provenance (which source it came
-- from), assembled into one application-ready shape. Duality view = the projection.
CREATE JSON RELATIONAL DUALITY VIEW mem_context_dv AS
SELECT JSON {
  '_id'       : m.memory_id,
  'session'   : m.session_id,
  'kind'      : m.kind,
  'statement' : m.statement,
  'scope'     : m.scope,
  'validFrom' : m.valid_from,
  'validTo'   : m.valid_to,
  'provenance':
    [ SELECT JSON { 'memoryId' : p.memory_id,
                    'sourceId' : p.source_id,
                    'source'   : ( SELECT JSON { 'sourceId' : s.source_id,
                                                 'kind' : s.kind, 'ref' : s.ref }
                                   FROM mem_source s WITH NOUPDATE
                                   WHERE s.source_id = p.source_id ) }
      FROM mem_provenance p WITH INSERT UPDATE DELETE
      WHERE p.memory_id = m.memory_id ]
} FROM mem_memory m WITH INSERT UPDATE DELETE;

DECLARE /* SEED one canonical memory for session 'sess-atlas' about "Project Atlas":
   a superseded belief (Postgres), the decision that replaced it (Oracle converged),
   a fact, an unrelated project's decision (scope exclusion), and a related risk.
   Timestamps are relative to now so the temporal queries in proof 5 are
   deterministic. Every statement is embedded in-DB by the MINILM_L12 ONNX model. */
BEGIN
  INSERT INTO mem_source VALUES ('S1','conversation','Atlas kickoff call',      SYSTIMESTAMP - INTERVAL '10' DAY);
  INSERT INTO mem_source VALUES ('S2','conversation','Atlas planning meeting',  SYSTIMESTAMP - INTERVAL '3'  DAY);
  INSERT INTO mem_source VALUES ('S3','document',    'Atlas PRD v2',            SYSTIMESTAMP - INTERVAL '5'  DAY);

  INSERT INTO mem_memory VALUES ('M1','sess-atlas','belief',
    'Project Atlas will store its data in Postgres', JSON('{"project":"Atlas","topic":"storage"}'),
    SYSTIMESTAMP - INTERVAL '10' DAY, SYSTIMESTAMP - INTERVAL '3' DAY, 'M2',
    VECTOR_EMBEDDING(MINILM_L12 USING 'Project Atlas will store its data in Postgres' AS data));
  INSERT INTO mem_memory VALUES ('M2','sess-atlas','decision',
    'Project Atlas will use the Oracle converged database for storage', JSON('{"project":"Atlas","topic":"storage"}'),
    SYSTIMESTAMP - INTERVAL '3' DAY, NULL, NULL,
    VECTOR_EMBEDDING(MINILM_L12 USING 'Project Atlas will use the Oracle converged database for storage' AS data));
  INSERT INTO mem_memory VALUES ('M3','sess-atlas','fact',
    'Project Atlas launches in Q4', JSON('{"project":"Atlas","topic":"schedule"}'),
    SYSTIMESTAMP - INTERVAL '5' DAY, NULL, NULL,
    VECTOR_EMBEDDING(MINILM_L12 USING 'Project Atlas launches in Q4' AS data));
  INSERT INTO mem_memory VALUES ('M4','sess-atlas','decision',
    'Project Zephyr will use MongoDB', JSON('{"project":"Zephyr","topic":"storage"}'),
    SYSTIMESTAMP - INTERVAL '20' DAY, NULL, NULL,
    VECTOR_EMBEDDING(MINILM_L12 USING 'Project Zephyr will use MongoDB' AS data));
  INSERT INTO mem_memory VALUES ('M5','sess-atlas','risk',
    'Migrating data off Postgres is a launch risk for Atlas', JSON('{"project":"Atlas","topic":"storage"}'),
    SYSTIMESTAMP - INTERVAL '2' DAY, NULL, NULL,
    VECTOR_EMBEDDING(MINILM_L12 USING 'Migrating data off Postgres is a launch risk for Atlas' AS data));

  INSERT INTO mem_provenance VALUES ('M1','S1');
  INSERT INTO mem_provenance VALUES ('M2','S2');
  INSERT INTO mem_provenance VALUES ('M3','S3');
  INSERT INTO mem_relate     VALUES ('M2','M5','relates_to');
  COMMIT;
END;
/

SELECT /* CONTEXT AS PROJECTION: the duality view assembles canonical memory M2 into
   one application-ready context document — statement + native JSON scope + its
   provenance (the source it was derived from) — generated, not stored. This is
   "pick up where we left off": one JSON shape projected from relational + JSON +
   link data, ready to drop into the agent's context window. */
       'ASSERT:context-projection-assembles:' ||
       CASE WHEN json_value(data, '$.statement') LIKE '%Oracle converged database%'
             AND json_value(data, '$.scope.project') = 'Atlas'
             AND json_value(data, '$.provenance[0].sourceId') = 'S2'
             AND json_value(data, '$.provenance[0].source.ref') = 'Atlas planning meeting'
            THEN 'PASS' ELSE 'FAIL' END
FROM mem_context_dv WHERE json_value(data, '$._id') = 'M2';

SELECT /* the same canonical row is reachable as flexible JSON scope AND as a
   relational ownership boundary — one store, two access patterns, no copy */
       'ASSERT:scope-is-json-ownership-is-relational:' ||
       CASE WHEN (SELECT COUNT(*) FROM mem_memory
                  WHERE session_id = 'sess-atlas'                     -- relational security
                    AND JSON_VALUE(scope, '$.project') = 'Atlas') = 4 -- flexible JSON scope
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
