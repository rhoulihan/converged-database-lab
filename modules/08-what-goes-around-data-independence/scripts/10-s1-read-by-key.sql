-- S1, read by key: read one order and all of its lines, four ways.
--   doc  : one document from a JSON collection table, found through its _id index
--   join : the order row joined to its line rows
--   dv   : the same order through a duality view (which is a join underneath)
--   n1   : the record-at-a-time interface: one query for the key list, then one
--          fetch per line
-- Each read runs twice; only the second run is measured (no parse cost).
-- Cost is 'session logical reads' (buffer visits), corrected for the meter's own
-- overhead. Target orders have k = 1, 10, 100 and 1000 lines, in two layouts:
--   clustered  : each order's lines are inserted together (what physical
--                clustering buys)
--   interleaved: lines arrive round-robin across 200 orders that are open at once,
--                so about one block per line (a constructed upper bound: a heap
--                with a single-column FK index)

-- Clean up anything left by an earlier, interrupted run.
drop view if exists m08_ord_dv;
drop table if exists m08_line purge;
drop table if exists m08_ord purge;
drop table if exists m08_ord_doc purge;
delete from m08_metrics where name like 's1-%' or name like 'tmp:s1-%' or name like 'ref:s1-%';

-- ===== Projections =====

create table m08_ord (
  id       number primary key,
  customer varchar2(40),
  status   varchar2(12)
);

create table m08_line (
  line_id  varchar2(36) primary key,
  order_id number not null references m08_ord,
  sku      varchar2(20),
  qty      number
);

create index m08_line_order_ix on m08_line (order_id);

create json collection table m08_ord_doc;

-- ===== Data =====
-- Line plan: one row per line with the order it belongs to and its insert position.
-- Clustered phase (phase 1): 2,000 filler orders (ids 1..2000) of 10 lines, with the
-- clustered targets (ids 900001..900004, k = 1, 10, 100, 1000) inserted in the middle;
-- every order's lines are contiguous.
-- Interleaved phase (phase 2): 200 slots, 1,000 rounds; each round inserts one line
-- for every slot. Slots 0..3 hold the interleaved targets (ids 900011..900014);
-- every other slot, and a target slot once its target is complete, holds a stream
-- of 10-line filler orders, so 200 orders stay open for the whole phase and each
-- target line sits about 200 rows (roughly one block) away from the next.
create table m08_line_plan as
with t (slot, k) as (
  select 0, 1 from dual union all select 1, 10 from dual
  union all select 2, 100 from dual union all select 3, 1000 from dual
),
clustered as (
  select o.id order_id, n, 1 phase,
         case when o.id <= 1000 then o.id else o.id + 4 end pos1, n pos2
    from (select level id from dual connect by level <= 2000) o,
         (select level - 1 n from dual connect by level <= 10)
  union all
  select 900001 + t.slot, l.n, 1, 1001 + t.slot, l.n
    from t, (select level - 1 n from dual connect by level <= 1000) l
   where l.n < t.k
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

insert into m08_ord (id, customer, status)
  select order_id, 'customer-' || mod(order_id, 500), 'OPEN'
    from (select distinct order_id from m08_line_plan);

-- Insert lines in plan order: this is what sets the physical layout.
insert into m08_line (line_id, order_id, sku, qty)
  select 'L' || order_id || '-' || n, order_id,
         'SKU-' || lpad(mod(order_id * 7 + n, 5000), 4, '0'), mod(n, 5) + 1
    from m08_line_plan
   order by phase, pos1, pos2;

drop table m08_line_plan purge;

-- The document projection carries the same content: the order and all its lines.
insert into m08_ord_doc (data)
  select json {'_id': o.id, 'customer': o.customer, 'status': o.status,
               'lines': (select json_arrayagg(json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty}
                                              order by l.line_id returning json)
                           from m08_line l where l.order_id = o.id)}
    from m08_ord o;

commit;

