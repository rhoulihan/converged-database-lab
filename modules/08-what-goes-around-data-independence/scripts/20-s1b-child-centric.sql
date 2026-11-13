-- S1b, child-centric query: "the line items with sku X1", read three ways.
--   childtable: the line rows, found through an index on sku. No join.
--   orderdocs : order documents, found through a multivalue index on items[*].sku.
--               Two readers, and the cheaper one counts (the documents' best plan,
--               as the join got its best plan in S1):
--                 jsontable : JSON_TABLE pulls the matching item out of each order
--                 serialized: the matching whole orders are fetched serialized, as a
--                             client would before filtering
--   itemdv    : an item-centric duality view whose root is the line table,
--               filtered on sku.
-- All of them return the same content: line_id and qty for the 20 matching lines.
--
-- What to expect. A document stored inside its row costs the same one block as a
-- line row, so reading whole orders to find one item costs nothing extra while
-- the documents fit in their rows (k = 10 and 100 here). Once a document outgrows
-- its row and is stored out of line (k = 1000 here, about 50 KB), every match
-- reads the whole order, and the order documents overpay.
-- sku X1 sits in exactly 20 lines spread over 20 orders. The orders have k = 10,
-- 100 or 1000 lines; each k gets its own freshly built data, so one measurement
-- sees one k. Layout is clustered: each order's lines are inserted together.
-- Each read runs twice; only the second run is measured (no parse cost).
-- Cost is 'session logical reads' (buffer visits), corrected for the meter's own
-- overhead.
--
-- Knob 1 (how often each query runs). The same data also serves the S1 read, one
-- order by key, measured here at the same k:
--   doc  : the order document by _id, serialized so its body is really read
--   join : the order row joined to its line rows
-- For a workload of 1,000 order reads plus q item queries, the two designs cost
--   documents : 1000*doc  + q*orderdocs      (orderdocs = the cheaper reader)
--   normalized: 1000*join + q*childtable
-- They are equal at the crossover
--   q = 1000 * (join - doc) / (orderdocs - childtable)
-- Above q item queries per 1,000 order reads, normalized tables do less work;
-- below it, documents do. Which way to go is knob 1: how often the item query runs.
-- With in-row documents (k = 10, 100) orderdocs - childtable <= 0: documents never
-- do more work, so there is no crossover (s1b-no-crossover-k<k> = 1).

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08b_load;
drop procedure if exists m08b_measure;
drop procedure if exists m08b_build;
drop view if exists m08b_item_dv;
drop table if exists m08b_line purge;
drop table if exists m08b_ord purge;
drop table if exists m08b_ord_doc purge;
delete from m08_metrics where name like 's1b-%' or name like 'tmp:s1b-%';

-- ===== Projections =====
-- m08b_build(k) drops and recreates them, so each k starts from empty tables.
--   m08b_ord     : the order rows
--   m08b_line    : the line rows, keyed by line_id; order_id is a plain NOT NULL
--                  foreign key; indexes on order_id and on sku
--   m08b_ord_doc : the same orders as documents, with a multivalue index on
--                  items[*].sku
--   m08b_item_dv : one document per line, rooted on m08b_line (order_id not selected)
create or replace procedure m08b_build(p_k number) as
  procedure ddl(p_sql varchar2) is begin execute immediate p_sql; end;
