ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Customer profile: one document per customer, orders + items nested.
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW customer_profile_dv AS
SELECT JSON {
  '_id'      : c.customer_id,
  'email'    : c.email,
  'fullName' : c.full_name,
  'segment'  : c.segment WITH UPDATE,
  'orders'   : [ SELECT JSON {
                   'orderId' : o.order_id,
                   'status'  : o.status WITH UPDATE,
                   'orderTs' : o.order_ts,
                   'total'   : o.total_amount,
                   'items'   : [ SELECT JSON {
                                   'line'      : oi.line_no,
                                   'productId' : oi.product_id,
                                   'qty'       : oi.qty,
                                   'unitPrice' : oi.unit_price }
                                 FROM order_items oi WITH INSERT UPDATE DELETE
                                 WHERE oi.order_id = o.order_id ]}
                 FROM orders o WITH INSERT UPDATE DELETE
                 WHERE o.customer_id = c.customer_id ]
} FROM customers c WITH INSERT UPDATE DELETE;

-- Order-centric shape over the SAME rows: second projection of one truth.
CREATE OR REPLACE JSON RELATIONAL DUALITY VIEW order_dv AS
SELECT JSON {
  '_id'      : o.order_id,
  'status'   : o.status WITH UPDATE,
  'orderTs'  : o.order_ts,
  'total'    : o.total_amount WITH UPDATE,
  'customer' : ( SELECT JSON { 'customerId' : c.customer_id,
                               'email'      : c.email,
                               'fullName'   : c.full_name }
                 FROM customers c WITH NOUPDATE
                 WHERE c.customer_id = o.customer_id ),
  'items'    : [ SELECT JSON { 'line'      : oi.line_no,
                               'productId' : oi.product_id,
                               'qty'       : oi.qty,
                               'unitPrice' : oi.unit_price }
                 FROM order_items oi WITH INSERT UPDATE DELETE
                 WHERE oi.order_id = o.order_id ]
} FROM orders o WITH INSERT UPDATE DELETE;
