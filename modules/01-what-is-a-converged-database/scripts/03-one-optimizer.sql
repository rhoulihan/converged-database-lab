WITH
/* Proof 3: one cost-based optimizer plans across all models in one statement:
   open/pending tickets from customers reachable in the referral graph from
   customer 10, ranked by vector similarity, with relational join context. */
ring AS (
  SELECT DISTINCT cid FROM GRAPH_TABLE (customer_graph
    MATCH (a IS customers) -[IS referrals]->{1,4} (b IS customers)
    WHERE a.customer_id = 10
    COLUMNS (b.customer_id AS cid))
)
SELECT 'ASSERT:converged-query-returns:' ||
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT c.customer_id
  FROM ring r
  JOIN customers c        ON c.customer_id = r.cid
  JOIN support_tickets st ON st.customer_id = c.customer_id
  WHERE st.status IN ('open','pending')
  ORDER BY VECTOR_DISTANCE(st.embedding,
           TO_VECTOR('[0.35,-0.35,0.35,-0.35,0.35,-0.35,0.35,-0.35]', 8, FLOAT32), COSINE)
  FETCH FIRST 10 ROWS ONLY
);

SELECT /* cycle detection from the seeded 4-hop referral ring (10→11→12→13→10) */
       'ASSERT:graph-cycle-found:' ||
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END
FROM GRAPH_TABLE (customer_graph
  MATCH (a IS customers) -[IS referrals]->{4} (a)
  WHERE a.customer_id = 10
  COLUMNS (a.customer_id AS cid));
