ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

DECLARE
  seed   NUMBER := 42;
  FUNCTION nxt RETURN NUMBER IS  -- LCG: deterministic across runs
  BEGIN
    seed := MOD(seed * 1103515245 + 12345, 2147483648);
    RETURN seed / 2147483648;
  END;
  FUNCTION pick(n IN PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN RETURN TRUNC(nxt * n) + 1; END;
  v_vec   VARCHAR2(400);
  v_norm  NUMBER;
  TYPE t_f IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  f t_f;
  v_total NUMBER;
  v_items PLS_INTEGER;
  v_price NUMBER;
BEGIN
  FOR i IN 1..200 LOOP
    INSERT INTO customers (email, full_name, segment)
    VALUES ('customer'||i||'@example.com', 'Customer '||i,
            CASE WHEN MOD(i,17)=0 THEN 'vip' WHEN MOD(i,5)=0 THEN 'premium' ELSE 'standard' END);
  END LOOP;

  FOR i IN 1..50 LOOP
    INSERT INTO products (sku, name, category, list_price, attributes)
    VALUES ('SKU-'||LPAD(i,4,'0'), 'Product '||i,
            CASE MOD(i,5) WHEN 0 THEN 'audio' WHEN 1 THEN 'compute'
                          WHEN 2 THEN 'storage' WHEN 3 THEN 'network' ELSE 'accessory' END,
            ROUND(10 + nxt*490, 2),
            JSON('{"color":"'||CASE MOD(i,3) WHEN 0 THEN 'black' WHEN 1 THEN 'silver' ELSE 'blue' END||
                 '","warrantyMonths":'||(12*(MOD(i,3)+1))||'}'));
  END LOOP;

  INSERT INTO stores (name, city, location) VALUES ('Downtown Austin','Austin', SDO_GEOMETRY(2001,4326,SDO_POINT_TYPE(-97.7431,30.2672,NULL),NULL,NULL));
  INSERT INTO stores (name, city, location) VALUES ('Domain North','Austin',    SDO_GEOMETRY(2001,4326,SDO_POINT_TYPE(-97.7220,30.4019,NULL),NULL,NULL));
  INSERT INTO stores (name, city, location) VALUES ('Frisco','Dallas',          SDO_GEOMETRY(2001,4326,SDO_POINT_TYPE(-96.8236,33.1507,NULL),NULL,NULL));
  INSERT INTO stores (name, city, location) VALUES ('Galleria','Houston',       SDO_GEOMETRY(2001,4326,SDO_POINT_TYPE(-95.4613,29.7392,NULL),NULL,NULL));
  INSERT INTO stores (name, city, location) VALUES ('Pearl','San Antonio',      SDO_GEOMETRY(2001,4326,SDO_POINT_TYPE(-98.4815,29.4426,NULL),NULL,NULL));
  INSERT INTO stores (name, city, location) VALUES ('Online','-',               NULL);

  FOR i IN 1..40 LOOP
    INSERT INTO devices (fingerprint) VALUES (RAWTOHEX(UTL_RAW.CAST_FROM_NUMBER(1000+i)));
  END LOOP;

  -- Device links: ring devices 1-5 shared by clique customers (fraud pattern),
  -- the rest one device per ~5 customers.
  FOR i IN 1..200 LOOP
    IF i <= 15 THEN
      INSERT INTO customer_devices (customer_id, device_id) VALUES (i, MOD(i,5)+1);
    ELSE
      INSERT INTO customer_devices (customer_id, device_id) VALUES (i, 6 + MOD(i,34));
    END IF;
  END LOOP;

  -- Referral chains + one cycle 10→11→12→13→10
  FOR i IN 1..60 LOOP
    INSERT INTO referrals (referrer_id, referee_id) VALUES (i, i+60);
  END LOOP;
  INSERT INTO referrals (referrer_id, referee_id) VALUES (10,11);
  INSERT INTO referrals (referrer_id, referee_id) VALUES (11,12);
  INSERT INTO referrals (referrer_id, referee_id) VALUES (12,13);
  INSERT INTO referrals (referrer_id, referee_id) VALUES (13,10);

  FOR i IN 1..1000 LOOP
    v_items := pick(4);
    v_total := 0;
    INSERT INTO orders (customer_id, store_id, status, order_ts, total_amount)
    VALUES (pick(200), pick(6),
            CASE WHEN MOD(i,29)=0 THEN 'returned' WHEN MOD(i,3)=0 THEN 'delivered'
                 WHEN MOD(i,2)=0 THEN 'shipped' ELSE 'placed' END,
            TIMESTAMP '2026-01-01 00:00:00' + NUMTODSINTERVAL(TRUNC(nxt*150), 'DAY'), 0);
    FOR j IN 1..v_items LOOP
      v_price := ROUND(10 + nxt*490, 2);
      INSERT INTO order_items (order_id, line_no, product_id, qty, unit_price)
      VALUES (i, j, pick(50), pick(3), v_price);
      v_total := v_total + v_price;
    END LOOP;
    UPDATE orders SET total_amount = ROUND(v_total,2) WHERE order_id = i;
  END LOOP;

  FOR i IN 1..300 LOOP
    v_norm := 0;
    FOR d IN 1..8 LOOP f(d) := nxt*2 - 1; v_norm := v_norm + f(d)*f(d); END LOOP;
    v_norm := SQRT(v_norm);
    v_vec := '[';
    FOR d IN 1..8 LOOP
      v_vec := v_vec || TO_CHAR(ROUND(f(d)/v_norm, 6),'FM990.999999') || CASE WHEN d<8 THEN ',' END;
    END LOOP;
    v_vec := v_vec || ']';
    INSERT INTO support_tickets (customer_id, subject, body, status, embedding)
    VALUES (pick(200),
            CASE MOD(i,4) WHEN 0 THEN 'Refund request for damaged item'
                          WHEN 1 THEN 'Cannot sign in after password reset'
                          WHEN 2 THEN 'Shipping delay on recent order'
                          ELSE 'Warranty question for product' END || ' #'||i,
            'Ticket '||i||' body: customer reports an issue with their recent experience. '||
            CASE MOD(i,4) WHEN 0 THEN 'The package arrived damaged and a refund is requested.'
                          WHEN 1 THEN 'Login fails with an authentication error after reset.'
                          WHEN 2 THEN 'The order has not arrived within the promised window.'
                          ELSE 'Customer asks whether the warranty covers accidental damage.' END,
            CASE WHEN MOD(i,3)=0 THEN 'closed' WHEN MOD(i,7)=0 THEN 'pending' ELSE 'open' END,
            TO_VECTOR(v_vec, 8, FLOAT32));
  END LOOP;
  COMMIT;
END;
/
