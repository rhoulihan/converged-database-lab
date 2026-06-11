ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- SQL/PGQ property graph over the SAME relational tables. No export, no sync.
CREATE PROPERTY GRAPH customer_graph
  VERTEX TABLES (
    customers KEY (customer_id)
      PROPERTIES (customer_id, email, full_name, segment),
    devices KEY (device_id)
      PROPERTIES (device_id, fingerprint)
  )
  EDGE TABLES (
    customer_devices KEY (customer_id, device_id)
      SOURCE KEY (customer_id) REFERENCES customers (customer_id)
      DESTINATION KEY (device_id) REFERENCES devices (device_id)
      PROPERTIES (first_seen),
    referrals KEY (referrer_id, referee_id)
      SOURCE KEY (referrer_id) REFERENCES customers (customer_id)
      DESTINATION KEY (referee_id) REFERENCES customers (customer_id)
      PROPERTIES (referred_at)
  );
