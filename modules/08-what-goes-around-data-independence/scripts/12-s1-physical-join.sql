-- S1 physical variants (A): how close do other physical designs bring the join?
-- Read one order and all of its lines by key, eight ways, over the same
-- interleaved data:
--   doc  : one document from a JSON collection table, found through its _id index
--   heap : heap line table, single-column order_id index (S1's interleaved join)
--   cov  : heap line table plus a covering index (order_id, line_id, sku, qty),
--          so the lines are read from the index alone
--   iot  : index-organized line table, primary key (order_id, line_id), so each
--          order's lines sit together in the primary key's leaf blocks
--   iotc : the iot with key compression (COMPRESS 1 on order_id), moved online
--          after the load so its leaf blocks are packed
--   clu  : index cluster on order_id holding both the order and line tables, so
--          an order and its lines share cluster blocks. As measured, the plan
--          makes two index probes: the order row through its own primary key
--          index, then the lines through the cluster index
--   hash : hash cluster on order_id holding both tables: both are reached by
--          hashing the key (TABLE ACCESS HASH), with no index probe
--   dv   : a duality view over the iot variant (a join, measured as one)
-- Every line table is loaded in the same interleaved order (S1's recipe), so the
-- physical design, not the load order, does any clustering.
-- Logical reads: the second execution of each read, as in S1, less the meter's
-- own overhead. CPU and elapsed: m08_meter.measure_repeat (20 runs) for k = 100
-- and k = 1000 only; smaller reads are below its 1 cs resolution.
-- The heap baseline is checked against S1's own interleaved numbers, which
-- 10-s1-read-by-key.sql leaves in m08_metrics as 'ref:s1-*' rows.
-- Warning: those rows live in the session table, and the validator reconnects
-- after any .sh script, so a .sh script numbered between 10 and 12 would lose
-- them and break that cross-check.
--
-- Twenty targets per k (fairness arms). One target per k can be a lucky or an
-- unlucky one, so the load also holds 19 more target orders at every k, in
-- the same interleaved style (each in its own slot of the round-robin). Every
-- reader is measured on all 20 targets at every k; the median, min and max
-- are recorded (s1a-<reader>-k<k>-t20-*). Three more readers join them:
--   hashk : the join in a hash cluster sized for k. The fixed SIZE 512
--           cluster above suits orders of about 10 lines; a larger order
--           chains blocks onto its key. So there is one more hash cluster per
--           k, SIZE computed from the bytes of the k-line order (plus 10%,
--           rounded up to 256 bytes, at most 8192), holding the full data
--           (every order and line, the lines in the same interleaved order)
--           with HASHKEYS 22000, as for hash. At k = 1000 the cap holds about
--           a quarter of the order (31,915 bytes), so it still chains blocks.
--   hdv   : a duality view over that k-sized hash cluster's two tables
--   hdoc  : the order document in a single-table hash cluster keyed by order
--           id, read by key and serialized like doc. On this build a
--           clustered table takes neither a JSON nor a LOB column, so the
--           document is stored as OSON in a RAW(2000) column (checked IS JSON
--           FORMAT OSON), the largest binary column a cluster accepts. Only
--           orders whose OSON fits in 2,000 bytes can be stored: the k = 1 and
--           k = 10 targets (and the 10-line fillers); a 100-line order does
--           not fit. One such cluster per k (k = 1 and 10), sized as for
--           hashk, holding every order document that fits (all but the
--           k = 100 and k = 1000 targets), HASHKEYS 22000.
-- CPU, elapsed and bytes per reader: m08_meter.measure_us (v$sql growth over
-- 100 runs, microseconds; see 00-meter.sql), for every target.

-- Clean up anything left by an earlier, interrupted run.
drop view if exists m08a_i_dv;
drop table if exists m08a_h_line purge;
drop table if exists m08a_v_line purge;
drop table if exists m08a_i_line purge;
drop table if exists m08a_k_line purge;
drop table if exists m08a_ord purge;
drop table if exists m08a_doc purge;
drop table if exists m08a_line_plan purge;
drop table if exists m08a_targets purge;
BEGIN
  FOR v IN (SELECT view_name FROM user_views WHERE view_name LIKE 'M08A\_HK%' ESCAPE '\') LOOP
    EXECUTE IMMEDIATE 'DROP VIEW ' || v.view_name;
  END LOOP;
  FOR c IN (SELECT cluster_name FROM user_clusters WHERE cluster_name LIKE 'M08A\_%' ESCAPE '\') LOOP
    EXECUTE IMMEDIATE 'DROP CLUSTER ' || c.cluster_name || ' INCLUDING TABLES CASCADE CONSTRAINTS';
  END LOOP;
END;
/
delete from m08_metrics where name like 's1a-%' or name like 'tmp:s1a-%';

-- ===== Projections =====

-- The order table shared by the heap, covering and iot variants.
create table m08a_ord (
  id       number primary key,
  customer varchar2(40),
  status   varchar2(12)
);

-- heap: exactly S1's line table.
create table m08a_h_line (
  line_id  varchar2(36) primary key,
  order_id number not null references m08a_ord,
  sku      varchar2(20),
  qty      number
);
create index m08a_h_line_order_ix on m08a_h_line (order_id);

-- cov: the same heap table; the order_id index also carries every column the
-- reader needs, so the reader never has to visit the table.
create table m08a_v_line (
  line_id  varchar2(36) primary key,
  order_id number not null references m08a_ord,
  sku      varchar2(20),
  qty      number
);
create index m08a_v_line_cov_ix on m08a_v_line (order_id, line_id, sku, qty);

-- iot: the rows live in the primary key index, sorted by (order_id, line_id).
create table m08a_i_line (
  order_id number not null references m08a_ord,
  line_id  varchar2(36),
  sku      varchar2(20),
  qty      number,
  constraint m08a_i_line_pk primary key (order_id, line_id)
) organization index;

-- iotc: the same IOT with the leading key column (order_id) compressed, so
-- each leaf block stores each order_id once. It is moved online after the
-- load (below) so the leaves are not left half empty by block splits.
create table m08a_k_line (
  order_id number not null references m08a_ord,
  line_id  varchar2(36),
  sku      varchar2(20),
  qty      number,
  constraint m08a_k_line_pk primary key (order_id, line_id)
) organization index compress 1;

-- clu: an index cluster keyed on order_id. SIZE 512 bytes per key: a typical
-- 10-line order is about 10 line rows of roughly 40 bytes plus a header row, so
-- one key fits in about 500 bytes and an 8 KB block holds about 15 orders.
-- Larger orders chain extra blocks onto their key.
create cluster m08a_clu (order_id number) size 512;
create index m08a_clu_ix on cluster m08a_clu;

create table m08a_c_ord (
  id       number primary key,
  customer varchar2(40),
  status   varchar2(12)
) cluster m08a_clu (id);

create table m08a_c_line (
  line_id  varchar2(36) primary key,
  order_id number not null references m08a_c_ord,
  sku      varchar2(20),
  qty      number
) cluster m08a_clu (order_id);

-- hash: a hash cluster keyed on order_id. HASHKEYS 22000 is about one hash
-- key per order (the data has about 20,000 orders, recorded as s1a-orders;
-- Oracle rounds HASHKEYS up to a prime).
-- SIZE 512 bytes per key, as for the index cluster. Larger orders chain extra
-- blocks onto their key.
create cluster m08a_hclu (order_id number) size 512 hashkeys 22000;

create table m08a_hc_ord (
  id       number primary key,
  customer varchar2(40),
  status   varchar2(12)
) cluster m08a_hclu (id);

create table m08a_hc_line (
  line_id  varchar2(36) primary key,
  order_id number not null references m08a_hc_ord,
  sku      varchar2(20),
  qty      number
) cluster m08a_hclu (order_id);

create json collection table m08a_doc;

-- ===== Data =====
-- The targets: 20 per k. Target 1 of each k is S1's (ids 900011..900014, slots
-- 0..3, exactly as before). Targets 2..20 have ids 901000 + 100 * kidx + j and
-- slots 4..79, four k values side by side.
create table m08a_targets as
  select k.k, k.kidx, j.j,
         case when j.j = 1 then 900011 + k.kidx else 901000 + 100 * k.kidx + j.j end id,
         case when j.j = 1 then k.kidx else 4 + (j.j - 2) * 4 + k.kidx end slot
    from (select level - 1 kidx, power(10, level - 1) k from dual connect by level <= 4) k,
         (select level j from dual connect by level <= 20) j;

-- S1's line plan, without S1's clustered targets (this script measures the
-- interleaved layout only). Phase 1: 2,000 filler orders of 10 lines, each
-- order's lines together. Phase 2: 200 slots, 1,000 rounds; each round inserts
-- one line for every slot. Slots 0..79 hold the targets (above); every other
-- slot, and a target slot once its target is complete, holds a stream of
-- 10-line filler orders, so 200 orders stay open for the whole phase.
create table m08a_line_plan as
with t as (select slot, k, id from m08a_targets),
clustered as (
  select o.id order_id, n, 1 phase,
         case when o.id <= 1000 then o.id else o.id + 4 end pos1, n pos2
    from (select level id from dual connect by level <= 2000) o,
         (select level - 1 n from dual connect by level <= 10)
),
rr as (
  select r.r, s.s, t.k, t.id
    from (select level - 1 r from dual connect by level <= 1000) r,
         (select level - 1 s from dual connect by level <= 200) s
         left join t on t.slot = s.s
),
interleaved as (
  select case when rr.k is not null and rr.r < rr.k then rr.id
              else 100000 + rr.s * 1000 + floor((rr.r - nvl(rr.k, 0)) / 10) end order_id,
         case when rr.k is not null and rr.r < rr.k then rr.r
              else mod(rr.r - nvl(rr.k, 0), 10) end n,
         2 phase, rr.r pos1, rr.s pos2
    from rr
)
select order_id, n, phase, pos1, pos2 from clustered
union all
select order_id, n, phase, pos1, pos2 from interleaved;

insert into m08a_ord (id, customer, status)
  select order_id, 'customer-' || mod(order_id, 500), 'OPEN'
    from (select distinct order_id from m08a_line_plan);

insert into m08a_c_ord (id, customer, status)
  select id, customer, status from m08a_ord;

insert into m08a_hc_ord (id, customer, status)
  select id, customer, status from m08a_ord;

-- Every line table gets the same rows in the same (plan) order.
insert into m08a_h_line (line_id, order_id, sku, qty)
  select 'L' || order_id || '-' || n, order_id,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

insert into m08a_v_line (line_id, order_id, sku, qty)
  select 'L' || order_id || '-' || n, order_id,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

insert into m08a_i_line (order_id, line_id, sku, qty)
  select order_id, 'L' || order_id || '-' || n,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

insert into m08a_c_line (line_id, order_id, sku, qty)
  select 'L' || order_id || '-' || n, order_id,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

insert into m08a_k_line (order_id, line_id, sku, qty)
  select order_id, 'L' || order_id || '-' || n,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

insert into m08a_hc_line (line_id, order_id, sku, qty)
  select 'L' || order_id || '-' || n, order_id,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08a_line_plan
   order by phase, pos1, pos2;

-- The document projection carries the same content: the order and all its lines.
insert into m08a_doc (data)
  select json {'_id': o.id, 'customer': o.customer, 'status': o.status,
               'lines': (select json_arrayagg(json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty}
                                              order by l.line_id returning json)
                           from m08a_h_line l where l.order_id = o.id)}
    from m08a_ord o;

commit;

-- Pack the compressed IOT's leaves after the interleaved load.
alter table m08a_k_line move online;

insert into m08_metrics (name, value)
  select 's1a-orders', count(*) from m08a_ord;

-- ===== Fairness arms: hash clusters sized for each k =====
-- For each k: the bytes of target 1 (its order row and its line rows, from
-- vsize plus a few bytes of row overhead), plus 10%, rounded up to 256 bytes,
-- at most 8192 (one block). One cluster per k, HASHKEYS 22000, holding the
-- full data (every order row and line row, the lines in the same interleaved
-- order), and a duality view over its two tables. Then, for k = 1 and 10, a
-- single-table hash cluster holding every order document whose OSON fits in
-- 2,000 bytes, sized from target 1's OSON bytes the same way.
DECLARE
  sz NUMBER;
  ob NUMBER;
  PROCEDURE ddl(p VARCHAR2) IS BEGIN EXECUTE IMMEDIATE p; END;
BEGIN
  FOR t IN (SELECT k, id FROM m08a_targets WHERE j = 1 ORDER BY k) LOOP
    SELECT (SELECT SUM(nvl(vsize(id), 0) + nvl(vsize(customer), 0) + nvl(vsize(status), 0) + 6)
              FROM m08a_ord WHERE id = t.id)
         + (SELECT SUM(nvl(vsize(line_id), 0) + nvl(vsize(order_id), 0) + nvl(vsize(sku), 0)
                       + nvl(vsize(qty), 0) + 7)
              FROM m08a_h_line WHERE order_id = t.id)
      INTO sz FROM dual;
    m08_meter.record('s1a-k' || t.k || '-order-bytes', sz);
    sz := LEAST(8192, CEIL(1.1 * sz / 256) * 256);
    m08_meter.record('s1a-hashk-k' || t.k || '-size', sz);
    ddl('create cluster m08a_hk' || t.k || ' (order_id number) size ' || sz || ' hashkeys 22000');
    ddl('create table m08a_hk' || t.k || '_ord (id number primary key, customer varchar2(40),'
        || ' status varchar2(12)) cluster m08a_hk' || t.k || ' (id)');
    ddl('create table m08a_hk' || t.k || '_line (line_id varchar2(36) primary key,'
        || ' order_id number not null references m08a_hk' || t.k || '_ord, sku varchar2(20),'
        || ' qty number) cluster m08a_hk' || t.k || ' (order_id)');
    ddl('insert into m08a_hk' || t.k || '_ord (id, customer, status)'
        || ' select id, customer, status from m08a_ord');
    ddl('insert into m08a_hk' || t.k || '_line (line_id, order_id, sku, qty)'
        || ' select ''L'' || order_id || ''-'' || n, order_id,'
        || ' ''SKU-'' || lpad(mod(order_id * 7 + n, 5000), 4, ''0''), mod(n, 5) + 1'
        || ' from m08a_line_plan order by phase, pos1, pos2');
    COMMIT;
    EXECUTE IMMEDIATE 'select count(*) from m08a_hk' || t.k || '_ord' INTO ob;
    m08_meter.record('s1a-hashk-k' || t.k || '-orders', ob);
    ddl('create json relational duality view m08a_hk' || t.k || '_dv as'
        || ' select json {''_id'' : o.id, ''customer'' : o.customer, ''status'' : o.status,'
        || ' ''lines'' : [select json {''lineId'' : l.line_id, ''sku'' : l.sku, ''qty'' : l.qty}'
        || ' from m08a_hk' || t.k || '_line l where l.order_id = o.id]}'
        || ' from m08a_hk' || t.k || '_ord o');
  END LOOP;

  FOR t IN (SELECT k, id FROM m08a_targets WHERE j = 1 ORDER BY k) LOOP
    -- The OSON size of target 1's document, at every k (the reason k = 100
    -- and 1000 are not stored).
    SELECT dbms_lob.getlength(json_object('_id' value o.id, 'customer' value o.customer,
                                          'status' value o.status,
                                          'lines' value (SELECT json_arrayagg(json_object(
                                                                  'lineId' value l.line_id,
                                                                  'sku' value l.sku, 'qty' value l.qty)
                                                                order by l.line_id returning json)
                                                           FROM m08a_h_line l WHERE l.order_id = o.id)
                                          returning blob format oson))
      INTO ob FROM m08a_ord o WHERE o.id = t.id;
    m08_meter.record('s1a-doc-k' || t.k || '-oson-bytes', ob);
    IF ob <= 2000 THEN
      sz := LEAST(8192, CEIL(1.1 * (ob + 20) / 256) * 256);
      m08_meter.record('s1a-hdoc-k' || t.k || '-size', sz);
      ddl('create cluster m08a_hd' || t.k || ' (order_id number) size ' || sz
          || ' single table hashkeys 22000');
      ddl('create table m08a_hd' || t.k || '_doc (order_id number primary key,'
          || ' doc raw(2000) check (doc is json format oson)) cluster m08a_hd' || t.k || ' (order_id)');
      ddl('insert into m08a_hd' || t.k || '_doc (order_id, doc)'
          || ' select id, dbms_lob.substr(b, 2000, 1) from ('
          || '  select o.id, json_object(''_id'' value o.id, ''customer'' value o.customer,'
          || '         ''status'' value o.status,'
          || '         ''lines'' value (select json_arrayagg(json_object(''lineId'' value l.line_id,'
          || '                                 ''sku'' value l.sku, ''qty'' value l.qty)'
          || '                               order by l.line_id returning json)'
          || '                          from m08a_h_line l where l.order_id = o.id)'
          || '         returning blob format oson) b'
          || '    from m08a_ord o)'
          || ' where dbms_lob.getlength(b) <= 2000');
      COMMIT;
      EXECUTE IMMEDIATE 'select count(*) from m08a_hd' || t.k || '_doc' INTO ob;
      m08_meter.record('s1a-hdoc-k' || t.k || '-docs', ob);
    END IF;
  END LOOP;
END;
/

drop table m08a_line_plan purge;

-- The duality view over the iot variant: lines keyed by lineId; the order_id
-- foreign key is joined on, not selected.
create or replace json relational duality view m08a_i_dv as
  select json {'_id': o.id, 'customer': o.customer, 'status': o.status,
               'lines': [select json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty}
                           from m08a_i_line l where l.order_id = o.id]}
    from m08a_ord o;

