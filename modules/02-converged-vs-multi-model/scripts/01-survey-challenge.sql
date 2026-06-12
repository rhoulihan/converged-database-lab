DECLARE /* Module 02 proof 1: the academic literature's canonical multi-model
   query, answered in ONE standard SQL statement.

   Lu & Holubova, "Multi-model Databases: A New Journey to Handle the Variety
   of Data," ACM Computing Surveys 52(3) Art. 55 (2019), Fig. 1 poses an
   e-commerce challenge spanning relational, graph, and document data:
   customers Mary (credit limit 5000), John (3000), William (2000); a "knows"
   social graph; orders as JSON documents. The Fig. 1 caption query: "Return
   all product_no which are ordered by a friend of a customer whose
   credit_limit>3000". Published result: ['2724f','3424g']. Their Fig. 2
   solves it in ArangoDB AQL and OrientDB SQL — each a proprietary language on
   its own engine. Here it is one standard SQL statement: GRAPH_TABLE
   (SQL/PGQ, ISO/IEC 9075-16) + JSON_TABLE (SQL/JSON, SQL:2016) + a relational
   predicate, planned by one cost-based optimizer.

   DATASET NOTE: the survey publishes the customers, the query, and the
   result, but not the complete knows-edge topology or full order documents.
   The rows below are CONSTRUCTED as the minimal dataset consistent with the
   survey's published inputs and published result: Mary (the only customer
   with credit_limit > 3000) knows John and William; John's order contains
   product 2724f, William's contains 3424g. Order_no / Product_Name / Price
   values are likewise constructed placeholders in the survey's document
   shape.

   DDL WARNING: this script intentionally performs DDL, and DDL AUTOCOMMITS —
   the harness rollback cannot undo it. Cleanup is therefore explicit: every
   module-local object (smm_ prefix, "survey multi-model") is dropped before
   the script ends, and assertions verify the drops. This first block is an
   idempotence guard: remove any smm_ leftovers from a previously interrupted
   run. */
  PROCEDURE drop_if_exists(p_stmt VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_stmt;
  EXCEPTION
    WHEN OTHERS THEN NULL; /* object absent — nothing to clean */
  END;
BEGIN
  drop_if_exists('DROP PROPERTY GRAPH smm_social');
  drop_if_exists('DROP TABLE smm_orders PURGE');
  drop_if_exists('DROP TABLE smm_knows PURGE');
  drop_if_exists('DROP TABLE smm_customers PURGE');
END;
/

DELETE /* idempotence guard for the EXPLAIN PLAN below: clear any prior rows
   for this statement id */
FROM plan_table WHERE statement_id = 'm02-survey';

CREATE TABLE smm_customers (
  customer_id  NUMBER PRIMARY KEY,
  name         VARCHAR2(40) NOT NULL,
  credit_limit NUMBER NOT NULL
);

CREATE TABLE smm_knows (
  knower_id NUMBER NOT NULL REFERENCES smm_customers,
  known_id  NUMBER NOT NULL REFERENCES smm_customers,
  PRIMARY KEY (knower_id, known_id)
);

CREATE TABLE smm_orders (
  order_id    NUMBER PRIMARY KEY,
  customer_id NUMBER NOT NULL REFERENCES smm_customers,
  doc         JSON NOT NULL
);

CREATE PROPERTY GRAPH smm_social
  VERTEX TABLES (
    smm_customers KEY (customer_id)
      PROPERTIES (customer_id, name, credit_limit)
  )
  EDGE TABLES (
    smm_knows KEY (knower_id, known_id)
      SOURCE KEY (knower_id) REFERENCES smm_customers (customer_id)
      DESTINATION KEY (known_id) REFERENCES smm_customers (customer_id)
  );

INSERT INTO smm_customers VALUES (1, 'Mary', 5000);

INSERT INTO smm_customers VALUES (2, 'John', 3000);

INSERT INTO smm_customers VALUES (3, 'William', 2000);

INSERT INTO smm_knows VALUES (1, 2);

INSERT INTO smm_knows VALUES (1, 3);

INSERT INTO smm_orders VALUES (1, 2,
  JSON('{"Order_no":"34e5e759","Orderlines":[{"Product_no":"2724f","Product_Name":"Toy","Price":66}]}'));

INSERT INTO smm_orders VALUES (2, 3,
  JSON('{"Order_no":"0c6df508","Orderlines":[{"Product_no":"3424g","Product_Name":"Book","Price":40}]}'));

SELECT DISTINCT jt.product_no /* THE statement — the survey's Fig. 1 query in
       one standard SQL statement: graph hop via SQL/PGQ GRAPH_TABLE
       (ISO/IEC 9075-16), document unnest via SQL/JSON JSON_TABLE (SQL:2016),
       relational predicate on credit_limit — one engine, one optimizer */
FROM GRAPH_TABLE (smm_social
       MATCH (c IS smm_customers) -[IS smm_knows]-> (f IS smm_customers)
       WHERE c.credit_limit > 3000
       COLUMNS (f.customer_id AS friend_id)) g
JOIN smm_orders o ON o.customer_id = g.friend_id
CROSS JOIN JSON_TABLE (o.doc, '$.Orderlines[*]'
       COLUMNS (product_no VARCHAR2(16) PATH '$.Product_no')) jt;

SELECT /* the result set equals the survey's published answer EXACTLY:
          two distinct products, and both are theirs */
       'ASSERT:survey-result-exact:' ||
       CASE WHEN COUNT(*) = 2
             AND COUNT(CASE WHEN product_no = '2724f' THEN 1 END) = 1
             AND COUNT(CASE WHEN product_no = '3424g' THEN 1 END) = 1
            THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT DISTINCT jt.product_no
  FROM GRAPH_TABLE (smm_social
         MATCH (c IS smm_customers) -[IS smm_knows]-> (f IS smm_customers)
         WHERE c.credit_limit > 3000
         COLUMNS (f.customer_id AS friend_id)) g
  JOIN smm_orders o ON o.customer_id = g.friend_id
  CROSS JOIN JSON_TABLE (o.doc, '$.Orderlines[*]'
         COLUMNS (product_no VARCHAR2(16) PATH '$.Product_no')) jt
);

