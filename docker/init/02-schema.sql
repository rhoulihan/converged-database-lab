ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

CREATE TABLE customers (
  customer_id  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email        VARCHAR2(120) NOT NULL UNIQUE,
  full_name    VARCHAR2(100) NOT NULL,
  segment      VARCHAR2(20) DEFAULT 'standard' NOT NULL
               CHECK (segment IN ('standard','premium','vip')),
  created_at   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

CREATE TABLE products (
  product_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku          VARCHAR2(24) NOT NULL UNIQUE,
  name         VARCHAR2(120) NOT NULL,
  category     VARCHAR2(40) NOT NULL,
  list_price   NUMBER(10,2) NOT NULL,
  attributes   JSON
);

CREATE TABLE stores (
  store_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name         VARCHAR2(80) NOT NULL,
  city         VARCHAR2(60) NOT NULL,
  location     SDO_GEOMETRY
);

CREATE TABLE orders (
  order_id     NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id  NUMBER NOT NULL REFERENCES customers,
  store_id     NUMBER REFERENCES stores,
  status       VARCHAR2(16) DEFAULT 'placed' NOT NULL
               CHECK (status IN ('placed','shipped','delivered','returned')),
  order_ts     TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  total_amount NUMBER(12,2)
);

CREATE TABLE order_items (
  order_id     NUMBER NOT NULL REFERENCES orders,
  line_no      NUMBER NOT NULL,
  product_id   NUMBER NOT NULL REFERENCES products,
  qty          NUMBER NOT NULL CHECK (qty > 0),
  unit_price   NUMBER(10,2) NOT NULL,
  PRIMARY KEY (order_id, line_no)
);

CREATE TABLE devices (
  device_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fingerprint  VARCHAR2(64) NOT NULL UNIQUE
);

CREATE TABLE customer_devices (
  customer_id  NUMBER NOT NULL REFERENCES customers,
  device_id    NUMBER NOT NULL REFERENCES devices,
  first_seen   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  PRIMARY KEY (customer_id, device_id)
);

CREATE TABLE referrals (
  referrer_id  NUMBER NOT NULL REFERENCES customers,
  referee_id   NUMBER NOT NULL REFERENCES customers,
  referred_at  TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  PRIMARY KEY (referrer_id, referee_id),
  CHECK (referrer_id != referee_id)
);

CREATE TABLE support_tickets (
  ticket_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id  NUMBER NOT NULL REFERENCES customers,
  subject      VARCHAR2(200) NOT NULL,
  body         VARCHAR2(4000) NOT NULL,
  status       VARCHAR2(12) DEFAULT 'open' NOT NULL
               CHECK (status IN ('open','pending','closed')),
  opened_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  -- Deterministic 8-dim demo embeddings (seeded). Engine behavior (distance, indexes,
  -- transactions, joins) is dimension-independent; module 03 documents the optional
  -- real-model flow (DBMS_VECTOR.LOAD_ONNX_MODEL, all-MiniLM-L12-v2).
  embedding    VECTOR(8, FLOAT32)
);

-- JSON collection table: document-native surface of the same engine.
CREATE JSON COLLECTION TABLE events;

CREATE INDEX idx_orders_customer  ON orders (customer_id, order_ts);
CREATE INDEX idx_items_product    ON order_items (product_id);
CREATE INDEX idx_tickets_customer ON support_tickets (customer_id);