-- The duality view: lines keyed by lineId; the order_id foreign key is joined on, not selected.
create or replace json relational duality view m08_ord_dv as
  select json {'_id': o.id, 'customer': o.customer, 'status': o.status,
               'lines': [select json {'lineId': l.line_id, 'sku': l.sku, 'qty': l.qty} from m08_line l where l.order_id = o.id]}
    from m08_ord o;

BEGIN
  dbms_stats.gather_table_stats(user, 'M08_ORD', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08_LINE', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08_ORD_DOC', cascade => true);
END;
/

-- ===== Measurement =====
-- Meter overhead: snap then delta with no work in between. Measured twice; the
-- second (warm) result is kept and subtracted from every measurement below.
DECLARE
  r NUMBER;
  e NUMBER;
BEGIN
  FOR i IN 1 .. 2 LOOP
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
    e := m08_meter.delta('execute count');
  END LOOP;
  m08_meter.record('s1-meter-overhead-reads', r);
  m08_meter.record('s1-meter-overhead-execs', e);
END;
/

-- Document: one indexed lookup on _id.
-- The reader serializes the document so its bytes are really read. Fetching the
-- JSON column into PL/SQL alone returns a LOB locator and skips the body, which
-- would undercount a large document. A client fetch of the 1,000-line document
-- costs the same logical reads as this serialized read.
DECLARE
  TYPE t_json IS TABLE OF BLOB;
  TYPE t_num  IS TABLE OF NUMBER;
  TYPE t_str  IS TABLE OF VARCHAR2(20);
  ids  t_num := t_num(900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014);
  ks   t_num := t_num(1, 10, 100, 1000, 1, 10, 100, 1000);
  lay  t_str := t_str('clustered', 'clustered', 'clustered', 'clustered',
                      'interleaved', 'interleaved', 'interleaved', 'interleaved');
  v    t_json;
  ovr  NUMBER;
  r    NUMBER;
  PROCEDURE q(p_id NUMBER) IS
  BEGIN
    SELECT /*+ M08S1DOC */ json_serialize(d.data returning blob) BULK COLLECT INTO v
      FROM m08_ord_doc d WHERE d.data."_id" = p_id;
    IF v.COUNT <> 1 THEN RAISE_APPLICATION_ERROR(-20810, 'doc rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1-meter-overhead-reads';
  FOR i IN 1 .. ids.COUNT LOOP
    q(ids(i));
    m08_meter.snap;
    q(ids(i));
    r := m08_meter.delta('session logical reads');
    m08_meter.record('s1-doc-' || lay(i) || '-k' || ks(i) || '-reads', GREATEST(r - ovr, 0));
  END LOOP;
END;
/

-- Join: the order row joined to its line rows through the order_id index.
DECLARE
  TYPE t_row IS RECORD (id NUMBER, customer VARCHAR2(40), status VARCHAR2(12),
                        line_id VARCHAR2(36), sku VARCHAR2(20), qty NUMBER);
  TYPE t_rows IS TABLE OF t_row;
  TYPE t_num  IS TABLE OF NUMBER;
  TYPE t_str  IS TABLE OF VARCHAR2(20);
  ids  t_num := t_num(900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014);
  ks   t_num := t_num(1, 10, 100, 1000, 1, 10, 100, 1000);
  lay  t_str := t_str('clustered', 'clustered', 'clustered', 'clustered',
                      'interleaved', 'interleaved', 'interleaved', 'interleaved');
  v    t_rows;
  ovr  NUMBER;
  r    NUMBER;
  PROCEDURE q(p_id NUMBER, p_k NUMBER) IS
  BEGIN
    SELECT /*+ M08S1JOIN */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
      BULK COLLECT INTO v
      FROM m08_ord o JOIN m08_line l ON l.order_id = o.id
     WHERE o.id = p_id;
    IF v.COUNT <> p_k THEN RAISE_APPLICATION_ERROR(-20811, 'join rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1-meter-overhead-reads';
  FOR i IN 1 .. ids.COUNT LOOP
    q(ids(i), ks(i));
    m08_meter.snap;
    q(ids(i), ks(i));
    r := m08_meter.delta('session logical reads');
    m08_meter.record('s1-join-' || lay(i) || '-k' || ks(i) || '-reads', GREATEST(r - ovr, 0));
  END LOOP;
END;
/

-- Duality view: the same document shape, built by a join at read time.
-- Serialized exactly like the document reader.
DECLARE
  TYPE t_json IS TABLE OF BLOB;
  TYPE t_num  IS TABLE OF NUMBER;
  TYPE t_str  IS TABLE OF VARCHAR2(20);
  ids  t_num := t_num(900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014);
  ks   t_num := t_num(1, 10, 100, 1000, 1, 10, 100, 1000);
  lay  t_str := t_str('clustered', 'clustered', 'clustered', 'clustered',
                      'interleaved', 'interleaved', 'interleaved', 'interleaved');
  v    t_json;
  ovr  NUMBER;
  r    NUMBER;
  PROCEDURE q(p_id NUMBER) IS
  BEGIN
    SELECT /*+ M08S1DV */ json_serialize(d.data returning blob) BULK COLLECT INTO v
      FROM m08_ord_dv d WHERE d.data."_id" = p_id;
    IF v.COUNT <> 1 THEN RAISE_APPLICATION_ERROR(-20812, 'dv rows ' || v.COUNT); END IF;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1-meter-overhead-reads';
  FOR i IN 1 .. ids.COUNT LOOP
    q(ids(i));
    m08_meter.snap;
    q(ids(i));
    r := m08_meter.delta('session logical reads');
    m08_meter.record('s1-dv-' || lay(i) || '-k' || ks(i) || '-reads', GREATEST(r - ovr, 0));
  END LOOP;
END;
/

-- Record-at-a-time interface: one query for the key list, then one fetch per line
-- by primary key. This is the access style Stonebraker and Pavlo describe as "a
-- lower-level, record-at-a-time interface" (SIGMOD Record 2024, section 2.3).
-- The metric and marker names keep the short label n1.
DECLARE
  TYPE t_num  IS TABLE OF NUMBER;
  TYPE t_str  IS TABLE OF VARCHAR2(20);
  TYPE t_key  IS TABLE OF VARCHAR2(36);
  ids  t_num := t_num(900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014);
  ks   t_num := t_num(1, 10, 100, 1000, 1, 10, 100, 1000);
  lay  t_str := t_str('clustered', 'clustered', 'clustered', 'clustered',
                      'interleaved', 'interleaved', 'interleaved', 'interleaved');
  cust t_str;
  stat t_str;
  keys t_key;
  sku  VARCHAR2(20);
  qty  NUMBER;
  ovr  NUMBER;
  ove  NUMBER;
  r    NUMBER;
  e    NUMBER;
  PROCEDURE q(p_id NUMBER, p_k NUMBER) IS
  BEGIN
    SELECT /*+ M08S1N1P */ o.customer, o.status, l.line_id
      BULK COLLECT INTO cust, stat, keys
      FROM m08_ord o JOIN m08_line l ON l.order_id = o.id
     WHERE o.id = p_id;
    IF keys.COUNT <> p_k THEN RAISE_APPLICATION_ERROR(-20813, 'n1 keys ' || keys.COUNT); END IF;
    FOR j IN 1 .. keys.COUNT LOOP
      SELECT /*+ M08S1N1C */ l.sku, l.qty INTO sku, qty
        FROM m08_line l WHERE l.line_id = keys(j);
    END LOOP;
  END q;
BEGIN
  SELECT value INTO ovr FROM m08_metrics WHERE name = 's1-meter-overhead-reads';
  SELECT value INTO ove FROM m08_metrics WHERE name = 's1-meter-overhead-execs';
  FOR i IN 1 .. ids.COUNT LOOP
    q(ids(i), ks(i));
    m08_meter.snap;
    q(ids(i), ks(i));
    r := m08_meter.delta('session logical reads');
    e := m08_meter.delta('execute count');
    m08_meter.record('s1-n1-' || lay(i) || '-k' || ks(i) || '-reads', GREATEST(r - ovr, 0));
    m08_meter.record(CASE lay(i) WHEN 'clustered' THEN 's1-n1-k' || ks(i) || '-execs'
                                 ELSE 'tmp:s1-n1-interleaved-k' || ks(i) || '-execs' END,
                     GREATEST(e - ove, 0));
  END LOOP;
END;
/

-- All three readers return the same logical content: the order and all its lines.
select 'ASSERT:s1-same-content:' ||
       case when (select count(*) from (
                    select d.data."_id".number() id, d.data.customer.string() customer, d.data.status.string() status,
                           j.line_id, j.sku, j.qty
                      from m08_ord_doc d,
                           json_table(d.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                                     sku varchar2(20) path '$.sku', qty number path '$.qty')) j
                     where d.data."_id" in (900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014)
                    minus
                    select o.id, o.customer, o.status, l.line_id, l.sku, l.qty
                      from m08_ord o join m08_line l on l.order_id = o.id
                     where o.id in (900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014))) = 0
             and (select count(*) from (
                    select o.id, o.customer, o.status, l.line_id, l.sku, l.qty
                      from m08_ord o join m08_line l on l.order_id = o.id
                     where o.id in (900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014)
                    minus
                    select d.data."_id".number(), d.data.customer.string(), d.data.status.string(),
                           j.line_id, j.sku, j.qty
                      from m08_ord_doc d,
                           json_table(d.data, '$.lines[*]' columns (line_id varchar2(36) path '$.lineId',
                                                                     sku varchar2(20) path '$.sku', qty number path '$.qty')) j
                     where d.data."_id" in (900001, 900002, 900003, 900004, 900011, 900012, 900013, 900014))) = 0
             and (select count(*) from (
                    select json_serialize(json_transform(v.data, remove '$._metadata') returning varchar2(32767))
                      from m08_ord_dv v where v.data."_id" in (900001, 900002, 900003)
                    minus
                    select json_serialize(d.data returning varchar2(32767))
                      from m08_ord_doc d where d.data."_id" in (900001, 900002, 900003))) = 0
             and (select sum(json_value(v.data, '$.lines.size()' returning number)) from m08_ord_dv v
                   where v.data."_id" in (900004, 900011, 900012, 900013, 900014)) = 1000 + 1 + 10 + 100 + 1000
            then 'PASS' else 'FAIL' end
  from dual;

-- The interleaved targets really are spread out: their lines occupy far more blocks.
select 'ASSERT:s1-interleaved-spread:' ||
       case when (select count(distinct dbms_rowid.rowid_block_number(rowid)) from m08_line where order_id = 900014)
               >= 10 * (select count(distinct dbms_rowid.rowid_block_number(rowid)) from m08_line where order_id = 900004)
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Measurements (as METRIC rows) =====
select 'METRIC:' || name || ':' || to_char(value, 'FM999999990')
  from m08_metrics
 where name like 's1-%'
 order by name;

-- ===== Assertions (read back from m08_metrics) =====

-- The document read never costs more logical reads than the join.
with ls as (select column_value l from table(sys.odcivarchar2list('clustered', 'interleaved'))),
     ks as (select column_value k from table(sys.odcinumberlist(1, 10, 100, 1000)))
select 'ASSERT:s1-doc-le-join-' || l || '-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1-doc-' || l || '-k' || k || '-reads') <=
                 (select value from m08_metrics where name = 's1-join-' || l || '-k' || k || '-reads')
            then 'PASS' else 'FAIL' end
  from ls, ks
 order by l, k;

