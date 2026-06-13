ALTER SESSION SET CONTAINER = FREEPDB1;

-- Module 03 infrastructure: REAL in-database embeddings + native Hybrid Vector
-- Index. This runs once on first boot (gvenzl initdb), after 01-07. It loads
-- Oracle's prebuilt augmented all-MiniLM-L12-v2 ONNX model (baked into the image
-- at /opt/oracle/models by docker/Dockerfile.oracle), embeds all 300 ticket
-- bodies into a real VECTOR(384) column, and builds the two indexes module 03
-- exercises. Idempotent: every CREATE is guarded so a recreated container over a
-- persistent volume re-runs cleanly.
--
-- Grants module 03 needs beyond the base 01-lab-user.sql set:
--   CREATE MINING MODEL  — DBMS_VECTOR.LOAD_ONNX_MODEL registers an ONNX model
--   READ ON ONNX_MODELS  — read the baked .onnx from the image directory
--   EXECUTE DBMS_VECTOR  — VECTOR_EMBEDDING / model load (public, granted for clarity)
--   EXECUTE DBMS_RLS     — VPD policy add/drop in 03-permission-aware-retrieval.sql
--   CREATE/DROP ANY CONTEXT — application context for the VPD tenant predicate
GRANT CREATE MINING MODEL TO lab_user;
GRANT CREATE ANY CONTEXT TO lab_user;
GRANT DROP ANY CONTEXT TO lab_user;
GRANT EXECUTE ON DBMS_VECTOR TO lab_user;
GRANT EXECUTE ON DBMS_RLS TO lab_user;

-- Directory over the baked model path; READ for lab_user so the load can open it.
CREATE OR REPLACE DIRECTORY ONNX_MODELS AS '/opt/oracle/models';
GRANT READ ON DIRECTORY ONNX_MODELS TO lab_user;

ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Load the model into the lab_user schema as MINILM_L12 so VECTOR_EMBEDDING
-- (MINILM_L12 USING <text> AS data) resolves for lab_user. The augmented model
-- carries its own tokenizer + pooling, so the metadata only needs to declare the
-- embedding function and the input attribute name (DATA, matching the AS data
-- alias used everywhere downstream). DROP first for idempotent re-runs.
DECLARE
  v_model_path VARCHAR2(400);
BEGIN
  BEGIN
    DBMS_VECTOR.DROP_ONNX_MODEL(model_name => 'MINILM_L12', force => TRUE);
  EXCEPTION WHEN OTHERS THEN NULL; /* not yet loaded — nothing to drop */
  END;
  DBMS_VECTOR.LOAD_ONNX_MODEL(
    directory  => 'ONNX_MODELS',
    file_name  => 'all_MiniLM_L12_v2.onnx',
    model_name => 'MINILM_L12',
    metadata   => JSON('{"function":"embedding","embeddingOutput":"embedding","input":{"input":["DATA"]}}'));
END;
/

-- Real 384-dim embedding column. The module-01 VECTOR(8) `embedding` column and
-- its IVF index (ticket_vec_idx) are LEFT UNTOUCHED — module 01 still uses them.
-- Module 03 uses this new body_vec and the HVI exclusively. Guarded so a
-- recreated container does not error on the already-present column.
DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists FROM user_tab_columns
   WHERE table_name = 'SUPPORT_TICKETS' AND column_name = 'BODY_VEC';
  IF v_exists = 0 THEN
    EXECUTE IMMEDIATE 'ALTER TABLE support_tickets ADD (body_vec VECTOR(384, FLOAT32))';
  END IF;
END;
/

-- Embed all 300 ticket bodies in-database — no external embedding service, no
-- copy pipeline. ~2.5s on the Free container. Re-runnable: recomputes from body.
UPDATE support_tickets SET body_vec = VECTOR_EMBEDDING(MINILM_L12 USING body AS data);

COMMIT;

-- IVF (NEIGHBOR PARTITIONS) vector index on the real 384-dim column. IVF needs
-- NO Vector Pool / VECTOR_MEMORY_SIZE, so it builds within the Free container's
-- SGA (HNSW would require carving VECTOR_MEMORY_SIZE from the 2 GB SGA — avoided
-- deliberately). Guarded for idempotent re-runs.
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX tickets_bodyvec_ivf';
EXCEPTION WHEN OTHERS THEN NULL; /* absent — first run */
END;
/
CREATE VECTOR INDEX tickets_bodyvec_ivf ON support_tickets(body_vec)
  ORGANIZATION NEIGHBOR PARTITIONS
  DISTANCE COSINE;

-- Hybrid Vector Index on the ticket body: one domain index unifying Oracle Text
-- (keyword) and a vector index (semantic) over the same column, queried via
-- DBMS_HYBRID_VECTOR.SEARCH with RRF/score fusion (04-hybrid-search.sql).
--
-- COLLISION NOTE: a CONTEXT/SEARCH text index and the HVI's internal text
-- component are the SAME indextype, so two cannot sit on the same column
-- (ORA-29879). The shared 05-text-vector.sql creates ticket_text_idx (a SEARCH
-- index) on body; module 03 needs the richer body text for a meaningful hybrid
-- proof, so we DROP ticket_text_idx here and let the HVI own body's text search.
-- The HVI exposes the same CONTAINS(body, ...) capability, so keyword-only
-- search in 04-hybrid-search.sql still works. (On the eventual merge with the
-- module-02 branch, whose read-after-write SEARCH proof uses ticket_text_idx,
-- that proof moves to the HVI or to the subject column — a merge-time decision.)
--
-- VECTOR_IDXTYPE IVF keeps the HVI's vector component off the Vector Pool
-- (Free-safe); MEMORY 256M caps the Oracle Text build memory modestly. Builds in
-- ~6s on the Free container.
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX tickets_hvi';
EXCEPTION WHEN OTHERS THEN NULL; /* absent — first run */
END;
/
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX ticket_text_idx';
EXCEPTION WHEN OTHERS THEN NULL; /* HVI takes over body text search */
END;
/
CREATE HYBRID VECTOR INDEX tickets_hvi ON support_tickets(body)
  PARAMETERS('MODEL MINILM_L12 VECTOR_IDXTYPE IVF MEMORY 256M');
