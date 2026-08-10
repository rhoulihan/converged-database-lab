-- Module 04 proof 5: SCOPED + TEMPORAL recall over the SAME canonical memory that
-- proof 4 committed (session 'sess-atlas'). Vector similarity is only ONE way an
-- agent reaches memory. A useful memory system also needs flexible JSON scope
-- ("under what circumstances is this relevant?") and time ("what did we decide
-- last week? what did we believe before we changed our minds?"). These are
-- different access patterns over one store, not separate databases — Jeremy Daly's
-- "multimodel access-pattern problem, not a vector-database problem."
-- Requires proof 4 to have run (shared fixture; lexical order guarantees it).

SELECT /* "What do you remember about Project Atlas?" — semantic (vector) recall
   CONSTRAINED BY JSON SCOPE. The nearest memory by cosine distance is returned,
   but only within scope.project = 'Atlas': the storage decision surfaces, and
   Project Zephyr's semantically-similar "will use MongoDB" storage memory is
   filtered out by scope before ranking — the guardrail a raw vector index lacks. */
       'ASSERT:scoped-vector-recall:' ||
       CASE WHEN (SELECT memory_id FROM mem_memory
                  WHERE session_id = 'sess-atlas'
                    AND JSON_VALUE(scope, '$.project') = 'Atlas'
                  ORDER BY VECTOR_DISTANCE(embedding,
                             VECTOR_EMBEDDING(MINILM_L12 USING 'what storage database will Project Atlas use' AS data),
                             COSINE)
                  FETCH FIRST 1 ROWS ONLY) IN ('M1','M2')
             AND NOT EXISTS (SELECT 1 FROM mem_memory
                             WHERE JSON_VALUE(scope, '$.project') = 'Atlas' AND memory_id = 'M4')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* "What did we DECIDE about Atlas last week?" — scope + temporal + relational
   in one predicate: kind = decision, scope.project = Atlas, still valid, and
   valid_from within the last 7 days. Returns the current decision (M2, Oracle),
   not the superseded belief and not the unrelated project. */
       'ASSERT:scoped-temporal-decision:' ||
       CASE WHEN (SELECT COUNT(*) FROM mem_memory
                  WHERE session_id = 'sess-atlas'
                    AND kind = 'decision'
                    AND JSON_VALUE(scope, '$.project') = 'Atlas'
                    AND valid_from >= SYSTIMESTAMP - INTERVAL '7' DAY
                    AND (valid_to IS NULL OR valid_to > SYSTIMESTAMP)
                    AND statement LIKE '%Oracle converged database%') = 1
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* "What did we BELIEVE before we changed our minds?" — temporal history:
   the superseded belief (valid_to set / superseded_by pointing forward) is still
   in the canonical memory and recoverable. Returns the Postgres belief (M1) that
   the Oracle decision (M2) replaced. An ADD-only or overwrite-in-place memory
   layer cannot answer this. */
       'ASSERT:superseded-belief-recoverable:' ||
       CASE WHEN (SELECT statement FROM mem_memory
                  WHERE session_id = 'sess-atlas'
                    AND JSON_VALUE(scope, '$.project') = 'Atlas'
                    AND superseded_by IS NOT NULL) LIKE '%Postgres%'
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
