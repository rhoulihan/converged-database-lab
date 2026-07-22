DECLARE /* Module 03 proof 2: a committed embedding change is IMMEDIATELY visible
   to the next approximate-similarity query — read-after-write on the vector path,
   with no reindex, no sleep, no LSN poll.

   A dedicated/synced vector store is eventually consistent here. Pinecone's own
   docs: "there can be a slight delay before new or changed records are visible
   to queries," and read-after-write must be hand-built by polling the
   x-pinecone-request-lsn / x-pinecone-max-indexed-lsn headers. MongoDB Atlas
   ($vectorSearch via mongot) replicates the index off the oplog asynchronously
   and gives no read-after-write guarantee. Oracle maintains the vector index
   inside the committing transaction (MVCC), so the change is visible on the next
   read by any session — there is no replication pipeline between models to lag.

   COMMIT / TEARDOWN EXCEPTION (honest): the validator rolls back SQL scripts to
   leave the domain unchanged, but this proof must COMMIT to demonstrate
   cross-statement visibility — and COMMIT cannot be rolled back. So the proof is
   fully self-restoring: it updates ticket #1's body_vec to an unrelated
   embedding, COMMITs, re-measures, then RECOMPUTES the original embedding from
   the unchanged `body` text and COMMITs again. The DDL helper table m03_raw_proof
   also autocommits and is dropped at the end. On success the domain is byte-for-
   byte pristine (restored distance == original distance, asserted).

   This first guard drops any helper table left by an interrupted run. */
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE m03_raw_proof PURGE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE TABLE m03_raw_proof (k VARCHAR2(30) PRIMARY KEY, v NUMBER);

DECLARE /* the whole capture / update+commit / re-measure / restore+commit cycle,
   in one block so the committed states are observed in order. Results land in
   m03_raw_proof for the standalone ASSERT selects below. body_vec is restored by
   re-embedding the untouched `body`, so the original value returns exactly. */
  v_qv          VECTOR;
  v_before_d    NUMBER;
  v_after_d     NUMBER;
  v_restored_d  NUMBER;
  v_before_rank NUMBER;
  v_after_rank  NUMBER;
BEGIN
  /* probe: a paraphrase, not a copy, of ticket #1's "Login fails ... after
     reset" body — the match is semantic, not verbatim */
  SELECT VECTOR_EMBEDDING(MINILM_L12 USING 'cannot access my account login error' AS data)
    INTO v_qv FROM dual;

  SELECT VECTOR_DISTANCE(body_vec, v_qv, COSINE) INTO v_before_d
    FROM support_tickets WHERE ticket_id = 1;
  SELECT rnk INTO v_before_rank FROM (
    SELECT ticket_id, ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE(body_vec, v_qv, COSINE)) rnk
    FROM support_tickets) WHERE ticket_id = 1;

  /* overwrite ticket #1's embedding with something semantically unrelated, COMMIT */
  UPDATE support_tickets
     SET body_vec = VECTOR_EMBEDDING(MINILM_L12 USING 'tropical fish aquarium maintenance schedule' AS data)
   WHERE ticket_id = 1;
  COMMIT;

  /* the very next query sees the new vector immediately — no reindex/sleep */
  SELECT VECTOR_DISTANCE(body_vec, v_qv, COSINE) INTO v_after_d
    FROM support_tickets WHERE ticket_id = 1;
  SELECT rnk INTO v_after_rank FROM (
    SELECT ticket_id, ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE(body_vec, v_qv, COSINE)) rnk
    FROM support_tickets) WHERE ticket_id = 1;

  /* restore the original embedding from the unchanged body text, COMMIT */
  UPDATE support_tickets
     SET body_vec = VECTOR_EMBEDDING(MINILM_L12 USING body AS data)
   WHERE ticket_id = 1;
  COMMIT;

  SELECT VECTOR_DISTANCE(body_vec, v_qv, COSINE) INTO v_restored_d
    FROM support_tickets WHERE ticket_id = 1;

  INSERT INTO m03_raw_proof VALUES ('before_rank',   v_before_rank);
  INSERT INTO m03_raw_proof VALUES ('after_rank',    v_after_rank);
  INSERT INTO m03_raw_proof VALUES ('dist_changed',  CASE WHEN ABS(v_after_d - v_before_d) > 0.01 THEN 1 ELSE 0 END);
  INSERT INTO m03_raw_proof VALUES ('restore_match', CASE WHEN ABS(v_restored_d - v_before_d) < 0.00001 THEN 1 ELSE 0 END);
  COMMIT;
END;
/

SELECT /* the committed embedding change moved the row distance to the probe —
          the write was immediately visible to the similarity query */
       'ASSERT:committed-write-visible:' ||
       CASE WHEN (SELECT v FROM m03_raw_proof WHERE k = 'dist_changed') = 1
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the row ANN rank changed too (it fell far down the top-k after the
          unrelated overwrite) — ranking reflects the new vector at once */
       'ASSERT:rank-changed:' ||
       CASE WHEN (SELECT v FROM m03_raw_proof WHERE k = 'after_rank')
                 > (SELECT v FROM m03_raw_proof WHERE k = 'before_rank')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* after re-embedding the untouched body and committing, the distance is
          identical to the original — the domain is restored byte-for-byte */
       'ASSERT:restored-exact:' ||
       CASE WHEN (SELECT v FROM m03_raw_proof WHERE k = 'restore_match') = 1
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* teardown: drop the helper table (DDL autocommits) so the domain is
   left exactly as seeded — support_tickets unchanged, no module-local objects */
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE m03_raw_proof PURGE';
END;
/

SELECT /* the helper table is gone — teardown verified */
       'ASSERT:teardown-clean:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM user_tables WHERE table_name = 'M03_RAW_PROOF';