-- Statistics without histograms (SIZE 1). The CPU readers below use literal
-- ids, and whether SIZE AUTO builds a histogram on order_id depends on when the
-- database last flushed its column-usage data. With one, the optimizer costs the
-- heap k = 1000 lookup as a full table scan (about 1,000 reads, more than the
-- index path), and the plan changes from run to run. SIZE 1 gives every reader
-- the same indexed plan the bind-variable reads block gets, on every run.
BEGIN
  FOR t IN (SELECT column_value tn FROM table(sys.odcivarchar2list(
              'M08A_ORD', 'M08A_H_LINE', 'M08A_V_LINE', 'M08A_I_LINE', 'M08A_K_LINE',
              'M08A_C_ORD', 'M08A_C_LINE', 'M08A_HC_ORD', 'M08A_HC_LINE', 'M08A_DOC'))) LOOP
    dbms_stats.gather_table_stats(user, t.tn, cascade => true,
                                  method_opt => 'FOR ALL COLUMNS SIZE 1');
  END LOOP;
  FOR t IN (SELECT table_name tn FROM user_tables
             WHERE table_name LIKE 'M08A\_HK%' ESCAPE '\' OR table_name LIKE 'M08A\_HD%' ESCAPE '\') LOOP
    dbms_stats.gather_table_stats(user, t.tn, cascade => true,
                                  method_opt => 'FOR ALL COLUMNS SIZE 1');
  END LOOP;
END;
/

-- ===== Measurement: logical reads =====
-- Meter overhead: snap then delta with no work in between. Measured twice; the
-- second (warm) result is kept and subtracted from every read count below.
DECLARE
  r NUMBER;
BEGIN
  FOR i IN 1 .. 2 LOOP
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
  END LOOP;
  m08_meter.record('s1a-meter-overhead-reads', r);
END;
/

-- Document and duality view: one serialized document by _id, so the body is
-- really read (a bare JSON fetch returns a locator and skips it).
DECLARE
  TYPE t_json IS TABLE OF BLOB;
  v    t_json;
  ovr  NUMBER;
  r    NUMBER;
  PROCEDURE q(p_v VARCHAR2, p_id NUMBER) IS
  BEGIN
    IF p_v = 'doc' THEN
      SELECT /*+ M08ADOC */ json_serialize(d.data returning blob) BULK COLLECT INTO v
        FROM m08a_doc d WHERE d.data."_id" = p_id;
    ELSE
      SELECT /*+ M08ADV */ json_serialize(d.data returning blob) BULK COLLECT INTO v
        FROM m08a_i_dv d WHERE d.data."_id" = p_id;
    END IF;
    IF v.COUNT <> 1 THEN RAISE_APPLICATION_ERROR(-20820, p_v || ' rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1a-meter-overhead-reads';
  FOR rv IN (SELECT column_value v FROM table(sys.odcivarchar2list('doc', 'dv'))) LOOP
    FOR t IN (SELECT 900010 + level id, power(10, level - 1) k FROM dual CONNECT BY level <= 4) LOOP
      q(rv.v, t.id);
      m08_meter.snap;
      q(rv.v, t.id);
      r := m08_meter.delta('session logical reads');
      m08_meter.record('s1a-' || rv.v || '-k' || t.k || '-reads', GREATEST(r - ovr, 0));
    END LOOP;
  END LOOP;
END;
/

-- The four joins: the order row joined to its line rows, by order id.
DECLARE
  TYPE t_row IS RECORD (id NUMBER, customer VARCHAR2(40), status VARCHAR2(12),
                        line_id VARCHAR2(36), sku VARCHAR2(20), qty NUMBER);
  TYPE t_rows IS TABLE OF t_row;
  v    t_rows;
  ovr  NUMBER;
  r    NUMBER;
  PROCEDURE q(p_v VARCHAR2, p_id NUMBER, p_k NUMBER) IS
  BEGIN
    CASE p_v
      WHEN 'heap' THEN
        SELECT /*+ M08AHEAP */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_ord o JOIN m08a_h_line l ON l.order_id = o.id WHERE o.id = p_id;
      WHEN 'cov' THEN
        SELECT /*+ M08ACOV */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_ord o JOIN m08a_v_line l ON l.order_id = o.id WHERE o.id = p_id;
      WHEN 'iot' THEN
        SELECT /*+ M08AIOT */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_ord o JOIN m08a_i_line l ON l.order_id = o.id WHERE o.id = p_id;
      WHEN 'iotc' THEN
        SELECT /*+ M08AIOTC */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_ord o JOIN m08a_k_line l ON l.order_id = o.id WHERE o.id = p_id;
      WHEN 'hash' THEN
        SELECT /*+ M08AHASH */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_hc_ord o JOIN m08a_hc_line l ON l.order_id = o.id WHERE o.id = p_id;
      WHEN 'clu' THEN
        SELECT /*+ M08ACLU */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_c_ord o JOIN m08a_c_line l ON l.order_id = o.id WHERE o.id = p_id;
    END CASE;
    IF v.COUNT <> p_k THEN RAISE_APPLICATION_ERROR(-20821, p_v || ' rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1a-meter-overhead-reads';
  FOR rv IN (SELECT column_value v FROM table(sys.odcivarchar2list('heap', 'cov', 'iot', 'iotc', 'clu', 'hash'))) LOOP
    FOR t IN (SELECT 900010 + level id, power(10, level - 1) k FROM dual CONNECT BY level <= 4) LOOP
      q(rv.v, t.id, t.k);
      m08_meter.snap;
      q(rv.v, t.id, t.k);
      r := m08_meter.delta('session logical reads');
      m08_meter.record('s1a-' || rv.v || '-k' || t.k || '-reads', GREATEST(r - ovr, 0));
    END LOOP;
  END LOOP;
END;
/

-- ===== Measurement: CPU and elapsed (k = 100 and 1000) =====
-- m08_meter.measure_repeat: one warm-up, then 20 runs, each fetching every row;
-- records the median and max of reads, CPU and elapsed per reader.
DECLARE
  TYPE t_map IS TABLE OF VARCHAR2(400) INDEX BY VARCHAR2(10);
  sqls t_map;
  v    VARCHAR2(10);
BEGIN
  sqls('doc')  := 'select /*+ M08ADOC */ json_serialize(d.data returning blob) from m08a_doc d where d.data."_id" = :id';
  sqls('dv')   := 'select /*+ M08ADV */ json_serialize(d.data returning blob) from m08a_i_dv d where d.data."_id" = :id';
  sqls('heap') := 'select /*+ M08AHEAP */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_ord o join m08a_h_line l on l.order_id = o.id where o.id = :id';
  sqls('cov')  := 'select /*+ M08ACOV */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_ord o join m08a_v_line l on l.order_id = o.id where o.id = :id';
  sqls('iot')  := 'select /*+ M08AIOT */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_ord o join m08a_i_line l on l.order_id = o.id where o.id = :id';
  sqls('iotc') := 'select /*+ M08AIOTC */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_ord o join m08a_k_line l on l.order_id = o.id where o.id = :id';
  sqls('hash') := 'select /*+ M08AHASH */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_hc_ord o join m08a_hc_line l on l.order_id = o.id where o.id = :id';
  sqls('clu')  := 'select /*+ M08ACLU */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
               || ' from m08a_c_ord o join m08a_c_line l on l.order_id = o.id where o.id = :id';
  v := sqls.FIRST;
  WHILE v IS NOT NULL LOOP
    FOR t IN (SELECT 900013 id, 100 k FROM dual UNION ALL SELECT 900014, 1000 FROM dual) LOOP
      m08_meter.measure_repeat('s1a-' || v || '-k' || t.k,
                               replace(sqls(v), ':id', to_char(t.id)), 20,
                               p_allow_lob => v IN ('doc', 'dv'));
    END LOOP;
    v := sqls.NEXT(v);
  END LOOP;
END;
/

-- ===== Measurement: 20 targets per k, every reader =====
-- For each reader, k and target: logical reads of the second execution
-- (m08_meter.measure_reads), then CPU, elapsed and bytes
-- (m08_meter.measure_us: purge, warm-up, 100 runs, v$sql growth per run). Each
-- reader binds the order id, so every target is parsed for its own id. Right
-- after each CPU window, the cursor's plan is checked for the reader's access
-- path (tmp:...-planok). Values per target stay in tmp rows; the summary
-- below records the median (lower middle of 20), min and max.
-- Readers whose storage depends on k: hashk and hdv use the cluster sized for
-- that k, hdoc exists for k = 1 and 10 only.
DECLARE
  TYPE t_vs IS TABLE OF VARCHAR2(10);
  rdrs t_vs := t_vs('doc', 'heap', 'cov', 'iot', 'iotc', 'clu', 'hash', 'dv', 'hashk', 'hdv', 'hdoc');
  q    VARCHAR2(1000);
  nm   VARCHAR2(80);
  lob  BOOLEAN;
  ok   NUMBER;

  FUNCTION join_sql(p_mk VARCHAR2, p_ord VARCHAR2, p_line VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN 'select /*+ ' || p_mk || ' */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
        || ' from ' || p_ord || ' o join ' || p_line || ' l on l.order_id = o.id where o.id = :id';
  END;

  -- The reader's query, with marker M08A<p_kind><READER> (R: reads, T: timed).
  FUNCTION rsql(p_v VARCHAR2, p_k NUMBER, p_kind VARCHAR2) RETURN VARCHAR2 IS
    mk VARCHAR2(30) := 'M08A' || p_kind || upper(p_v);
  BEGIN
    RETURN CASE p_v
      WHEN 'doc'   THEN 'select /*+ ' || mk || ' */ json_serialize(d.data returning blob)'
                        || ' from m08a_doc d where d.data."_id" = :id'
      WHEN 'dv'    THEN 'select /*+ ' || mk || ' */ json_serialize(d.data returning blob)'
                        || ' from m08a_i_dv d where d.data."_id" = :id'
      WHEN 'hdv'   THEN 'select /*+ ' || mk || ' */ json_serialize(d.data returning blob)'
                        || ' from m08a_hk' || p_k || '_dv d where d.data."_id" = :id'
      WHEN 'hdoc'  THEN 'select /*+ ' || mk || ' */ json_serialize(d.doc returning blob)'
                        || ' from m08a_hd' || p_k || '_doc d where d.order_id = :id'
      WHEN 'heap'  THEN join_sql(mk, 'm08a_ord', 'm08a_h_line')
      WHEN 'cov'   THEN join_sql(mk, 'm08a_ord', 'm08a_v_line')
      WHEN 'iot'   THEN join_sql(mk, 'm08a_ord', 'm08a_i_line')
      WHEN 'iotc'  THEN join_sql(mk, 'm08a_ord', 'm08a_k_line')
      WHEN 'clu'   THEN join_sql(mk, 'm08a_c_ord', 'm08a_c_line')
      WHEN 'hash'  THEN join_sql(mk, 'm08a_hc_ord', 'm08a_hc_line')
      WHEN 'hashk' THEN join_sql(mk, 'm08a_hk' || p_k || '_ord', 'm08a_hk' || p_k || '_line')
    END;
  END;

  -- Plan lines of the marker's current cursor(s) matching an operation.
  FUNCTION has(p_mk VARCHAR2, p_op VARCHAR2, p_opt VARCHAR2, p_obj VARCHAR2) RETURN NUMBER IS
    n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n
      FROM v$sql s JOIN v$sql_plan p ON p.sql_id = s.sql_id AND p.child_number = s.child_number
     WHERE s.sql_text LIKE '% ' || p_mk || ' */%' AND s.command_type = 3
       AND p.operation = p_op
       AND (p_opt IS NULL OR p.options = p_opt)
       AND (p_obj IS NULL OR p.object_name = p_obj);
    RETURN n;
  END;

  FUNCTION fulls(p_mk VARCHAR2) RETURN NUMBER IS
    n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO n
      FROM v$sql s JOIN v$sql_plan p ON p.sql_id = s.sql_id AND p.child_number = s.child_number
     WHERE s.sql_text LIKE '% ' || p_mk || ' */%' AND s.command_type = 3
       AND (p.options LIKE '%FULL%' OR p.options LIKE '%SAMPLE%');
    RETURN n;
  END;

  -- The access path under test, as in the s1a-plan-* checks, for the timed cursor.
  FUNCTION plan_ok(p_v VARCHAR2, p_k NUMBER) RETURN NUMBER IS
    mk VARCHAR2(30) := 'M08AT' || upper(p_v);
    hk VARCHAR2(30) := 'M08A_HK' || p_k;
    good BOOLEAN;
  BEGIN
    good := CASE p_v
      WHEN 'doc'   THEN has(mk, 'INDEX', NULL, NULL) > 0
      WHEN 'heap'  THEN has(mk, 'INDEX', 'RANGE SCAN', 'M08A_H_LINE_ORDER_IX') > 0
      WHEN 'cov'   THEN has(mk, 'INDEX', 'RANGE SCAN', 'M08A_V_LINE_COV_IX') > 0
                        AND has(mk, 'TABLE ACCESS', NULL, 'M08A_V_LINE') = 0
      WHEN 'iot'   THEN has(mk, 'INDEX', 'RANGE SCAN', 'M08A_I_LINE_PK') > 0
      WHEN 'iotc'  THEN has(mk, 'INDEX', 'RANGE SCAN', 'M08A_K_LINE_PK') > 0
      WHEN 'clu'   THEN has(mk, 'TABLE ACCESS', 'CLUSTER', 'M08A_C_LINE') > 0
      WHEN 'hash'  THEN has(mk, 'TABLE ACCESS', 'HASH', 'M08A_HC_ORD') > 0
                        AND has(mk, 'TABLE ACCESS', 'HASH', 'M08A_HC_LINE') > 0
                        AND has(mk, 'INDEX', NULL, NULL) = 0
      WHEN 'dv'    THEN has(mk, 'INDEX', 'RANGE SCAN', 'M08A_I_LINE_PK') > 0
      WHEN 'hashk' THEN has(mk, 'TABLE ACCESS', 'HASH', hk || '_ORD') > 0
                        AND has(mk, 'TABLE ACCESS', 'HASH', hk || '_LINE') > 0
                        AND has(mk, 'INDEX', NULL, NULL) = 0
      WHEN 'hdv'   THEN has(mk, 'TABLE ACCESS', 'HASH', hk || '_LINE') > 0
      WHEN 'hdoc'  THEN has(mk, 'TABLE ACCESS', 'HASH', 'M08A_HD' || p_k || '_DOC') > 0
                        AND has(mk, 'INDEX', NULL, NULL) = 0
    END;
    RETURN CASE WHEN good AND fulls(mk) = 0 THEN 1 ELSE 0 END;
  END;
BEGIN
  FOR i IN 1 .. rdrs.COUNT LOOP
    FOR t IN (SELECT k, j, id FROM m08a_targets ORDER BY k, j) LOOP
      CONTINUE WHEN rdrs(i) = 'hdoc' AND t.k > 10;
      nm  := 'tmp:s1a-' || rdrs(i) || '-k' || t.k || '-t' || t.j;
      lob := rdrs(i) IN ('doc', 'dv', 'hdv', 'hdoc');
      m08_meter.measure_reads(nm, rsql(rdrs(i), t.k, 'R'), t.id, lob);
      m08_meter.measure_us(nm, rsql(rdrs(i), t.k, 'T'), 'M08AT' || upper(rdrs(i)), t.id, 100, lob);
      m08_meter.record(nm || '-planok', plan_ok(rdrs(i), t.k));
    END LOOP;
  END LOOP;
END;
/

-- Summary per reader and k over its targets: median (the lower middle value,
-- an observed target), min and max of reads and CPU microseconds; median of
-- elapsed microseconds and bytes; and the number of targets. Target 1's CPU,
-- elapsed and bytes are also recorded under the single-target names
-- (s1a-<reader>-k<k>-us, -ela-us, -bytes), next to its -reads.
DECLARE
  PROCEDURE summ(p_v VARCHAR2, p_k NUMBER) IS
    pfx VARCHAR2(60) := 's1a-' || p_v || '-k' || p_k;
  BEGIN
    FOR st IN (SELECT column_value s FROM TABLE(sys.odcivarchar2list('reads', 'us', 'ela-us', 'bytes'))) LOOP
      FOR a IN (SELECT percentile_disc(0.5) WITHIN GROUP (ORDER BY value) md,
                       MIN(value) mn, MAX(value) mx, COUNT(*) n
                  FROM m08_metrics
                 WHERE regexp_like(name, '^tmp:' || pfx || '-t[0-9]+-' || st.s || '$')) LOOP
        IF a.n > 0 THEN
          m08_meter.record(pfx || '-t20-' || st.s || '-median', a.md);
          IF st.s IN ('reads', 'us') THEN
            m08_meter.record(pfx || '-t20-' || st.s || '-min', a.mn);
            m08_meter.record(pfx || '-t20-' || st.s || '-max', a.mx);
          END IF;
          IF st.s = 'reads' THEN
            m08_meter.record(pfx || '-t20-targets', a.n);
          END IF;
        END IF;
      END LOOP;
    END LOOP;
    FOR st IN (SELECT column_value s FROM TABLE(sys.odcivarchar2list('us', 'ela-us', 'bytes'))) LOOP
      INSERT INTO m08_metrics (name, value)
        SELECT pfx || '-' || st.s, value FROM m08_metrics
         WHERE name = 'tmp:' || pfx || '-t1-' || st.s;
    END LOOP;
  END;
BEGIN
  FOR r IN (SELECT column_value v FROM TABLE(sys.odcivarchar2list(
              'doc', 'heap', 'cov', 'iot', 'iotc', 'clu', 'hash', 'dv', 'hashk', 'hdv', 'hdoc'))) LOOP
    FOR k IN (SELECT DISTINCT k FROM m08a_targets ORDER BY k) LOOP
      summ(r.v, k.k);
    END LOOP;
  END LOOP;
END;
/

-- ===== Layout facts (as METRIC rows below) =====
-- Distinct blocks that hold each target's line rows: heap, index cluster and
-- hash cluster. (An index-organized table has no physical rowid block number,
-- so iot and iotc are not listed.)
BEGIN
  FOR t IN (SELECT 900010 + level id, power(10, level - 1) k FROM dual CONNECT BY level <= 4) LOOP
    FOR b IN (SELECT 'heap' v, count(DISTINCT dbms_rowid.rowid_block_number(rowid)) n
                FROM m08a_h_line WHERE order_id = t.id
              UNION ALL
              SELECT 'clu', count(DISTINCT dbms_rowid.rowid_block_number(rowid))
                FROM m08a_c_line WHERE order_id = t.id
              UNION ALL
              SELECT 'hash', count(DISTINCT dbms_rowid.rowid_block_number(rowid))
                FROM m08a_hc_line WHERE order_id = t.id) LOOP
      m08_meter.record('s1a-' || b.v || '-k' || t.k || '-blocks', b.n);
    END LOOP;
  END LOOP;
END;
/

-- ===== Assertions =====

-- Same content: every reader's tables return the same rows for each of the 20
-- targets at each k, the order fields and all k lines (doc and dv read
-- through json_table).
with tg as (select id, k from m08a_targets),
src as (
  select 'doc' v, d.data."_id".number() id, d.data.customer.string() customer,
         d.data.status.string() status, j.line_id, j.sku, j.qty
    from m08a_doc d,
         json_table(d.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                   sku varchar2(20) path '$.sku', qty number path '$.qty')) j
   where d.data."_id".number() in (select id from tg)
  union all
  select 'heap', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_h_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'cov', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_v_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'iot', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_i_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'iotc', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_k_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'hash', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_hc_ord o join m08a_hc_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'clu', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_c_ord o join m08a_c_line l on l.order_id = o.id where o.id in (select id from tg)
  union all
  select 'dv', v.data."_id".number(), v.data.customer.string(), v.data.status.string(),
         j.line_id, j.sku, j.qty
    from m08a_i_dv v,
         json_table(v.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                   sku varchar2(20) path '$.sku', qty number path '$.qty')) j
   where v.data."_id".number() in (select id from tg)
),
g as (
  select id, count(*) n, count(distinct v) nv
    from src group by id, customer, status, line_id, sku, qty
),
ks as (select distinct k from m08a_targets)
select 'ASSERT:s1a-same-content-k' || ks.k || ':' ||
       case when (select count(*) from g join tg on tg.id = g.id where tg.k = ks.k) = 20 * ks.k
             and (select count(*) from g join tg on tg.id = g.id
                   where tg.k = ks.k and (g.n <> 8 or g.nv <> 8)) = 0
             and (select count(*) from m08_metrics where name like 's1a-%-k' || ks.k || '-reads') = 8
            then 'PASS' else 'FAIL' end
  from ks
 order by ks.k;

-- Same content for the fairness arms: for every target, the k-sized hash
-- cluster join (hashk), the duality view over it (hdv, through json_table)
-- and, where stored, the hash-cluster document (hdoc, through json_table)
-- return exactly the document's rows; hdoc is stored for all 20 targets at
-- k = 1 and 10 and the same JSON as the document (json_equal).
declare
  ok  number := 1;
  n   number;
  function cnt(p_sql varchar2) return number is
    x number;
  begin
    execute immediate p_sql into x;
    return x;
  end;
begin
  for t in (select k, id from m08a_targets) loop
    for a in (select 'select o.id, o.customer, o.status, l.line_id, l.sku, l.qty from m08a_hk' || t.k
                     || '_ord o join m08a_hk' || t.k || '_line l on l.order_id = o.id where o.id = ' || t.id q
                from dual
              union all
              select 'select v.data."_id".number(), v.data.customer.string(), v.data.status.string(),'
                     || ' j.line_id, j.sku, j.qty from m08a_hk' || t.k || '_dv v, json_table(v.data, ''$.lines[*]'''
                     || ' columns (line_id varchar2(36) path ''$.lineId'', sku varchar2(20) path ''$.sku'','
                     || ' qty number path ''$.qty'')) j where v.data."_id" = ' || t.id
                from dual
              union all
              select 'select json_value(d.doc, ''$._id'' returning number), json_value(d.doc, ''$.customer''),'
                     || ' json_value(d.doc, ''$.status''), j.line_id, j.sku, j.qty from m08a_hd' || t.k || '_doc d,'
                     || ' json_table(d.doc format oson, ''$.lines[*]'' columns (line_id varchar2(36) path ''$.lineId'','
                     || ' sku varchar2(20) path ''$.sku'', qty number path ''$.qty'')) j where d.order_id = ' || t.id
                from dual where t.k <= 10) loop
      n := cnt('select count(*) from ((' || a.q || ') minus (select d.data."_id".number(), d.data.customer.string(),'
               || ' d.data.status.string(), j.line_id, j.sku, j.qty from m08a_doc d, json_table(d.data, ''$.lines[*]'''
               || ' columns (line_id varchar2(36) path ''$.lineId'', sku varchar2(20) path ''$.sku'','
               || ' qty number path ''$.qty'')) j where d.data."_id" = ' || t.id || '))')
         + abs(cnt('select count(*) from (' || a.q || ')') - t.k);
      if n <> 0 then ok := 0; end if;
    end loop;
    if t.k <= 10 then
      n := cnt('select count(*) from m08a_hd' || t.k || '_doc h join m08a_doc d on d.data."_id" = h.order_id'
               || ' where h.order_id = ' || t.id || ' and json_equal(json(h.doc), d.data)');
      if n <> 1 then ok := 0; end if;
    end if;
  end loop;
  m08_meter.record('tmp:s1a-arms-same-content', ok);
end;
/

select 'ASSERT:s1a-same-content-new-arms:' ||
       case when (select value from m08_metrics where name = 'tmp:s1a-arms-same-content') = 1
             -- the arms hold the full population: every order in each k-sized
             -- cluster, every order but the 40 large targets in each document cluster
             and (select count(*) from m08_metrics
                   where name like 's1a-hashk-k%-orders'
                     and value = (select value from m08_metrics where name = 's1a-orders')) = 4
             and (select count(*) from m08_metrics
                   where name like 's1a-hdoc-k%-docs'
                     and value = (select value from m08_metrics where name = 's1a-orders') - 40) = 2
            then 'PASS' else 'FAIL' end
  from dual;

-- The 20-target windows: every timed cursor ran its access path under test
-- (tmp:...-planok), executed once per call, and was parsed fresh (its purge
-- left no cursor). 8 readers x 80 targets, hashk and hdv x 80, hdoc x 40.
select 'ASSERT:s1a-t20-plans:' ||
       case when (select count(*) from m08_metrics where name like 'tmp:s1a-%-planok') = 840
             and (select count(*) from m08_metrics where name like 'tmp:s1a-%-planok' and value <> 1) = 0
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1a-t20-measured:' ||
       case when (select count(*) from m08_metrics where name like 'tmp:s1a-%-execs-per-call') = 840
             and (select count(*) from m08_metrics where name like 'tmp:s1a-%-execs-per-call' and value <> 1) = 0
             and (select count(*) from m08_metrics where name like 's1a-%-t20-targets' and value = 20) = 42
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1a-t20-purge-effective:' ||
       case when (select count(*) from m08_metrics where name like 'tmp:s1a-%-purge-left') = 840
             and (select count(*) from m08_metrics where name like 'tmp:s1a-%-purge-left' and value <> 0) = 0
            then 'PASS' else 'FAIL' end
  from dual;

-- Plans. Each marker names one reader; every measured cursor with that marker
-- (the reads block's and measure_repeat's, at least two) must have the access
-- path under test.
--   iot  : INDEX RANGE SCAN on the IOT primary key
--   iotc : INDEX RANGE SCAN on the compressed IOT's primary key
--   clu  : TABLE ACCESS CLUSTER on the cluster's line table
--   hash : TABLE ACCESS HASH on both the order and the line table, and no INDEX step
--   cov  : an INDEX RANGE SCAN on the covering index, and no TABLE ACCESS on the line table
--   dv   : tracks iot (INDEX RANGE SCAN on the IOT primary key)
-- Each row of m is one required plan line; a marker passes when all of its rows
-- are found in every one of its cursors.
with m (marker, ok_op, ok_opt, ok_obj, bad_obj) as (
  select 'M08AIOT', 'INDEX', 'RANGE SCAN', 'M08A_I_LINE_PK', null from dual union all
  select 'M08AIOTC', 'INDEX', 'RANGE SCAN', 'M08A_K_LINE_PK', null from dual union all
  select 'M08ACLU', 'TABLE ACCESS', 'CLUSTER', 'M08A_C_LINE', null from dual union all
  select 'M08AHASH', 'TABLE ACCESS', 'HASH', 'M08A_HC_ORD', null from dual union all
  select 'M08AHASH', 'TABLE ACCESS', 'HASH', 'M08A_HC_LINE', null from dual union all
  select 'M08ACOV', 'INDEX', 'RANGE SCAN', 'M08A_V_LINE_COV_IX', 'M08A_V_LINE' from dual union all
  select 'M08ADV', 'INDEX', 'RANGE SCAN', 'M08A_I_LINE_PK', null from dual
),
cur as (
  select m.marker, s.sql_id, s.child_number,
         (select count(*) from v$sql_plan p
           where p.sql_id = s.sql_id and p.child_number = s.child_number
             and p.operation = m.ok_op and p.options = m.ok_opt and p.object_name = m.ok_obj) good,
         (select count(*) from v$sql_plan p
           where p.sql_id = s.sql_id and p.child_number = s.child_number
             and ((p.operation = 'TABLE ACCESS' and p.object_name = m.bad_obj)
                  or (m.marker = 'M08AHASH' and p.operation = 'INDEX'))) bad
    from m join v$sql s on upper(s.sql_text) like '%/*+ ' || m.marker || ' */%'
   where s.object_status = 'VALID'
     and s.command_type = 3                -- the SELECT itself, not the PL/SQL block around it
     and upper(s.sql_text) not like '%V$SQL%'
)
select 'ASSERT:s1a-plan-' || lower(substr(mk.marker, 5)) || ':' ||
       case when (select count(distinct cur.sql_id || ':' || cur.child_number)
                    from cur where cur.marker = mk.marker) >= 2
             and (select count(*) from cur where cur.marker = mk.marker and (cur.good = 0 or cur.bad > 0)) = 0
            then 'PASS' else 'FAIL' end
  from (select distinct marker from m) mk
 order by mk.marker;

-- Every measured statement used keyed access (an index, or the hash cluster's
-- hash), and none scanned a whole table.
select 'ASSERT:s1a-plans-indexed:' ||
       case when (select count(distinct m.marker)
                    from (select column_value marker from table(sys.odcivarchar2list(
                            'M08ADOC', 'M08AHEAP', 'M08ACOV', 'M08AIOT', 'M08AIOTC',
                            'M08ACLU', 'M08AHASH', 'M08ADV'))) m
                   where exists (select 1 from v$sql s join v$sql_plan p
                                     on p.sql_id = s.sql_id and p.child_number = s.child_number
                                  where upper(s.sql_text) like '%/*+ ' || m.marker || ' */%'
                                    and s.object_status = 'VALID'
                                    and s.command_type = 3
                                    and (p.operation = 'INDEX'
                                         or (p.operation = 'TABLE ACCESS' and p.options = 'HASH')))) = 8
             and (select count(*) from v$sql s join v$sql_plan p
                      on p.sql_id = s.sql_id and p.child_number = s.child_number
                   where upper(s.sql_text) like '%/*+ M08' || 'A%'
                     and upper(s.sql_text) not like '%V$SQL%'   -- not a query that inspects plans
                     and s.command_type = 3
                     and s.object_status = 'VALID'
                     and (p.options like '%FULL%' or p.options like '%SAMPLE%')) = 0
            then 'PASS' else 'FAIL' end
  from dual;

-- The heap baseline reproduces S1's interleaved join (within 5 reads at each k),
-- and the document reproduces S1's document read (within 2 reads).
with ks as (select column_value k from table(sys.odcinumberlist(1, 10, 100, 1000)))
select 'ASSERT:s1a-heap-matches-s1-k' || k || ':' ||
       case when abs((select value from m08_metrics where name = 's1a-heap-k' || k || '-reads') -
                     (select value from m08_metrics where name = 'ref:s1-join-interleaved-k' || k || '-reads')) <= 5
             and abs((select value from m08_metrics where name = 's1a-doc-k' || k || '-reads') -
                     (select value from m08_metrics where name = 'ref:s1-doc-interleaved-k' || k || '-reads')) <= 2
            then 'PASS' else 'FAIL' end
  from ks
 order by k;

-- The cluster really co-locates: the 1,000-line target's lines sit in far
-- fewer cluster blocks than heap blocks. (A layout check, not a cost check.)
select 'ASSERT:s1a-clu-colocated:' ||
       case when (select value from m08_metrics where name = 's1a-clu-k1000-blocks') * 10
               <= (select value from m08_metrics where name = 's1a-heap-k1000-blocks')
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Measurements (as METRIC rows) =====
-- No direction is asserted between the document and any join: the numbers are
-- reported as measured.
select 'METRIC:' || name || ':' || to_char(value, 'FM999999990')
  from m08_metrics
 where name like 's1a-%'
   and (name like '%-reads' or name like '%-blocks' or name like '%-reads-median'
        or name like '%-cpu-cs-median' or name like '%-cpu-cs-max'
        or name like '%-elapsed-cs-median' or name like '%-elapsed-cs-max'
        or name like '%-us' or name like '%-bytes' or name like '%-t20-%'
        or name like '%-size' or name = 's1a-orders' or name like '%-orders' or name like '%-docs')
 order by name;

-- ===== Teardown =====
-- Clear this script's rows (and S1's handed-off 'ref:' rows) first: the DDL
-- below commits, so the validator's rollback would not remove them.
delete from m08_metrics where name like 's1a-%' or name like 'tmp:s1a-%' or name like 'ref:s1-%';

drop view if exists m08a_i_dv;
drop table if exists m08a_targets purge;
drop table if exists m08a_h_line purge;
drop table if exists m08a_v_line purge;
drop table if exists m08a_i_line purge;
drop table if exists m08a_k_line purge;
drop table if exists m08a_ord purge;
drop table if exists m08a_doc purge;
BEGIN
  FOR v IN (SELECT view_name FROM user_views WHERE view_name LIKE 'M08A\_HK%' ESCAPE '\') LOOP
    EXECUTE IMMEDIATE 'DROP VIEW ' || v.view_name;
  END LOOP;
  FOR c IN (SELECT cluster_name FROM user_clusters WHERE cluster_name LIKE 'M08A\_%' ESCAPE '\') LOOP
    EXECUTE IMMEDIATE 'DROP CLUSTER ' || c.cluster_name || ' INCLUDING TABLES CASCADE CONSTRAINTS';
  END LOOP;
END;
/

select 'ASSERT:s1a-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08A\_%' escape '\') = 0
             and (select count(*) from m08_metrics
                   where name like 's1a-%' or name like 'tmp:s1a-%' or name like 'ref:s1-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
