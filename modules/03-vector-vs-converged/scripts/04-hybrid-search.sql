DECLARE /* Module 03 proof 4: ONE engine, ONE index, ONE call fuses keyword and
   semantic search — Oracle's native Hybrid Vector Index (HVI) queried through
   DBMS_HYBRID_VECTOR.SEARCH. The HVI (tickets_hvi, built in 08-vector-model.sql)
   is a single domain index combining Oracle Text and a vector index over the
   same ticket body, with embeddings produced in-database by the all-MiniLM-L12-v2
   ONNX model.

   Why hybrid: Anthropic's Contextual Retrieval (Sept 2024) found that adding
   keyword/BM25 to embeddings reduced retrieval failures by up to 67% in their
   evaluation — lexical search catches exact ids/codes/acronyms that dense
   vectors miss, while vectors catch paraphrase a keyword query misses. The
   production stack is hybrid, not raw ANN.

   The contrast: pgvector + pg_search require hand-rolled reciprocal-rank fusion
   in application SQL because BM25 and vector scores are "incommensurable"
   (ParadeDB's own framing); Pinecone's sparse-dense scores "are not normalized
   to the dense vector range," so the app must weight and rerank; MongoDB's
   $rankFusion is Preview (8.1+). Here the fusion is one call: the HVI computes
   BOTH a vector_score and a text_score per row and returns a single fused,
   ranked result set.

   This proof: run the hybrid search (semantic probe "the box was crushed and
   broken in transit" + keyword "damaged"), capture the fused top-10; separately
   capture keyword-only (CONTAINS) and vector-only (VECTOR_DISTANCE on body_vec)
   top-10. Assertions prove (a) the hybrid call returns topN rows, (b) every
   fused row carries BOTH a vector and a text score — proof the single index ran
   keyword AND semantic together, and (c) the fused set differs from the
   keyword-only set — semantic recall surfaces rows lexical ranking alone misses.

   DDL EXCEPTION: the helper table m03_hybrid_proof is DDL (autocommits); it is
   dropped at the end and the drop is asserted. The HVI and the seeded rows are
   never modified. This first guard clears any leftover helper table. */
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE m03_hybrid_proof PURGE';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

CREATE TABLE m03_hybrid_proof (
  method     VARCHAR2(8),
  ticket_id  NUMBER,
  vscore     NUMBER,
  tscore     NUMBER,
  PRIMARY KEY (method, ticket_id)
);

DECLARE /* run the three retrievals and stash their top-10 into the helper table.
   The hybrid result is the JSON array returned by DBMS_HYBRID_VECTOR.SEARCH,
   unnested with JSON_TABLE; rowid maps back to ticket_id. Keyword-only uses the
   HVI's text component via CONTAINS; vector-only uses the real 384-dim body_vec
   IVF column. All three share the same probe text so the comparison is fair. */
  c_probe   CONSTANT VARCHAR2(80) := 'the box was crushed and broken in transit';
  c_keyword CONSTANT VARCHAR2(40) := 'damaged';
  v_json    CLOB;
BEGIN
  /* hybrid: one call, fused keyword + semantic over the single HVI */
  v_json := DBMS_HYBRID_VECTOR.SEARCH(
    json('{ "hybrid_index_name" : "tickets_hvi",
            "vector" : { "search_text" : "the box was crushed and broken in transit" },
            "text"   : { "contains"    : "damaged" },
            "return" : { "topN" : 10 } }'));
  INSERT INTO m03_hybrid_proof (method, ticket_id, vscore, tscore)
  SELECT 'HYBRID', t.ticket_id, h.vscore, h.tscore
  FROM JSON_TABLE(v_json, '$[*]'
         COLUMNS (rid    VARCHAR2(30) PATH '$.rowid',
                  vscore NUMBER       PATH '$.vector_score',
                  tscore NUMBER       PATH '$.text_score')) h
  JOIN support_tickets t ON t.rowid = CHARTOROWID(h.rid);

  /* keyword-only: pure lexical, the HVI text side via CONTAINS */
  INSERT INTO m03_hybrid_proof (method, ticket_id)
  SELECT 'KEYWORD', ticket_id FROM (
    SELECT ticket_id FROM support_tickets
    WHERE CONTAINS(body, c_keyword, 1) > 0
    ORDER BY SCORE(1) DESC, ticket_id
    FETCH FIRST 10 ROWS ONLY);

  /* vector-only: pure semantic, VECTOR_DISTANCE on the real body_vec column */
  INSERT INTO m03_hybrid_proof (method, ticket_id)
  SELECT 'VECTOR', ticket_id FROM (
    SELECT ticket_id FROM support_tickets
    ORDER BY VECTOR_DISTANCE(body_vec,
               VECTOR_EMBEDDING(MINILM_L12 USING c_probe AS data), COSINE)
    FETCH FIRST 10 ROWS ONLY);
  COMMIT;
END;
/

SELECT /* the hybrid call returned the requested top-N (10) fused rows */
       'ASSERT:hybrid-returns-topN:' ||
       CASE WHEN (SELECT COUNT(*) FROM m03_hybrid_proof WHERE method='HYBRID') = 10
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* every fused row carries BOTH a vector score and a text score — proof
          the single HVI ran keyword AND semantic search together and fused them
          in one call, no app-side RRF across two systems, no score normalization */
       'ASSERT:fusion-uses-both-signals:' ||
       CASE WHEN (SELECT COUNT(*) FROM m03_hybrid_proof
                  WHERE method='HYBRID' AND vscore IS NOT NULL AND tscore IS NOT NULL) = 10
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the fused result set differs from the keyword-only set — semantic
          recall pulls in rows pure lexical ranking does not surface (the
          hybrid-vs-lexical gap that Anthropic measured) */
       'ASSERT:fusion-differs-from-keyword:' ||
       CASE WHEN EXISTS (
              SELECT ticket_id FROM m03_hybrid_proof WHERE method='HYBRID'
              MINUS
              SELECT ticket_id FROM m03_hybrid_proof WHERE method='KEYWORD')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* teardown: drop the helper table (DDL autocommits). The HVI and all 300
   seeded ticket rows are untouched by this proof. */
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE m03_hybrid_proof PURGE';
END;
/

SELECT /* helper table gone — teardown verified, domain unchanged */
       'ASSERT:teardown-clean:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM user_tables WHERE table_name = 'M03_HYBRID_PROOF';