-- The document reader really reads the body: a 1,000-line document costs more than a 1-line one.
select 'ASSERT:s1-doc-body-read:' ||
       case when (select value from m08_metrics where name = 's1-doc-clustered-k1000-reads') >
                 (select value from m08_metrics where name = 's1-doc-clustered-k1-reads')
            then 'PASS' else 'FAIL' end
  from dual;

-- The duality view is a join: it is never cheaper than the document.
with ls as (select column_value l from table(sys.odcivarchar2list('clustered', 'interleaved'))),
     ks as (select column_value k from table(sys.odcinumberlist(1, 10, 100, 1000)))
select 'ASSERT:s1-dv-ge-doc-' || l || '-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1-dv-' || l || '-k' || k || '-reads') >=
                 (select value from m08_metrics where name = 's1-doc-' || l || '-k' || k || '-reads')
            then 'PASS' else 'FAIL' end
  from ls, ks
 order by l, k;

-- The join's cost grows with the number of lines.
with ls as (select column_value l from table(sys.odcivarchar2list('clustered', 'interleaved')))
select 'ASSERT:s1-join-grows-' || l || ':' ||
       case when (select value from m08_metrics where name = 's1-join-' || l || '-k1000-reads') >
                 (select value from m08_metrics where name = 's1-join-' || l || '-k10-reads')
            then 'PASS' else 'FAIL' end
  from ls
 order by l;