begin
  ddl('drop view if exists m08b_item_dv');
  ddl('drop table if exists m08b_line purge');
  ddl('drop table if exists m08b_ord purge');
  ddl('drop table if exists m08b_ord_doc purge');
  ddl('create table m08b_ord (id number primary key, customer varchar2(40), status varchar2(12))');
  ddl('create table m08b_line (line_id varchar2(36) primary key,
                               order_id number not null references m08b_ord,
                               sku varchar2(20), qty number)');
  ddl('create index m08b_line_order_ix on m08b_line (order_id)');
  ddl('create index m08b_line_sku_ix on m08b_line (sku)');
  ddl('create json collection table m08b_ord_doc');
  ddl('create multivalue index m08b_doc_sku_ix on m08b_ord_doc d (d.data.items[*].sku.string())');
  ddl('create json relational duality view m08b_item_dv as
         select json {''_id'': l.line_id, ''sku'': l.sku, ''qty'': l.qty} from m08b_line l');
end;
/

begin
  m08b_build(10);
end;
/

-- ===== Data =====
-- 2,000 filler orders (ids 1..2000) of 10 lines, and 20 target orders
-- (ids 900001..900020) of k lines. Target t is inserted right after filler t*100,
-- so the 20 targets sit in different blocks. Each target's middle line (n = k/2)
-- has sku X1; no other line does. Lines are inserted order by order (clustered),
-- and the documents are inserted in the same order, built from the line rows.
create or replace procedure m08b_load(p_k number) as
begin
  insert into m08b_ord (id, customer, status)
    select id, 'customer-' || mod(id, 500), 'OPEN'
      from (select level id from dual connect by level <= 2000
            union all
            select 900000 + level from dual connect by level <= 20);

  insert into m08b_line (line_id, order_id, sku, qty)
    select 'L' || o.id || '-' || n.n, o.id,
           case when o.id > 900000 and n.n = floor(p_k / 2) then 'X1'
                else 'SKU-' || lpad(mod(o.id * 7 + n.n, 5000), 4, '0') end,
           mod(n.n, 5) + 1
      from m08b_ord o, (select level - 1 n from dual connect by level <= p_k) n
     where o.id > 900000 or n.n < 10
     order by case when o.id > 900000 then (o.id - 900000) * 100 + 0.5 else o.id end, n.n;

  insert into m08b_ord_doc (data)
    -- json_object, not the json {...} constructor: inside PL/SQL, ': o.id' would
    -- parse as a bind variable.
    select json_object('_id' value o.id, 'customer' value o.customer, 'status' value o.status,
                       'items' value (select json_arrayagg(json_object('lineId' value l.line_id,
                                                                       'sku' value l.sku,
                                                                       'qty' value l.qty)
                                                           order by l.line_id returning json)
                                        from m08b_line l where l.order_id = o.id)
                       returning json)
      from m08b_ord o
     order by case when o.id > 900000 then (o.id - 900000) * 100 + 0.5 else o.id end;
  commit;

  dbms_stats.gather_table_stats(user, 'M08B_ORD', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08B_LINE', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08B_ORD_DOC', cascade => true);
end;
/

-- ===== Measurement =====
-- Meter overhead: snap then delta with no work in between. Measured twice; the
-- second (warm) result is kept and subtracted from every measurement below.
declare
  r number;
begin
  for i in 1 .. 2 loop
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
  end loop;
  m08_meter.record('s1b-meter-overhead-reads', r);
end;
/

-- m08b_measure(k): run each reader twice, record the second run, then check that
-- the three item readers returned the same pairs and that every plan used an index.
create or replace procedure m08b_measure(p_k number) as
  type t_key  is table of varchar2(36);
  type t_num  is table of number;
  type t_blob is table of blob;
  type t_row  is record (id number, customer varchar2(40), status varchar2(12),
                         line_id varchar2(36), sku varchar2(20), qty number);
  type t_rows is table of t_row;
  type t_map  is table of number index by varchar2(36);
  ods    t_blob;
  type t_skey is table of varchar2(36) index by pls_integer;
  type t_sqty is table of number index by pls_integer;
  ser    t_skey;
  serq   t_sqty;
  ct_key t_key; ct_qty t_num;
  od_key t_key; od_qty t_num;
  dv_key t_key; dv_qty t_num;
  docs   t_blob;
  jrows  t_rows;
  ovr    number;
  r      number;
  same   number := 1;
  ok     number;
  m      t_map;

  -- child table: the line rows through the sku index. No join.
  procedure childtable is
  begin
    select /*+ M08KIDCT */ l.line_id, l.qty bulk collect into ct_key, ct_qty
      from m08b_line l where l.sku = 'X1';
  end;
  -- order documents: whole orders through the multivalue index, then the item.
  procedure orderdocs is
  begin
    select /*+ M08KIDOD */ jt.line_id, jt.qty bulk collect into od_key, od_qty
      from m08b_ord_doc d,
           json_table(d.data, '$.items[*]'
                      columns (line_id varchar2(36) path '$.lineId',
                               sku     varchar2(20) path '$.sku',
                               qty     number       path '$.qty')) jt
     where json_exists(d.data, '$.items[*]?(@.sku == "X1")')
       and jt.sku = 'X1';
  end;
  -- order documents, serialized: the matching whole orders through the same index.
  procedure orderdocs_ser is
  begin
    select /*+ M08KIDODS */ json_serialize(d.data returning blob) bulk collect into ods
      from m08b_ord_doc d
     where json_exists(d.data, '$.items[*]?(@.sku == "X1")');
  end;
  -- item-centric duality view: rooted on the line table, filtered on sku.
  procedure itemdv is
  begin
    select /*+ M08KIDDV */ v.data."_id".string(), v.data.qty.number()
      bulk collect into dv_key, dv_qty
      from m08b_item_dv v where v.data.sku.string() = 'X1';
  end;
  -- S1 order read by key, as a document (serialized so the body is really read).
  procedure doc is
  begin
    select /*+ M08KIDDOC */ json_serialize(d.data returning blob) bulk collect into docs
      from m08b_ord_doc d where d.data."_id" = 900001;
    if docs.count <> 1 then raise_application_error(-20820, 'doc rows ' || docs.count); end if;
  end;
  -- S1 order read by key, as the order row joined to its line rows.
  procedure joinread is
  begin
    select /*+ M08KIDJOIN */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty
      bulk collect into jrows
      from m08b_ord o join m08b_line l on l.order_id = o.id
     where o.id = 900001;
    if jrows.count <> p_k then raise_application_error(-20821, 'join rows ' || jrows.count); end if;
  end;

  function r_of(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  procedure measure(p_name varchar2) is
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      case p_name
        when 'childtable' then childtable;
        when 'orderdocs-jsontable'  then orderdocs;
        when 'orderdocs-serialized' then orderdocs_ser;
        when 'itemdv'     then itemdv;
        when 'doc'        then doc;
        when 'join'       then joinread;
      end case;
    end loop;
    r := m08_meter.delta('session logical reads');
    m08_meter.record('s1b-' || p_name || '-k' || p_k || '-reads', greatest(r - ovr, 0));
  end;
begin
  select value into ovr from m08_metrics where name = 's1b-meter-overhead-reads';
  measure('childtable');
  measure('orderdocs-jsontable');
  measure('orderdocs-serialized');
  -- The documents' best plan: the cheaper of the two readers.
  m08_meter.record('s1b-orderdocs-k' || p_k || '-reads',
                   least(r_of('s1b-orderdocs-jsontable-k' || p_k || '-reads'),
                         r_of('s1b-orderdocs-serialized-k' || p_k || '-reads')));
  measure('itemdv');
  measure('doc');
  measure('join');

  -- Same content: the same 20 (line_id, qty) pairs from every item reader. The
  -- serialized orders are filtered here, as the client would.
  if ods.count = 20 then
    for i in 1 .. ods.count loop
      for x in (select jt.line_id, jt.qty
                  from json_table(ods(i) format json, '$.items[*]'
                                  columns (line_id varchar2(36) path '$.lineId',
                                           sku     varchar2(20) path '$.sku',
                                           qty     number       path '$.qty')) jt
                 where jt.sku = 'X1') loop
        ser(ser.count + 1) := x.line_id;
        serq(ser.count) := x.qty;
      end loop;
    end loop;
  end if;
  if ct_key.count <> 20 or od_key.count <> 20 or dv_key.count <> 20 or ser.count <> 20 then
    same := 0;
  else
    for i in 1 .. ct_key.count loop m(ct_key(i)) := ct_qty(i); end loop;
    if m.count <> 20 then same := 0; end if;
    for i in 1 .. 20 loop
      if not m.exists(od_key(i)) or m(od_key(i)) <> od_qty(i)
         or not m.exists(dv_key(i)) or m(dv_key(i)) <> dv_qty(i)
         or not m.exists(ser(i)) or m(ser(i)) <> serq(i) then
        same := 0;
      end if;
    end loop;
  end if;
  m08_meter.record('tmp:s1b-same-content-k' || p_k, same);

  -- Plans: every marker has a valid cursor with an INDEX step and no full table scan.
  select case when (select count(distinct mk.marker)
                      from (select 'M08KIDCT' marker from dual union all select 'M08KIDOD' from dual
                            union all select 'M08KIDODS' from dual
                            union all select 'M08KIDDV' from dual union all select 'M08KIDDOC' from dual
                            union all select 'M08KIDJOIN' from dual) mk
                     where exists (select 1 from v$sql s join v$sql_plan p
                                       on p.sql_id = s.sql_id and p.child_number = s.child_number
                                    where upper(s.sql_text) like '%/*+ ' || mk.marker || ' */%'
                                      and s.object_status = 'VALID'
                                      and p.operation = 'INDEX')) = 6
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where upper(s.sql_text) like '%/*+ M08' || 'KID%'
                       and s.object_status = 'VALID'
                       and p.operation = 'TABLE ACCESS' and p.options like '%FULL%') = 0
              then 1 else 0 end
    into ok from dual;
  m08_meter.record('tmp:s1b-plans-indexed-k' || p_k, ok);
end;
/

-- k = 10 (the tables were built above)
begin
  m08b_load(10);
  m08b_measure(10);
end;
/

-- k = 100
begin
  m08b_build(100);
end;
/

begin
  m08b_load(100);
  m08b_measure(100);
end;
/

-- k = 1000
begin
  m08b_build(1000);
end;
/

begin
  m08b_load(1000);
  m08b_measure(1000);
end;
/

-- Crossover (knob 1), k = 1000 only: q = 1000 * (join - doc) / (orderdocs - childtable),
-- rounded; it is left out unless both terms are positive (s1b-crossover-k1000-positive
-- then fails). For in-row documents (k = 10, 100) record s1b-no-crossover-k<k>: 1 when
-- orderdocs <= childtable (documents never do more work), else 0.
declare
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  for k in (select column_value k from table(sys.odcinumberlist(10, 100))) loop
    m08_meter.record('s1b-no-crossover-k' || k.k,
                     case when v('s1b-orderdocs-k' || k.k || '-reads') <=
                               v('s1b-childtable-k' || k.k || '-reads') then 1 else 0 end);
  end loop;
  declare
    num number := 1000 * (v('s1b-join-k1000-reads') - v('s1b-doc-k1000-reads'));
    den number := v('s1b-orderdocs-k1000-reads') - v('s1b-childtable-k1000-reads');
  begin
    if num > 0 and den > 0 then
      m08_meter.record('s1b-crossover-item-queries-per-1000-order-reads-k1000', round(num / den));
    end if;
  end;
end;
/

-- ===== Measurements (as METRIC rows) =====
select 'METRIC:' || name || ':' || to_char(value, 'FM999999990')
  from m08_metrics
 where name like 's1b-%'
 order by name;

-- ===== Assertions (read back from m08_metrics) =====

-- In-row documents: reading the whole order costs no more than reading the line
-- row (2 reads of slack for block placement).
with ks as (select column_value k from table(sys.odcinumberlist(10, 100)))
select 'ASSERT:s1b-inrow-no-penalty-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k' || k || '-reads') <=
                 (select value from m08_metrics where name = 's1b-childtable-k' || k || '-reads') + 2
            then 'PASS' else 'FAIL' end
  from ks
 order by k;