EXPLAIN PLAN SET STATEMENT_ID = 'm02-survey' FOR
SELECT DISTINCT jt.product_no
FROM GRAPH_TABLE (smm_social
       MATCH (c IS smm_customers) -[IS smm_knows]-> (f IS smm_customers)
       WHERE c.credit_limit > 3000
       COLUMNS (f.customer_id AS friend_id)) g
JOIN smm_orders o ON o.customer_id = g.friend_id
CROSS JOIN JSON_TABLE (o.doc, '$.Orderlines[*]'
       COLUMNS (product_no VARCHAR2(16) PATH '$.Product_no')) jt;

SELECT /* a real costed plan was produced */ 'ASSERT:plan-captured:' ||
       CASE WHEN COUNT(*) >= 4 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm02-survey';

SELECT /* the graph pattern lowers to ordinary row sources over the edge
          table — the CBO reads SMM_KNOWS through its PK index, whose name is
          system-generated, so resolve it via user_indexes */
       'ASSERT:plan-spans-graph:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm02-survey'
                           AND (p.object_name = 'SMM_KNOWS'
                                OR p.object_name IN (SELECT i.index_name
                                                     FROM user_indexes i
                                                     WHERE i.table_name = 'SMM_KNOWS')))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the relational vertex table is costed in the same plan */
       'ASSERT:plan-spans-relational:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm02-survey'
                           AND (p.object_name = 'SMM_CUSTOMERS'
                                OR p.object_name IN (SELECT i.index_name
                                                     FROM user_indexes i
                                                     WHERE i.table_name = 'SMM_CUSTOMERS')))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the JSON order documents are costed in the same plan */
       'ASSERT:plan-spans-document:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm02-survey'
                           AND (p.object_name = 'SMM_ORDERS'
                                OR p.object_name IN (SELECT i.index_name
                                                     FROM user_indexes i
                                                     WHERE i.table_name = 'SMM_ORDERS')))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the document unnest appears as a JSONTABLE EVALUATION row source
          inside the same plan tree */
       'ASSERT:plan-evaluates-json:' ||
       CASE WHEN EXISTS (SELECT 1 FROM plan_table p
                         WHERE p.statement_id = 'm02-survey'
                           AND p.operation LIKE 'JSONTABLE%')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* every row source above belongs to a single plan tree */
       'ASSERT:one-plan-tree:' ||
       CASE WHEN COUNT(DISTINCT plan_id) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm02-survey';

DELETE /* EXPLAIN PLAN rows are transactional, but the DROP statements below
   autocommit whatever is pending — delete the plan rows first so the implicit
   commit leaves plan_table unchanged */
FROM plan_table WHERE statement_id = 'm02-survey';

DROP PROPERTY GRAPH smm_social;

DROP TABLE smm_orders PURGE;

DROP TABLE smm_knows PURGE;

DROP TABLE smm_customers PURGE;

SELECT /* explicit cleanup verified: no module table survives */
       'ASSERT:smm-tables-dropped:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM user_tables WHERE table_name LIKE 'SMM\_%' ESCAPE '\';

SELECT /* explicit cleanup verified: the module property graph is gone */
       'ASSERT:smm-graph-dropped:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM user_property_graphs WHERE graph_name = 'SMM_SOCIAL';

SELECT /* the plan rows were deleted before the autocommitting DDL, so
          plan_table is left unchanged too */
       'ASSERT:plan-table-clean:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM plan_table WHERE statement_id = 'm02-survey';
