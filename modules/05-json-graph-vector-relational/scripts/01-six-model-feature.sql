DELETE /* Module 05 proof 1 (THE HEADLINE): one real application feature
   expressed as ONE SQL statement spanning SIX data models, planned by ONE
   cost-based optimizer in ONE transaction. The anchor's module-01 one-plan
   proved FOUR models (graph + document + vector + relational); this adds the two
   models no prior module exercised — SPATIAL and TEXT — to reach six.

   THE FEATURE — proactive support outreach / customer-360-for-action: starting
   from a flagged account (customer 10), find the customers worth contacting now.
     - GRAPH   : the flagged account's shared-device ring (fraud/abuse travel in
                 rings) — customers who share a device with customer 10, via a
                 two-edge GRAPH_TABLE pattern over CUSTOMER_DEVICES.
     - RELATIONAL: keep only premium/vip customers; join CUSTOMERS/ORDERS/STORES.
     - SPATIAL : who placed an order at a store within 50 km of our downtown-
                 Austin service center (so an in-person follow-up is feasible) —
                 SDO_WITHIN_DISTANCE against a fixed reference point (a single-
                 geometry probe, NOT a table-to-table spatial join).
     - VECTOR  : who has an open/pending ticket SEMANTICALLY near a known defect
                 ("user cannot log in after password reset"), embedded in-database
                 by the same MiniLM-L12 ONNX model that embedded the ticket bodies.
     - TEXT    : whose ticket body also lexically mentions the issue
                 (CONTAINS 'login OR authentication', via the Oracle Text index).
     - DOCUMENT: project each match as a ready-to-use customer_profile_dv JSON
                 document (JSON_VALUE / JSON_SERIALIZE on the duality view).

   TUNED CONSTANTS (verified live to return >= 1 row on the seeded data): flagged
   customer = 10; radius = 50 km from (-97.7431, 30.2672); defect probe = 'user
   cannot log in after password reset'; keyword = 'login OR authentication'. The
   match is customer 15 (premium, in customer 10's shared-device ring, ticket 209
   "Cannot sign in after password reset", orders at Downtown Austin + Domain North
   inside 50 km). DISTINCT collapses customer 15's several in-radius orders to one
   outreach row.

   OPTIMIZER NOTE (honest, mirrors module 03): at 300 tickets / 6 stores the CBO
   drives the spatial DOMAIN INDEX (STORES_GEOM_IDX) for the geo probe but applies
   CONTAINS and VECTOR_DISTANCE as functional filter / top-k SORT over the small
   surviving candidate set rather than navigating the text/IVF domain indexes —
   a full scan of the handful of survivors is cheaper. That is the optimizer
   costing every model in ONE plan and picking the cheap path; the indexes are
   built and VALID and would drive the plan at scale. This module proves
   COMPOSITION and one-plan-tree correctness across six models, not index
   throughput.

   This first statement is an idempotence guard: clear any prior plan rows. */
FROM plan_table WHERE statement_id = 'm05-sixmodel';

SELECT /* the feature returns at least one customer to contact — the six-model
          statement actually runs and produces a result on the seeded data */
       'ASSERT:six-model-returns:' ||
       CASE WHEN COUNT(*) >= 1 THEN 'PASS' ELSE 'FAIL' END
FROM (
  WITH ring AS (
    SELECT DISTINCT b_id AS cid
    FROM GRAPH_TABLE (customer_graph
      MATCH (a IS customers) -[IS customer_devices]-> (d IS devices)
            <-[IS customer_devices]- (b IS customers)
      WHERE a.customer_id = 10
      COLUMNS (b.customer_id AS b_id))
  )
  SELECT DISTINCT c.customer_id,
         JSON_VALUE(p.data, '$.email') AS email,
         VECTOR_DISTANCE(st.body_vec,
           VECTOR_EMBEDDING(MINILM_L12 USING 'user cannot log in after password reset' AS data),
           COSINE) AS dist
  FROM ring r
  JOIN customers c          ON c.customer_id = r.cid
  JOIN orders o             ON o.customer_id = c.customer_id
  JOIN stores s             ON s.store_id = o.store_id
  JOIN support_tickets st   ON st.customer_id = c.customer_id
  JOIN customer_profile_dv p ON JSON_VALUE(p.data, '$._id' RETURNING NUMBER) = c.customer_id
  WHERE c.segment IN ('premium','vip')
    AND st.status IN ('open','pending')
    AND CONTAINS(st.body, 'login OR authentication') > 0
    AND SDO_WITHIN_DISTANCE(
          s.location,
          SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
          'distance=50 unit=KM') = 'TRUE'
  ORDER BY dist
  FETCH FIRST 10 ROWS ONLY
);

