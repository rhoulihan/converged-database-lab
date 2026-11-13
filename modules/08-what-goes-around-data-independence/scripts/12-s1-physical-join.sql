-- S1 physical variants (A): is S1's join the best join? Read one order and all
-- of its lines by key, six ways, over the same interleaved data:
--   doc  : one document from a JSON collection table, found through its _id index
--   heap : heap line table, single-column order_id index (S1's interleaved join)
--   cov  : heap line table plus a covering index (order_id, line_id, sku, qty),
--          so the lines are read from the index alone
--   iot  : index-organized line table, primary key (order_id, line_id), so each
--          order's lines sit together in the primary key's leaf blocks
--   clu  : index cluster on order_id holding both the order and line tables, so
--          an order and its lines share cluster blocks behind one key lookup
--   dv   : a duality view over the iot variant (a join, measured as one)
-- Every line table is loaded in the same interleaved order (S1's recipe), so the
-- physical design, not the load order, does any clustering.
-- Logical reads: the second execution of each read, as in S1, less the meter's
-- own overhead. CPU and elapsed: m08_meter.measure_repeat (20 runs) for k = 100
-- and k = 1000 only; smaller reads are below its 1 cs resolution.
-- The heap baseline is checked against S1's own interleaved numbers, which
-- 10-s1-read-by-key.sql leaves in m08_metrics as 'ref:s1-*' rows.

-- Clean up anything left by an earlier, interrupted run.
drop view if exists m08a_i_dv;
drop table if exists m08a_h_line purge;
drop table if exists m08a_v_line purge;
drop table if exists m08a_i_line purge;
drop table if exists m08a_ord purge;
drop table if exists m08a_doc purge;
drop table if exists m08a_line_plan purge;
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM user_clusters WHERE cluster_name = 'M08A_CLU';
  IF n > 0 THEN
    EXECUTE IMMEDIATE 'DROP CLUSTER m08a_clu INCLUDING TABLES CASCADE CONSTRAINTS';
  END IF;
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

create json collection table m08a_doc;

-- ===== Data =====
-- S1's line plan, without S1's clustered targets (this script measures the
-- interleaved layout only). Phase 1: 2,000 filler orders of 10 lines, each
-- order's lines together. Phase 2: 200 slots, 1,000 rounds; each round inserts
-- one line for every slot. Slots 0..3 hold the targets (ids 900011..900014,
-- k = 1, 10, 100, 1000); every other slot, and a target slot once its target is
-- complete, holds a stream of 10-line filler orders, so 200 orders stay open
-- for the whole phase.
create table m08a_line_plan as
with t (slot, k) as (
  select 0, 1 from dual union all select 1, 10 from dual
  union all select 2, 100 from dual union all select 3, 1000 from dual
),
clustered as (
  select o.id order_id, n, 1 phase,
         case when o.id <= 1000 then o.id else o.id + 4 end pos1, n pos2
    from (select level id from dual connect by level <= 2000) o,
         (select level - 1 n from dual connect by level <= 10)
),
rr as (
  select r.r, s.s, t.k
    from (select level - 1 r from dual connect by level <= 1000) r,
         (select level - 1 s from dual connect by level <= 200) s
         left join t on t.slot = s.s
),
interleaved as (
  select case when rr.k is not null and rr.r < rr.k then 900011 + rr.s
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

drop table m08a_line_plan purge;

-- The document projection carries the same content: the order and all its lines.
insert into m08a_doc (data)
  select json {'_id': o.id, 'customer': o.customer, 'status': o.status,
               'lines': (select json_arrayagg(json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty}
                                              order by l.line_id returning json)
                           from m08a_h_line l where l.order_id = o.id)}
    from m08a_ord o;

commit;

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
              'M08A_ORD', 'M08A_H_LINE', 'M08A_V_LINE', 'M08A_I_LINE',
              'M08A_C_ORD', 'M08A_C_LINE', 'M08A_DOC'))) LOOP
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
      WHEN 'clu' THEN
        SELECT /*+ M08ACLU */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
          BULK COLLECT INTO v
          FROM m08a_c_ord o JOIN m08a_c_line l ON l.order_id = o.id WHERE o.id = p_id;
    END CASE;
    IF v.COUNT <> p_k THEN RAISE_APPLICATION_ERROR(-20821, p_v || ' rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1a-meter-overhead-reads';
  FOR rv IN (SELECT column_value v FROM table(sys.odcivarchar2list('heap', 'cov', 'iot', 'clu'))) LOOP
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

-- ===== Layout facts (as METRIC rows below) =====
-- Distinct blocks that hold each target's line rows, heap and cluster. (An
-- index-organized table has no physical rowid block number, so iot is not listed.)
BEGIN
  FOR t IN (SELECT 900010 + level id, power(10, level - 1) k FROM dual CONNECT BY level <= 4) LOOP
    FOR b IN (SELECT 'heap' v, count(DISTINCT dbms_rowid.rowid_block_number(rowid)) n
                FROM m08a_h_line WHERE order_id = t.id
              UNION ALL
              SELECT 'clu', count(DISTINCT dbms_rowid.rowid_block_number(rowid))
                FROM m08a_c_line WHERE order_id = t.id) LOOP
      m08_meter.record('s1a-' || b.v || '-k' || t.k || '-blocks', b.n);
    END LOOP;
  END LOOP;
END;
/

-- ===== Assertions =====

