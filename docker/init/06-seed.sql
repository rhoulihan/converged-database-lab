ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

DECLARE
  -- All item declarations must precede subprogram bodies (PLS-00103 otherwise).
  seed    NUMBER := 42;
  -- Ticket volume. 10,000 tickets is deliberately past the point where the
  -- cost-based optimizer chooses the IVF vector index over exact full-scan
  -- distance for module 03's filtered FETCH APPROX query (the crossover
  -- arrives by roughly 3,000 rows on the Free container with fresh stats) —
  -- so the captured plan shows the index + in-plan predicate evaluation, not
  -- a toy-size full scan.
  c_tickets CONSTANT PLS_INTEGER := 10000;
  v_vec   VARCHAR2(400);
  v_norm  NUMBER;
  TYPE t_f IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
  f t_f;
  v_total NUMBER;
  v_items PLS_INTEGER;
  v_price NUMBER;
  -- Local functions cannot be referenced inside SQL (PLS-00231), so every
  -- nxt/pick value is computed into these before its INSERT.
  v_cust  PLS_INTEGER;
  v_store PLS_INTEGER;
  v_prod  PLS_INTEGER;
  v_qty   PLS_INTEGER;
  v_ts    TIMESTAMP;
  v_cat   PLS_INTEGER;
  v_body  VARCHAR2(2000);
  -- Enriched ticket-body corpus for tickets 301..c_tickets: 6 intros x 8 issue
  -- categories x 4 details x 50 products x 5 closers ~= 48k distinct bodies, so
  -- the 384-dim embeddings form real semantic clusters instead of 4 duplicated
  -- points (matters for a meaningful IVF index and hybrid-search demo).
  TYPE t_v IS TABLE OF VARCHAR2(400);
  intro   t_v := t_v('Customer reports an issue with their recent experience.',
                     'Contacting support after several attempts to resolve this alone.',
                     'Opening a ticket on behalf of the account holder.',
                     'Follow-up on an earlier conversation with the support team.',
                     'New request submitted through the help center.',
                     'Escalated from chat: the problem is still not resolved.');
  refund  t_v := t_v('The package arrived damaged and a refund is requested.',
                     'The box was crushed in transit and the item inside is damaged beyond use.',
                     'Item arrived with a cracked casing; customer asks for their money back.',
                     'Shipment was left in the rain and the contents are damaged and unusable.');
  login   t_v := t_v('Login fails with an authentication error after reset.',
                     'Password reset completed but sign-in still rejects the new credentials.',
                     'Two-factor prompt never arrives and access to the account is blocked.',
                     'Account is locked out after the security update and recovery does not work.');
  shipdl  t_v := t_v('The order has not arrived within the promised window.',
                     'Tracking has shown no movement for a week and the delivery date passed.',
                     'Carrier marked the parcel delivered but nothing has arrived.',
                     'Estimated delivery keeps slipping and no update has been provided.');
  warr    t_v := t_v('Customer asks whether the warranty covers accidental damage.',
                     'Requesting warranty service for a unit that stopped powering on.',
                     'Screen developed dead pixels within the coverage period.',
                     'Asking how to start a warranty claim for a failed component.');
  billing t_v := t_v('The statement shows a duplicate charge for a single order.',
                     'A promotional discount was not applied at checkout.',
                     'The invoice total does not match the order confirmation email.',
                     'Customer was billed after cancelling the subscription.');
  exch    t_v := t_v('Requesting an exchange for a different size of the same product.',
                     'The wrong color variant was delivered and a swap is requested.',
                     'Received a different model than the one ordered.',
                     'Asking to exchange a gift for store credit instead.');
  install t_v := t_v('The setup guide does not match the ports on the device.',
                     'Firmware update fails at forty percent every attempt.',
                     'The companion app cannot discover the device during pairing.',
                     'Installation completes but the device reboots continuously.');
  perf    t_v := t_v('The device becomes very slow after a few hours of use.',
                     'Battery drains overnight even when the unit is idle.',
                     'Audio cuts out intermittently during playback.',
                     'The connection drops whenever a second device joins.');
  closing t_v := t_v('Customer asks for a response today.',
                     'This is the second time the issue has been reported.',
                     'The customer mentions they are a long-time subscriber.',
                     'A callback number has been left on the account.',
                     'No workaround has been found so far.');
  FUNCTION nxt RETURN NUMBER IS  -- LCG: deterministic across runs
  BEGIN
    seed := MOD(seed * 1103515245 + 12345, 2147483648);
    RETURN seed / 2147483648;
  END;
  FUNCTION pick(n IN PLS_INTEGER) RETURN PLS_INTEGER IS
  BEGIN RETURN TRUNC(nxt * n) + 1; END;
  FUNCTION cat_detail(p_cat PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE p_cat
      WHEN 1 THEN refund (pick(4)) WHEN 2 THEN login(pick(4))
      WHEN 3 THEN shipdl (pick(4)) WHEN 4 THEN warr (pick(4))
      WHEN 5 THEN billing(pick(4)) WHEN 6 THEN exch (pick(4))
      WHEN 7 THEN install(pick(4)) ELSE perf(pick(4)) END;
  END;
BEGIN
  FOR i IN 1..200 LOOP
    INSERT INTO customers (email, full_name, segment)
    VALUES ('customer'||i||'@example.com', 'Customer '||i,
            CASE WHEN MOD(i,17)=0 THEN 'vip' WHEN MOD(i,5)=0 THEN 'premium' ELSE 'standard' END);
  END LOOP;

  FOR i IN 1..50 LOOP
    v_price := ROUND(10 + nxt*490, 2);
    INSERT INTO products (sku, name, category, list_price, attributes)
    VALUES ('SKU-'||LPAD(i,4,'0'), 'Product '||i,
            CASE MOD(i,5) WHEN 0 THEN 'audio' WHEN 1 THEN 'compute'
                          WHEN 2 THEN 'storage' WHEN 3 THEN 'network' ELSE 'accessory' END,
            v_price,
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
    v_cust  := pick(200);
    v_store := pick(6);
    v_ts    := TIMESTAMP '2026-01-01 00:00:00' + NUMTODSINTERVAL(TRUNC(nxt*150), 'DAY');
    INSERT INTO orders (customer_id, store_id, status, order_ts, total_amount)
    VALUES (v_cust, v_store,
            CASE WHEN MOD(i,29)=0 THEN 'returned' WHEN MOD(i,3)=0 THEN 'delivered'
                 WHEN MOD(i,2)=0 THEN 'shipped' ELSE 'placed' END,
            v_ts, 0);
    FOR j IN 1..v_items LOOP
      v_price := ROUND(10 + nxt*490, 2);
      v_prod  := pick(50);
      v_qty   := pick(3);
      INSERT INTO order_items (order_id, line_no, product_id, qty, unit_price)
      VALUES (i, j, v_prod, v_qty, v_price);
      v_total := v_total + v_price;
    END LOOP;
    UPDATE orders SET total_amount = ROUND(v_total,2) WHERE order_id = i;
  END LOOP;

  -- Tickets 1..300: the ORIGINAL 4-template corpus, byte-for-byte (module 01's
  -- ticket #1 proofs and module 03's read-after-write probe depend on ticket #1
  -- keeping its "Login fails with an authentication error after reset." body).
  FOR i IN 1..300 LOOP
    v_norm := 0;
    FOR d IN 1..8 LOOP f(d) := nxt*2 - 1; v_norm := v_norm + f(d)*f(d); END LOOP;
    v_norm := SQRT(v_norm);
    v_vec := '[';
    FOR d IN 1..8 LOOP
      v_vec := v_vec || TO_CHAR(ROUND(f(d)/v_norm, 6),'FM990.999999') || CASE WHEN d<8 THEN ',' END;
    END LOOP;
    v_vec := v_vec || ']';
    v_cust := pick(200);
    INSERT INTO support_tickets (customer_id, subject, body, status, embedding)
    VALUES (v_cust,
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

  -- Tickets 301..c_tickets: the enriched scaled corpus. The LCG is re-seeded to
  -- a fixed value here so this block is deterministic regardless of how the
  -- upstream seeding evolves — same bodies on every fresh build.
  seed := 342;
  FOR i IN 301..c_tickets LOOP
    v_cat  := pick(8);
    v_cust := pick(200);
    v_body := intro(pick(6))||' '||cat_detail(v_cat)||
              ' Relates to Product '||pick(50)||'. '||closing(pick(5));
    v_norm := 0;
    FOR d IN 1..8 LOOP f(d) := nxt*2 - 1; v_norm := v_norm + f(d)*f(d); END LOOP;
    v_norm := SQRT(v_norm);
    v_vec := '[';
    FOR d IN 1..8 LOOP
      v_vec := v_vec || TO_CHAR(ROUND(f(d)/v_norm, 6),'FM990.999999') || CASE WHEN d<8 THEN ',' END;
    END LOOP;
    v_vec := v_vec || ']';
    INSERT INTO support_tickets (customer_id, subject, body, status, embedding)
    VALUES (v_cust,
            CASE v_cat WHEN 1 THEN 'Refund request for damaged item'
                       WHEN 2 THEN 'Cannot sign in after password reset'
                       WHEN 3 THEN 'Shipping delay on recent order'
                       WHEN 4 THEN 'Warranty question for product'
                       WHEN 5 THEN 'Billing discrepancy on statement'
                       WHEN 6 THEN 'Exchange request for recent order'
                       WHEN 7 THEN 'Device setup and installation issue'
                       ELSE 'Performance problem with product' END || ' #'||i,
            v_body,
            CASE WHEN MOD(i,3)=0 THEN 'closed' WHEN MOD(i,7)=0 THEN 'pending' ELSE 'open' END,
            TO_VECTOR(v_vec, 8, FLOAT32));
  END LOOP;
  COMMIT;
END;
/