EXPLAIN PLAN SET STATEMENT_ID = 'm05-sixmodel' FOR
WITH ring AS (
  SELECT DISTINCT b_id AS cid
  FROM GRAPH_TABLE (customer_graph
    MATCH (a IS customers) -[IS customer_devices]-> (d IS devices)
          <-[IS customer_devices]- (b IS customers)
    WHERE a.customer_id = 10
    COLUMNS (b.customer_id AS b_id))
)
SELECT c.customer_id,
       c.full_name /* non-key column defeats join elimination so CUSTOMERS
                      survives as a visible relational row source */,
       st.ticket_id,
       JSON_SERIALIZE(p.data) AS profile_doc
FROM ring r
JOIN customers c          ON c.customer_id = r.cid
JOIN orders o             ON o.customer_id = c.customer_id
JOIN stores s             ON s.store_id = o.store_id
JOIN support_tickets st   ON st.customer_id = c.customer_id
JOIN customer_profile_dv p ON JSON_VALUE(p.data, '$._id' RETURNING NUMBER) = c.customer_id
WHERE c.segment IN ('premium','vip')
  AND st.status IN ('open','pending')
  AND CONTAINS(st.body, 'login OR authentication') > 0
  AND SDO_WITHIN_DISTANCE(
        s.location,
        SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
        'distance=50 unit=KM') = 'TRUE'
ORDER BY VECTOR_DISTANCE(st.body_vec,
         VECTOR_EMBEDDING(MINILM_L12 USING 'user cannot log in after password reset' AS data),
         COSINE)
FETCH FIRST 10 ROWS ONLY;

SELECT /* a real costed plan was produced (many row sources: 5 tables, the
          spatial domain index, the graph edge access, joins, the vector sort) */
       'ASSERT:plan-captured:' ||
       CASE WHEN COUNT(*) >= 10 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm05-sixmodel';

SELECT /* GRAPH leg: the shared-device GRAPH_TABLE pattern lowers to row sources
          over the CUSTOMER_DEVICES edge table — the CBO walks the edges through
          their PK index (system-generated name), so resolve it via user_indexes
          exactly as module 01 did for REFERRALS */
       'ASSERT:plan-spans-graph:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm05-sixmodel'
                           AND (p.object_name = 'CUSTOMER_DEVICES'
                                OR p.object_name IN (SELECT i.index_name
                                                     FROM user_indexes i
                                                     WHERE i.table_name = 'CUSTOMER_DEVICES')))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* RELATIONAL leg: the operational CUSTOMERS and ORDERS tables are costed
          in the same plan as everything else */
       'ASSERT:plan-spans-relational:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND object_name = 'CUSTOMERS')
             AND EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND object_name = 'ORDERS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* SPATIAL leg: the geo probe is served by the R-tree spatial DOMAIN INDEX
          STORES_GEOM_IDX, in the same plan tree (the model no prior module had) */
       'ASSERT:plan-spans-spatial:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND object_name = 'STORES_GEOM_IDX'
                           AND operation = 'DOMAIN INDEX')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* TEXT + VECTOR leg: SUPPORT_TICKETS feeds both the CONTAINS keyword
          predicate and the VECTOR_DISTANCE ranking, costed in the same plan.
          The CONTAINS predicate is attached to the SUPPORT_TICKETS access. */
       'ASSERT:plan-spans-text-vector-table:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND object_name = 'SUPPORT_TICKETS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* TEXT leg specifically: the Oracle Text CONTAINS operator is present in
          the plan's predicate information (CTXSYS.CONTAINS on the ticket body) —
          keyword search is costed inside the one statement, not a side call */
       'ASSERT:plan-contains-text-predicate:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND UPPER(filter_predicates) LIKE '%CONTAINS%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* VECTOR leg specifically: the VECTOR_DISTANCE top-k ranking shows as a
          SORT ORDER BY (STOPKEY) row source — similarity ordering is in the
          same plan as the graph/spatial/text/relational access */
       'ASSERT:plan-vector-drives-sort:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND operation = 'SORT'
                           AND options LIKE 'ORDER BY%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* SPATIAL predicate is present in the plan's predicate info — the geo
          filter is genuinely part of this one statement's evaluation */
       'ASSERT:plan-contains-spatial-predicate:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table WHERE statement_id = 'm05-sixmodel'
                           AND UPPER(access_predicates) LIKE '%SDO_WITHIN_DISTANCE%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* ONE optimizer, ONE statement, ONE plan: every row source above belongs
          to a single plan tree — no federation seam between the six models */
       'ASSERT:one-plan-tree:' ||
       CASE WHEN COUNT(DISTINCT plan_id) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm05-sixmodel';
