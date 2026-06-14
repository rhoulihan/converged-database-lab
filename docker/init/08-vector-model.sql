ALTER SESSION SET CONTAINER = FREEPDB1;

-- In-database embeddings infrastructure (foundational; used by the AI articles).
-- Runs once on first boot (gvenzl initdb), after 01-07. Loads Oracle's prebuilt
-- augmented all-MiniLM-L12-v2 ONNX model (baked into the image at /opt/oracle/models
-- by docker/Dockerfile.oracle), embeds all 300 ticket bodies into a real VECTOR(384)
-- column, and builds an IVF vector index on it. Idempotent: every CREATE is guarded
-- so a recreated container over a persistent volume re-runs cleanly.
--
-- Grants used by the AI modules beyond the base 01-lab-user.sql set:
--   CREATE MINING MODEL  — DBMS_VECTOR.LOAD_ONNX_MODEL registers an ONNX model
--   READ ON ONNX_MODELS  — read the baked .onnx from the image directory
--   EXECUTE DBMS_VECTOR  — VECTOR_EMBEDDING / model load
--   EXECUTE DBMS_RLS     — VPD policies (permission-aware retrieval proofs)
--   CREATE/DROP ANY CONTEXT — application context for VPD tenant/user predicates
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
-- its IVF index (ticket_vec_idx) are LEFT UNTOUCHED. Guarded so a recreated
-- container does not error on the already-present column.
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
-- SGA. Guarded for idempotent re-runs.
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX tickets_bodyvec_ivf';
EXCEPTION WHEN OTHERS THEN NULL; /* absent — first run */
END;
/
CREATE VECTOR INDEX tickets_bodyvec_ivf ON support_tickets(body_vec)
  ORGANIZATION NEIGHBOR PARTITIONS
  DISTANCE COSINE;
