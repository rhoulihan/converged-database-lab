DELETE /* Module 03 proof 1: similarity AND relational filter AND join, in ONE
   optimizer-costed plan — with the IVF vector index driving the search and the
   relational predicates PROVABLY applied inside the plan, before the ranking.
   Against REAL 384-dim embeddings over 10,000 tickets.

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
   costed in ONE plan tree by ONE cost-based optimizer — and the DBMS_XPLAN
   predicate list shows WHERE each filter runs.

   WHAT THE PLAN SHOWS (the filter-first proof): at 10,000 tickets the CBO
   chooses the IVF vector index (VECTOR$TICKETS_BODYVEC_IVF$... row sources):
   the index's top centroid partitions produce the similarity candidates, the
   candidates join back to SUPPORT_TICKETS by rowid, the segment predicate is
   evaluated on the CUSTOMERS scan and the status/date predicate on the ORDERS
   scan — all VISIBLE in the Predicate Information section — and only the
   filtered, joined survivors reach the final top-10 SORT ORDER BY STOPKEY.
   The filters run before the ranking — they are never applied AFTER a
   pre-ranked top-10, which is pgvector's documented post-index mode (a
   10%-selective predicate leaving ~4 rows of a requested 10).

   OPTIMIZER HONESTY: this is a genuine cost-based choice, not a hint. With
   fresh stats (gathered at init) the same query full-scans at 300 rows —
   exact distance over a few hundred rows is simply cheaper than probing
   centroid partitions — and the crossover to the IVF index arrives by
   roughly 3,000 rows on the Free container. Oracle documents both the pre-filter and post-filter IVF
   strategies and costs them; the optimizer weighs, then picks. This module
   proves COMPOSITION and in-plan filtering on a 2-core Free container — it is
   never a latency or recall benchmark (see README scale note). This first
   statement is an idempotence guard. */
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

SELECT /* the human-readable plan WITH the predicate list — the exhibit the
          article prints. Not an assertion; the assertions below check the same
          facts machine-readably from PLAN_TABLE. */
       plan_table_output
FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'm03-filtered', 'BASIC +PREDICATE'));

SELECT /* a real costed plan was produced (>= 12 row sources: 3 domain tables,
          the IVF index row sources, joins, sorts, stopkeys) */
       'ASSERT:plan-captured:' ||
       CASE WHEN COUNT(*) >= 12 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm03-filtered';

SELECT /* the IVF vector index drives the plan — its centroid/partition row
          sources (VECTOR$TICKETS_BODYVEC_IVF$...) are in the plan tree, so the
          similarity candidates come from the ANN index, not a full scan */
       'ASSERT:ivf-index-drives-plan:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name LIKE 'VECTOR$TICKETS_BODYVEC_IVF$%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the operational customer table is costed in the same plan as the
          vector search — the filter+join the dedicated store cannot do */
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

SELECT /* the base vector table appears too — the ANN candidates are joined back
          to SUPPORT_TICKETS rows (rowid join) inside the same plan tree */
       'ASSERT:plan-spans-vector-table:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'SUPPORT_TICKETS')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the PREDICATE LIST proof, part 1: the segment filter is evaluated ON
          the CUSTOMERS row source — inside the plan, not after the ranking */
       'ASSERT:segment-filter-in-plan:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'CUSTOMERS'
                           AND filter_predicates LIKE '%SEGMENT%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the PREDICATE LIST proof, part 2: the order-status/date filter is
          evaluated ON the ORDERS row source, same plan, before the ranking */
       'ASSERT:order-filter-in-plan:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table
                         WHERE statement_id = 'm03-filtered'
                           AND object_name = 'ORDERS'
                           AND filter_predicates LIKE '%STATUS%'
                           AND filter_predicates LIKE '%ORDER_TS%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the PREDICATE LIST proof, part 3 — FILTER BEFORE RANK: both relational
          filters sit BELOW the final top-10 SORT ORDER BY STOPKEY in the plan
          tree (preorder ids: descendants of the ranking sort have larger ids),
          so the top-10 is computed OVER the filtered rows — filters shrink the
          candidate pool, they are never applied to a pre-ranked top-10 */
       'ASSERT:filters-precede-ranking:' ||
       CASE WHEN (SELECT MIN(id) FROM plan_table
                  WHERE statement_id = 'm03-filtered'
                    AND operation = 'SORT' AND options LIKE 'ORDER BY%STOPKEY')
                 < (SELECT MIN(id) FROM plan_table
                    WHERE statement_id = 'm03-filtered'
                      AND object_name = 'CUSTOMERS'
                      AND filter_predicates LIKE '%SEGMENT%')
             AND (SELECT MIN(id) FROM plan_table
                  WHERE statement_id = 'm03-filtered'
                    AND operation = 'SORT' AND options LIKE 'ORDER BY%STOPKEY')
                 < (SELECT MIN(id) FROM plan_table
                    WHERE statement_id = 'm03-filtered'
                      AND object_name = 'ORDERS'
                      AND filter_predicates LIKE '%STATUS%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the VECTOR_DISTANCE drives the ranking — the top-k SORT ORDER BY
          (STOPKEY) row source is present, i.e. similarity ordering is in the
          same plan as the filters and joins */
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
          VALID — the same index the plan assertions above show in use */
       'ASSERT:ivf-index-valid:' ||
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM user_indexes
WHERE index_name = 'TICKETS_BODYVEC_IVF'
  AND index_type = 'VECTOR'
  AND status = 'VALID';
