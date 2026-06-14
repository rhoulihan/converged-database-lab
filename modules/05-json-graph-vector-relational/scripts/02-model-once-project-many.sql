SELECT /* Module 05 proof 2 -- MODEL THE DOMAIN ONCE, PROJECT THE ACCESS MANY WAYS.
   customer_profile_dv and order_dv are two different JSON-relational duality
   views over the SAME normalized customers and orders rows. Different
   hierarchies, one canonical truth, nothing stored twice -- the documents are
   generated on read and disassembled on write. This script proves, in pure SQL,
   that the two projections agree on the shared facts for one order, and that a
   base-column change is immediately visible through the view (write-through, no
   sync step). The ETag optimistic-concurrency conflict (ORA-42699) is proved in
   the companion 02-duality-etag-conflict.js through the MongoDB API, where every
   operation is its own committed statement so the stale-write rejection is
   deterministic. Order 1 is a seeded order belonging to one known customer.

   (a-1) order_dv exposes the order with a nested customer email and a total. */
       'ASSERT:order-dv-shape:' ||
       CASE WHEN JSON_VALUE(data, '$.customer.email') IS NOT NULL
                 AND JSON_VALUE(data, '$.total' RETURNING NUMBER) IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
FROM order_dv
WHERE JSON_VALUE(data, '$._id' RETURNING NUMBER) = 1;

SELECT /* (a-2) the customer email reported by order_dv (the order-centric shape)
          matches the email reported by customer_profile_dv (the customer-centric
          shape) for that order's customer. Same shared row, two projections. */
       'ASSERT:projections-agree-email:' ||
       CASE WHEN o_email = p_email AND o_email IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT (SELECT JSON_VALUE(o.data, '$.customer.email')
            FROM order_dv o
           WHERE JSON_VALUE(o.data, '$._id' RETURNING NUMBER) = 1) AS o_email,
         (SELECT JSON_VALUE(p.data, '$.email')
            FROM customer_profile_dv p
           WHERE JSON_VALUE(p.data, '$._id' RETURNING NUMBER) =
                 (SELECT o2.customer_id FROM orders o2 WHERE o2.order_id = 1)) AS p_email
  FROM dual
);

SELECT /* (a-3) the order total in order_dv equals the same order nested in
          customer_profile_dv's orders array (selected by a JSON path filter on
          orderId). Both views read one column, orders.total_amount. */
       'ASSERT:projections-agree-total:' ||
       CASE WHEN o_total = p_total AND o_total IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT (SELECT JSON_VALUE(o.data, '$.total' RETURNING NUMBER)
            FROM order_dv o
           WHERE JSON_VALUE(o.data, '$._id' RETURNING NUMBER) = 1) AS o_total,
         (SELECT JSON_VALUE(p.data, '$.orders[*]?(@.orderId == 1).total' RETURNING NUMBER)
            FROM customer_profile_dv p
           WHERE JSON_VALUE(p.data, '$._id' RETURNING NUMBER) =
                 (SELECT o3.customer_id FROM orders o3 WHERE o3.order_id = 1)) AS p_total
  FROM dual
);

UPDATE /* (b) WRITE-THROUGH -- change a base column (customers.segment) in SQL.
          The duality views own no copy, they assemble from this row, so the
          change is immediately visible through customer_profile_dv. The harness
          rolls back; the commit-free update is enough to read-your-write
          in-session. */
  customers
   SET segment = 'vip'
 WHERE customer_id = (SELECT customer_id FROM orders WHERE order_id = 1)
   AND segment <> 'vip';

SELECT /* the base-table change is reflected in the document projection with no
          sync step -- customer_profile_dv reports segment vip. One truth, the
          document is the rows. */
       'ASSERT:write-through-visible:' ||
       CASE WHEN JSON_VALUE(data, '$.segment') = 'vip'
            THEN 'PASS' ELSE 'FAIL' END
FROM customer_profile_dv
WHERE JSON_VALUE(data, '$._id' RETURNING NUMBER) =
      (SELECT customer_id FROM orders WHERE order_id = 1);
