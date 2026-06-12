DELETE /* Proof 5: one cost-based optimizer produces a single plan spanning
   graph, document, vector, and relational access in one statement. Oracle
   translates GRAPH_TABLE internally to equivalent SQL, so the plan shows the
   graph as an ordinary VIEW row source over the REFERRALS edge table — one
   cost model, no federation seam. This first statement is an idempotence
   guard: clear any prior rows for this statement id. */
FROM plan_table WHERE statement_id = 'm01-one-plan';

EXPLAIN PLAN SET STATEMENT_ID = 'm01-one-plan' FOR
WITH ring AS (
  SELECT DISTINCT cid FROM GRAPH_TABLE (customer_graph
    MATCH (a IS customers) -[IS referrals]->{1,4} (b IS customers)
    WHERE a.customer_id = 10
    COLUMNS (b.customer_id AS cid))
)
SELECT c.customer_id,
       c.full_name /* selecting a non-key column defeats join elimination so
                      CUSTOMERS survives as a row source in the plan */
FROM ring r
JOIN customers c        ON c.customer_id = r.cid
JOIN support_tickets st ON st.customer_id = c.customer_id
WHERE st.status IN ('open','pending')
  AND NOT EXISTS (SELECT /* document-model predicate in the same plan */ 1
                  FROM events e
                  WHERE e.data.type.string() = 'suppression'
                    AND e.data.customerId.number() = c.customer_id)
ORDER BY VECTOR_DISTANCE(st.embedding,
         TO_VECTOR('[0.35,-0.35,0.35,-0.35,0.35,-0.35,0.35,-0.35]', 8, FLOAT32), COSINE)
FETCH FIRST 10 ROWS ONLY;

SELECT /* a real costed plan was produced */ 'ASSERT:plan-captured:' ||
       CASE WHEN COUNT(*) >= 4 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm01-one-plan';

SELECT /* GRAPH_TABLE lowers to an ordinary VIEW row source named for the
          graph (CUSTOMER_GRAPH) that walks the REFERRALS edge table — the CBO
          reads the edges through their PK index, whose name is
          system-generated, so resolve it via user_indexes */
       'ASSERT:plan-spans-graph:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm01-one-plan'
                           AND object_name = 'CUSTOMER_GRAPH')
             AND EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm01-one-plan'
                           AND (p.object_name = 'REFERRALS'
                                OR p.object_name IN (SELECT i.index_name
                                                     FROM user_indexes i
                                                     WHERE i.table_name = 'REFERRALS')))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT 'ASSERT:plan-spans-relational:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm01-one-plan'
                           AND object_name = 'CUSTOMERS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the JSON collection table appears under its own name */
       'ASSERT:plan-spans-document:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm01-one-plan'
                           AND object_name = 'EVENTS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the table feeding VECTOR_DISTANCE is costed in the same plan */
       'ASSERT:plan-spans-vector:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm01-one-plan'
                           AND object_name = 'SUPPORT_TICKETS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* every row source above belongs to a single plan tree */
       'ASSERT:one-plan-tree:' ||
       CASE WHEN COUNT(DISTINCT plan_id) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm01-one-plan';
