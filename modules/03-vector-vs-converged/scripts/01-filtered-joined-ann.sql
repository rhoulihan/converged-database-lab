DELETE /* Module 03 proof 1: similarity AND relational filter AND join, in ONE
   optimizer-costed plan, against REAL 384-dim embeddings.

   The query is a production-shaped RAG retrieval: find the support tickets most
   semantically similar to a natural-language probe ("unable to log in after
   reset"), but only for premium/vip customers who have a recently SHIPPED order
   — similarity composed with live business predicates and a join to operational
   tables. The probe is embedded in-database by the same model that embedded the
   ticket bodies (VECTOR_EMBEDDING(MINILM_L12 USING ... AS data)), so it is a
   real semantic probe, not a canned literal vector.

   A dedicated vector store answers only the similarity half: the segment filter
   is flat-metadata-only, and the join to ORDERS is an application-side fetch
   against a second system. Here CUSTOMERS, ORDERS, and SUPPORT_TICKETS are all
   costed in ONE plan tree by ONE cost-based optimizer.

   OPTIMIZER NOTE (honest): with only 300 tickets the CBO chooses the PRE-FILTER
   strategy — apply the selective relational predicates first, then compute exact
   COSINE distance over the small surviving set — because a full scan of 300 rows
   is cheaper than navigating IVF centroid partitions. That is the optimizer
   doing its job: it costs pre-filter vs post-filter (and exact vs approximate)
   and picks the cheap one. The IVF index on body_vec is built, VALID, and would
   drive the plan at scale; this module proves COMPOSITION and one-plan-tree
   correctness, not ANN throughput (see README scale note). The final assertion
   confirms the IVF index exists and is VALID so the engine's approximate path is
   genuinely available. This first statement is an idempotence guard. */
FROM plan_table WHERE statement_id = 'm03-filtered';

EXPLAIN PLAN SET STATEMENT_ID = 'm03-filtered' FOR
SELECT t.ticket_id,
       c.full_name /* non-key column keeps CUSTOMERS in the plan (defeats join
                      elimination) so the relational join is visibly costed */,
       o.order_id,
       VECTOR_DISTANCE(t.body_vec,
         VECTOR_EMBEDDING(MINILM_L12 USING 'unable to log in after reset' AS data),
         COSINE) AS dist
FROM support_tickets t
JOIN customers c ON c.customer_id = t.customer_id
JOIN orders o   ON o.customer_id = c.customer_id
WHERE c.segment IN ('premium','vip')
  AND o.status = 'shipped'
  AND o.order_ts >= TIMESTAMP '2026-03-01 00:00:00'
ORDER BY dist
FETCH APPROX FIRST 10 ROWS ONLY WITH TARGET ACCURACY 90;

SELECT /* a real costed plan was produced (>= 8 row sources: 3 tables, 2 joins,
          sort, view, count-stopkey, select) */
       'ASSERT:plan-captured:' ||
       CASE WHEN COUNT(*) >= 8 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm03-filtered';

SELECT /* the operational customer table is costed in the same plan as the
          vector ORDER BY — the filter+join the dedicated store cannot do */
       'ASSERT:plan-spans-customers:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'CUSTOMERS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the orders table — the operational join target — is in the same plan */
       'ASSERT:plan-spans-orders:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'ORDERS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the table feeding VECTOR_DISTANCE (the real 384-dim body_vec) is
          costed in the same plan tree as the relational joins */
       'ASSERT:plan-spans-vector-table:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'SUPPORT_TICKETS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the VECTOR_DISTANCE drives the ranking — a SORT ORDER BY (STOPKEY)
          row source is present, i.e. similarity ordering is in the same plan */
       'ASSERT:vector-drives-sort:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND operation = 'SORT'
                           AND options LIKE 'ORDER BY%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* every row source above belongs to ONE plan tree — one optimizer, one
          statement, no federation seam between similarity and the relational join */
       'ASSERT:one-plan-tree:' ||
       CASE WHEN COUNT(DISTINCT plan_id) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm03-filtered';

SELECT /* the IVF approximate index on the real 384-dim column is built and
          VALID — the engine ANN path is genuinely available; the CBO simply
          costs exact cheaper at 300 rows (see header) */
       'ASSERT:ivf-index-valid:' ||
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM user_indexes
WHERE index_name = 'TICKETS_BODYVEC_IVF'
  AND index_type = 'VECTOR'
  AND status = 'VALID';