-- Same content: every reader's tables return the same rows for each target, the
-- order fields and all k lines (doc and dv read through json_table).
with src as (
  select 'doc' v, d.data."_id".number() id, d.data.customer.string() customer,
         d.data.status.string() status, j.line_id, j.sku, j.qty
    from m08a_doc d,
         json_table(d.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                   sku varchar2(20) path '$.sku', qty number path '$.qty')) j
   where d.data."_id" in (900011, 900012, 900013, 900014)
  union all
  select 'heap', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_h_line l on l.order_id = o.id where o.id in (900011, 900012, 900013, 900014)
  union all
  select 'cov', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_v_line l on l.order_id = o.id where o.id in (900011, 900012, 900013, 900014)
  union all
  select 'iot', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_ord o join m08a_i_line l on l.order_id = o.id where o.id in (900011, 900012, 900013, 900014)
  union all
  select 'clu', o.id, o.customer, o.status, l.line_id, l.sku, l.qty
    from m08a_c_ord o join m08a_c_line l on l.order_id = o.id where o.id in (900011, 900012, 900013, 900014)
  union all
  select 'dv', v.data."_id".number(), v.data.customer.string(), v.data.status.string(),
         j.line_id, j.sku, j.qty
    from m08a_i_dv v,
         json_table(v.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                   sku varchar2(20) path '$.sku', qty number path '$.qty')) j
   where v.data."_id" in (900011, 900012, 900013, 900014)
),
g as (
  select id, count(*) n, count(distinct v) nv
    from src group by id, customer, status, line_id, sku, qty
),
ks as (select 900010 + level id, power(10, level - 1) k from dual connect by level <= 4)
select 'ASSERT:s1a-same-content-k' || ks.k || ':' ||
       case when (select count(*) from g where g.id = ks.id) = ks.k
             and (select count(*) from g where g.id = ks.id and (g.n <> 6 or g.nv <> 6)) = 0
             and (select count(*) from m08_metrics where name like 's1a-%-k' || ks.k || '-reads') = 6
            then 'PASS' else 'FAIL' end
  from ks
 order by ks.k;

-- The duality view returns the same document as the collection (k <= 100).
select 'ASSERT:s1a-dv-same-document:' ||
       case when (select count(*) from (
                    select json_serialize(json_transform(v.data, remove '$._metadata') returning varchar2(32767))
                      from m08a_i_dv v where v.data."_id" in (900011, 900012, 900013)
                    minus
                    select json_serialize(d.data returning varchar2(32767))
                      from m08a_doc d where d.data."_id" in (900011, 900012, 900013))) = 0
             and (select count(*) from m08a_i_dv v where v.data."_id" in (900011, 900012, 900013)) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- Plans. Each marker names one reader; every measured cursor with that marker
-- (the reads block's and measure_repeat's, at least two) must have the access
-- path under test.
--   iot : INDEX RANGE SCAN on the IOT primary key
--   clu : TABLE ACCESS CLUSTER on the cluster's line table
--   cov : an INDEX RANGE SCAN on the covering index, and no TABLE ACCESS on the line table
--   dv  : tracks iot (INDEX RANGE SCAN on the IOT primary key)
with m (marker, ok_op, ok_opt, ok_obj, bad_obj) as (
  select 'M08AIOT', 'INDEX', 'RANGE SCAN', 'M08A_I_LINE_PK', null from dual union all
  select 'M08ACLU', 'TABLE ACCESS', 'CLUSTER', 'M08A_C_LINE', null from dual union all
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
             and p.operation = 'TABLE ACCESS' and p.object_name = m.bad_obj) bad
    from m join v$sql s on upper(s.sql_text) like '%/*+ ' || m.marker || ' */%'
   where s.object_status = 'VALID'
     and s.command_type = 3                -- the SELECT itself, not the PL/SQL block around it
     and upper(s.sql_text) not like '%V$SQL%'
)
select 'ASSERT:s1a-plan-' || lower(substr(m.marker, 5)) || ':' ||
       case when (select count(*) from cur where cur.marker = m.marker) >= 2
             and (select count(*) from cur where cur.marker = m.marker and (cur.good = 0 or cur.bad > 0)) = 0
            then 'PASS' else 'FAIL' end
  from m
 order by m.marker;

-- Every measured statement used an index, and none scanned a whole table.
select 'ASSERT:s1a-plans-indexed:' ||
       case when (select count(distinct m.marker)
                    from (select column_value marker from table(sys.odcivarchar2list(
                            'M08ADOC', 'M08AHEAP', 'M08ACOV', 'M08AIOT', 'M08ACLU', 'M08ADV'))) m
                   where exists (select 1 from v$sql s join v$sql_plan p
                                     on p.sql_id = s.sql_id and p.child_number = s.child_number
                                  where upper(s.sql_text) like '%/*+ ' || m.marker || ' */%'
                                    and s.object_status = 'VALID'
                                    and p.operation = 'INDEX')) = 6
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
        or name like '%-elapsed-cs-median' or name like '%-elapsed-cs-max')
 order by name;

-- ===== Teardown =====
-- Clear this script's rows (and S1's handed-off 'ref:' rows) first: the DDL
-- below commits, so the validator's rollback would not remove them.
delete from m08_metrics where name like 's1a-%' or name like 'tmp:s1a-%' or name like 'ref:s1-%';

drop view if exists m08a_i_dv;
drop table if exists m08a_h_line purge;
drop table if exists m08a_v_line purge;
drop table if exists m08a_i_line purge;
drop table if exists m08a_ord purge;
drop table if exists m08a_doc purge;
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM user_clusters WHERE cluster_name = 'M08A_CLU';
  IF n > 0 THEN
    EXECUTE IMMEDIATE 'DROP CLUSTER m08a_clu INCLUDING TABLES CASCADE CONSTRAINTS';
  END IF;
END;
/

select 'ASSERT:s1a-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08A\_%' escape '\') = 0
             and (select count(*) from m08_metrics
                   where name like 's1a-%' or name like 'tmp:s1a-%' or name like 'ref:s1-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
