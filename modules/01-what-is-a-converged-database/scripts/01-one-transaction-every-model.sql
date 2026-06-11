-- Proof 1: one ACID transaction spanning every data model, then atomic rollback.
-- (Validator runs with autocommit off and rolls back; assertions check both phases.)
-- NOTE: assertion comments ride INSIDE the SELECTs (after the keyword) because the
-- harness only fetches rows from statements whose text begins with SELECT/WITH.

INSERT INTO orders (customer_id, store_id, status, total_amount)
VALUES (1, 1, 'placed', 99.99);

INSERT INTO order_items (order_id, line_no, product_id, qty, unit_price)
VALUES ((SELECT MAX(order_id) FROM orders), 1, 1, 1, 99.99);

INSERT INTO events (data) VALUES (JSON('{"type":"order_placed","channel":"lab","note":"document write, same txn"}'));

UPDATE support_tickets
   SET status = 'pending',
       embedding = TO_VECTOR('[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5]', 8, FLOAT32)
 WHERE ticket_id = 1;

SELECT /* all four writes visible inside the SAME uncommitted transaction */
       'ASSERT:txn-relational-visible:' ||
       CASE WHEN EXISTS (SELECT 1 FROM orders WHERE total_amount = 99.99 AND status='placed') THEN 'PASS' ELSE 'FAIL' END FROM dual;
SELECT 'ASSERT:txn-document-visible:' ||
       CASE WHEN EXISTS (SELECT 1 FROM events e WHERE e.data.type.string() = 'order_placed') THEN 'PASS' ELSE 'FAIL' END FROM dual;
SELECT 'ASSERT:txn-vector-visible:' ||
       CASE WHEN (SELECT VECTOR_DISTANCE(embedding, TO_VECTOR('[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5]',8,FLOAT32), COSINE)
                  FROM support_tickets WHERE ticket_id = 1) < 0.0001 THEN 'PASS' ELSE 'FAIL' END FROM dual;

ROLLBACK;

SELECT /* and atomically gone after rollback */
       'ASSERT:rollback-relational:' ||
       CASE WHEN NOT EXISTS (SELECT 1 FROM orders WHERE total_amount = 99.99 AND status = 'placed') THEN 'PASS' ELSE 'FAIL' END FROM dual;
SELECT 'ASSERT:rollback-document:' ||
       CASE WHEN NOT EXISTS (SELECT 1 FROM events e WHERE e.data.type.string() = 'order_placed') THEN 'PASS' ELSE 'FAIL' END FROM dual;
SELECT 'ASSERT:rollback-vector:' ||
       CASE WHEN (SELECT VECTOR_DISTANCE(embedding, TO_VECTOR('[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5]',8,FLOAT32), COSINE)
                  FROM support_tickets WHERE ticket_id = 1) > 0.0001 THEN 'PASS' ELSE 'FAIL' END FROM dual;