-- Out-of-row documents: every match reads a whole order, more than twice the child table.
select 'ASSERT:s1b-outofrow-penalty-k1000:' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k1000-reads') >
                 2 * (select value from m08_metrics where name = 's1b-childtable-k1000-reads')
            then 'PASS' else 'FAIL' end
  from dual;

-- The item-centric duality view reads the child table: it stays close to it (at most 2x).
with ks as (select column_value k from table(sys.odcinumberlist(10, 100, 1000)))
select 'ASSERT:s1b-itemdv-close-to-childtable-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1b-itemdv-k' || k || '-reads') <=
                 2 * (select value from m08_metrics where name = 's1b-childtable-k' || k || '-reads')
            then 'PASS' else 'FAIL' end
  from ks
 order by k;

-- The bigger the order, the more the order documents overpay.
select 'ASSERT:s1b-gap-grows-with-k:' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k1000-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k1000-reads'), 0) >
                 (select value from m08_metrics where name = 's1b-orderdocs-k10-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k10-reads'), 0)
            then 'PASS' else 'FAIL' end
  from dual;

-- At k = 1000 there is a finite crossover above zero.
select 'ASSERT:s1b-crossover-k1000-positive:' ||
       case when (select value from m08_metrics
                   where name = 's1b-crossover-item-queries-per-1000-order-reads-k1000') > 0
            then 'PASS' else 'FAIL' end
  from dual;

-- Every item reader returned the same 20 (line_id, qty) pairs at every k.
select 'ASSERT:s1b-same-content:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1b-same-content-k%' and value = 1) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- Every measured statement used an index, and none scanned a whole table, at every k.
select 'ASSERT:s1b-plans-indexed:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1b-plans-indexed-k%' and value = 1) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's1b-%' or name like 'tmp:s1b-%';

drop procedure if exists m08b_load;
drop procedure if exists m08b_measure;
drop procedure if exists m08b_build;
drop view if exists m08b_item_dv;
drop table if exists m08b_line purge;
drop table if exists m08b_ord purge;
drop table if exists m08b_ord_doc purge;

select 'ASSERT:s1b-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08B\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 's1b-%' or name like 'tmp:s1b-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