-- The record-at-a-time reader runs exactly k+1 statements (both layouts).
with ks as (select column_value k from table(sys.odcinumberlist(1, 10, 100, 1000)))
select 'ASSERT:s1-n1-execs-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1-n1-k' || k || '-execs') = k + 1
             and (select value from m08_metrics where name = 'tmp:s1-n1-interleaved-k' || k || '-execs') = k + 1
            then 'PASS' else 'FAIL' end
  from ks
 order by k;

-- Every measured statement used an index, and none scanned a whole table.
select 'ASSERT:s1-plans-indexed:' ||
       case when (select count(distinct m.marker)
                    from (select 'M08S1DOC' marker from dual union all select 'M08S1JOIN' from dual
                          union all select 'M08S1DV' from dual union all select 'M08S1N1P' from dual
                          union all select 'M08S1N1C' from dual) m
                   where exists (select 1 from v$sql s join v$sql_plan p
                                     on p.sql_id = s.sql_id and p.child_number = s.child_number
                                  where upper(s.sql_text) like '%/*+ ' || m.marker || ' */%'
                                    and s.object_status = 'VALID'
                                    and p.operation = 'INDEX')) = 5
             and (select count(*) from v$sql s join v$sql_plan p
                      on p.sql_id = s.sql_id and p.child_number = s.child_number
                   where upper(s.sql_text) like '%/*+ M08' || 'S1%'
                     and s.object_status = 'VALID'
                     and p.operation = 'TABLE ACCESS' and p.options like '%FULL%') = 0
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Hand the interleaved document and join reads to 12-s1-physical-join.sql,
-- which checks that its heap baseline reproduces them. These 'ref:' rows stay
-- in the session table until that script (or 99-teardown.sql) removes them.
insert into m08_metrics (name, value)
  select 'ref:' || name, value from m08_metrics
   where name like 's1-join-interleaved-k%-reads' or name like 's1-doc-interleaved-k%-reads';

-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's1-%' or name like 'tmp:s1-%';

drop view if exists m08_ord_dv;
drop table if exists m08_line purge;
drop table if exists m08_ord purge;
drop table if exists m08_ord_doc purge;

select 'ASSERT:s1-teardown-clean:' ||
       case when (select count(*) from user_objects
                   where object_name like 'M08\_ORD%' escape '\'
                      or object_name like 'M08\_LINE%' escape '\') = 0
             and (select count(*) from m08_metrics
                   where name like 's1-%' or name like 'tmp:s1-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
