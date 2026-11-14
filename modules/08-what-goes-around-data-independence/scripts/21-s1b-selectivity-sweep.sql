-- S1b sweep (C): does the S1b crossover depend on how many orders match?
-- S1b fixed the selectivity at 20 matching orders. This script sweeps it:
-- M = 5, 20, 100 and 500 matching orders, on one data load per order size k
-- (k = 100 and k = 1000 lines per matching order), clustered layout.
--
-- Readers, as in S1b's final design:
--   childtable : line_id and qty from the line table. No join, no hint; the
--                covering index (sku, line_id, qty) can answer alone.
--   orderdocs  : the order documents, found through a multivalue index on
--                items[*].sku. Two readers, the cheaper one counts:
--                  jsontable : JSON_TABLE pulls the matching item out of each order
--                  serialized: the matching whole orders, serialized, as a client
--                              would fetch them before filtering
--   doc, join  : S1's order read by key on the same data (one k-line order):
--                the document by _id (serialized), or the order row joined to its
--                line rows. These do not depend on M.
-- Every item reader must return the same M (line_id, qty) pairs.
--
-- No hints on the item readers. Statistics carry a histogram on every indexed
-- column (FOR ALL INDEXED COLUMNS SIZE 254), so the optimizer sees how many
-- rows each sku has and may pick a different plan at each M. That is the
-- realistic case. Each M uses its own sku literal, so each M gets its own
-- cursor and plan. The executed plan of every measured point is captured with
-- dbms_xplan.display_cursor(..., 'ALLSTATS LAST') and printed as PLAN rows.
--
-- Cost is logical reads on the second execution, minus the meter's overhead,
-- as in S1b. Crossover per point, the same formula as S1b:
--   q = 1000 * (join - doc) / (orderdocs - childtable)
-- It exists only when both terms are positive; otherwise
-- s1c-no-crossover-k<k>-m<M> = 1 is recorded. CPU and elapsed medians
-- (m08_meter.measure_repeat, 20 runs, 1 cs resolution) are recorded for the
-- item readers at M = 100 and 500.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08c1_build;
drop procedure if exists m08c1_load;
drop procedure if exists m08c1_measure;
drop table if exists m08c1_line purge;
drop table if exists m08c1_ord purge;
drop table if exists m08c1_ord_doc purge;
drop table if exists m08c1_plan purge;
delete from m08_metrics where name like 's1c-%' or name like 'tmp:s1c-%';

-- Executed plans, one row per plan line, printed below as PLAN rows.
create table m08c1_plan (k number, m number, reader varchar2(30), n number, line varchar2(400));

-- ===== Projections =====
-- m08c1_build(k) drops and recreates them, so each k starts from empty tables.
--   m08c1_ord     : the order rows
--   m08c1_line    : the line rows, keyed by line_id; order_id is a plain NOT NULL
--                   foreign key; an index on order_id (for the join) and the
--                   covering index on (sku, line_id, qty)
--   m08c1_ord_doc : the same orders as documents, with a multivalue index on
--                   items[*].sku
create or replace procedure m08c1_build as
  procedure ddl(p_sql varchar2) is begin execute immediate p_sql; end;
begin
  ddl('drop table if exists m08c1_line purge');
  ddl('drop table if exists m08c1_ord purge');
  ddl('drop table if exists m08c1_ord_doc purge');
  ddl('create table m08c1_ord (id number primary key, customer varchar2(40), status varchar2(12))');
  ddl('create table m08c1_line (line_id varchar2(36) primary key,
                                order_id number not null references m08c1_ord,
                                sku varchar2(20), qty number)');
  ddl('create index m08c1_line_order_ix on m08c1_line (order_id)');
  ddl('create index m08c1_line_cov_ix on m08c1_line (sku, line_id, qty)');
  ddl('create json collection table m08c1_ord_doc');
  ddl('create multivalue index m08c1_doc_sku_ix on m08c1_ord_doc d (d.data.items[*].sku.string())');
end;
/

-- Build once now, so the load procedure below compiles against the tables.
begin
  m08c1_build;
end;
/

-- ===== Data =====
-- 2,000 filler orders (ids 1..2000) of 10 lines, and 500 matching orders
-- (ids 900001..900500) of k lines. Matching order t is inserted right after
-- filler 4t, so the matching orders are spread through the tables. The skus
-- swept are nested, each in one line of its orders:
--   XM500 : every matching order          (line k/10)
--   XM100 : every 5th   (t mod 5 = 0)     (line 3k/10)
--   XM20  : every 25th  (t mod 25 = 0)    (line k/2)
--   XM5   : every 100th (t mod 100 = 0)   (line 7k/10)
-- No other line has an XM sku. Lines are inserted order by order (clustered),
-- and the documents in the same order, built from the line rows.
create or replace procedure m08c1_load(p_k number) as
begin
  insert into m08c1_ord (id, customer, status)
    select id, 'customer-' || mod(id, 500), 'OPEN'
      from (select level id from dual connect by level <= 2000
            union all
            select 900000 + level from dual connect by level <= 500);

  insert into m08c1_line (line_id, order_id, sku, qty)
    select 'L' || o.id || '-' || n.n, o.id,
           case when o.id > 900000 and n.n = floor(p_k / 10) then 'XM500'
                when o.id > 900000 and n.n = floor(3 * p_k / 10) and mod(o.id - 900000, 5) = 0 then 'XM100'
                when o.id > 900000 and n.n = floor(p_k / 2) and mod(o.id - 900000, 25) = 0 then 'XM20'
                when o.id > 900000 and n.n = floor(7 * p_k / 10) and mod(o.id - 900000, 100) = 0 then 'XM5'
                else 'SKU-' || lpad(mod(o.id * 7 + n.n, 5000), 4, '0') end,
           mod(n.n, 5) + 1
      from m08c1_ord o, (select level - 1 n from dual connect by level <= p_k) n
     where o.id > 900000 or n.n < 10
     order by case when o.id > 900000 then (o.id - 900000) * 4 + 0.5 else o.id end, n.n;

  insert into m08c1_ord_doc (data)
    select json_object('_id' value o.id, 'customer' value o.customer, 'status' value o.status,
                       'items' value (select json_arrayagg(json_object('lineId' value l.line_id,
                                                                       'sku' value l.sku,
                                                                       'qty' value l.qty)
                                                           order by l.line_id returning json)
                                        from m08c1_line l where l.order_id = o.id)
                       returning json)
      from m08c1_ord o
     order by case when o.id > 900000 then (o.id - 900000) * 4 + 0.5 else o.id end;
  commit;

  for t in (select column_value tn from table(sys.odcivarchar2list('M08C1_ORD', 'M08C1_LINE', 'M08C1_ORD_DOC'))) loop
    dbms_stats.gather_table_stats(user, t.tn,
      method_opt => 'FOR ALL COLUMNS SIZE 1 FOR ALL INDEXED COLUMNS SIZE 254',
      cascade => true, no_invalidate => false);
  end loop;
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
  m08_meter.record('s1c-meter-overhead-reads', r);
end;
/

-- m08c1_measure(k): every reader at every M, run twice, the second run counted.
-- Each statement carries a marker last in its hint comment (' <marker> */') so
-- its cursor can be found, and gather_plan_statistics so its executed plan
-- shows rows and buffers per step. The timed copies (measure_repeat) carry
-- their own marker and must run the same plan as the counted cursor.
create or replace procedure m08c1_measure(p_k number) as
  type t_key  is table of varchar2(36);
  type t_num  is table of number;
  type t_blob is table of blob;
  type t_row  is record (id number, customer varchar2(40), status varchar2(12),
                         line_id varchar2(36), sku varchar2(20), qty number);
  type t_rows is table of t_row;
  type t_map  is table of number index by varchar2(36);
  ct_key t_key; ct_qty t_num;
  od_key t_key; od_qty t_num;
  ods    t_blob;
  docs   t_blob;
  jrows  t_rows;
  ovr    number;
  r      number;
  ms     sys.odcinumberlist := sys.odcinumberlist(5, 20, 100, 500);
  pfx    varchar2(30) := 's1c-k' || p_k;

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  function item_sql(p_reader varchar2, p_m number, p_marker varchar2, p_stats boolean) return varchar2 is
    h varchar2(60) := '/*+ ' || case when p_stats then 'gather_plan_statistics ' end || p_marker || ' */';
  begin
    return case p_reader
      when 'childtable' then
        'select ' || h || ' l.line_id, l.qty from m08c1_line l where l.sku = ''XM' || p_m || ''''
      when 'orderdocs-jsontable' then
        'select ' || h || ' jt.line_id, jt.qty from m08c1_ord_doc d, json_table(d.data, ''$.items[*]'''
        || ' columns (line_id varchar2(36) path ''$.lineId'', sku varchar2(20) path ''$.sku'','
        || ' qty number path ''$.qty'')) jt'
        || ' where json_exists(d.data, ''$.items[*]?(@.sku == "XM' || p_m || '")'') and jt.sku = ''XM' || p_m || ''''
      when 'orderdocs-serialized' then
        'select ' || h || ' json_serialize(d.data returning blob) from m08c1_ord_doc d'
        || ' where json_exists(d.data, ''$.items[*]?(@.sku == "XM' || p_m || '")'')'
    end;
  end;

  -- The newest valid cursor whose text ends its hint with p_marker.
  procedure find_cursor(p_marker varchar2, p_sqlid out varchar2, p_child out number, p_phv out number) is
    pat varchar2(80) := '% ' || p_marker || ' */%';
  begin
    select sql_id, child_number, plan_hash_value into p_sqlid, p_child, p_phv
      from (select sql_id, child_number, plan_hash_value
              from v$sql
             where sql_text like pat and object_status = 'VALID'
             order by last_active_time desc, child_number desc)
     where rownum = 1;
  end;

  -- Store the executed plan and the plan facts the checks need.
  procedure capture(p_reader varchar2, p_m number, p_marker varchar2) is
    sid varchar2(13);
    chn number;
    phv number;
    nb  number;
    nm  varchar2(100) := pfx || case when p_m is not null then '-m' || p_m end || '-' || p_reader;
  begin
    find_cursor(p_marker, sid, chn, phv);
    insert into m08c1_plan (k, m, reader, n, line)
      select p_k, p_m, p_reader, rownum, substr(plan_table_output, 1, 400)
        from table(dbms_xplan.display_cursor(sid, chn, 'ALLSTATS LAST'));
    m08_meter.record('tmp:' || nm || '-phv', phv);
    -- The plan header of an ALLSTATS LAST plan has a Buffers column.
    select count(*) into nb from m08c1_plan
     where k = p_k and (m = p_m or (m is null and p_m is null))
       and reader = p_reader and line like '%Buffers%';
    m08_meter.record('tmp:' || nm || '-xplan-buffers', nb);
    -- Access-path facts, read from the executed cursor's plan.
    for p in (select
                count(case when operation = 'INDEX' and object_name = 'M08C1_LINE_COV_IX' then 1 end) cov,
                count(case when operation = 'TABLE ACCESS' and object_name = 'M08C1_LINE' then 1 end) linetab,
                count(case when operation = 'INDEX' and object_name = 'M08C1_DOC_SKU_IX' then 1 end) mvix,
                count(case when operation = 'TABLE ACCESS' and options like '%FULL%' then 1 end) full_scans
                from v$sql_plan where sql_id = sid and child_number = chn) loop
      m08_meter.record('tmp:' || nm || '-cov', p.cov);
      m08_meter.record('tmp:' || nm || '-linetab', p.linetab);
      m08_meter.record('tmp:' || nm || '-mvix', p.mvix);
      m08_meter.record('tmp:' || nm || '-full-scans', p.full_scans);
    end loop;
  end;

  procedure exec_item(p_reader varchar2, p_sql varchar2) is
  begin
    case p_reader
      when 'childtable'           then execute immediate p_sql bulk collect into ct_key, ct_qty;
      when 'orderdocs-jsontable'  then execute immediate p_sql bulk collect into od_key, od_qty;
      when 'orderdocs-serialized' then execute immediate p_sql bulk collect into ods;
    end case;
  end;

  -- One item reader at one M: two runs, the second counted, then its plan.
  procedure measure_item(p_reader varchar2, p_m number) is
    mk varchar2(30) := 'M08C1' || case p_reader when 'childtable' then 'CT'
                                                when 'orderdocs-jsontable' then 'OD'
                                                else 'ODS' end || 'K' || p_k || 'M' || p_m;
    s  varchar2(4000) := item_sql(p_reader, p_m, mk, true);
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      exec_item(p_reader, s);
    end loop;
    r := m08_meter.delta('session logical reads');
    m08_meter.record(pfx || '-m' || p_m || '-' || p_reader || '-reads', greatest(r - ovr, 0));
    capture(p_reader, p_m, mk);
  end;

  -- Same content: childtable, jsontable and the client-filtered serialized
  -- orders all return the same M (line_id, qty) pairs.
  function same_content(p_m number) return number is
    m   t_map;
    n   number := 0;
    bad number := 0;
  begin
    if ct_key.count <> p_m or od_key.count <> p_m or ods.count <> p_m then
      return 0;
    end if;
    for i in 1 .. ct_key.count loop m(ct_key(i)) := ct_qty(i); end loop;
    if m.count <> p_m then return 0; end if;
    for i in 1 .. od_key.count loop
      if not m.exists(od_key(i)) or m(od_key(i)) <> od_qty(i) then bad := 1; end if;
    end loop;
    for i in 1 .. ods.count loop
      for x in (select jt.line_id, jt.qty
                  from json_table(ods(i) format json, '$.items[*]'
                                  columns (line_id varchar2(36) path '$.lineId',
                                           sku     varchar2(20) path '$.sku',
                                           qty     number       path '$.qty')) jt
                 where jt.sku = 'XM' || p_m) loop
        n := n + 1;
        if not m.exists(x.line_id) or m(x.line_id) <> x.qty then bad := 1; end if;
      end loop;
    end loop;
    return case when bad = 0 and n = p_m then 1 else 0 end;
  end;
begin
  ovr := v('s1c-meter-overhead-reads');

  -- S1's order read by key, on this data (independent of M).
  for i in 1 .. 2 loop
    if i = 2 then m08_meter.snap; end if;
    execute immediate 'select /*+ gather_plan_statistics M08C1DOCK' || p_k || ' */'
                   || ' json_serialize(d.data returning blob) from m08c1_ord_doc d'
                   || ' where d.data."_id" = 900001'
      bulk collect into docs;
  end loop;
  r := m08_meter.delta('session logical reads');
  if docs.count <> 1 then raise_application_error(-20850, 'doc rows ' || docs.count); end if;
  m08_meter.record(pfx || '-doc-reads', greatest(r - ovr, 0));
  m08_meter.record(pfx || '-doc-bytes', dbms_lob.getlength(docs(1)));
  capture('doc', null, 'M08C1DOCK' || p_k);

  for i in 1 .. 2 loop
    if i = 2 then m08_meter.snap; end if;
    execute immediate 'select /*+ gather_plan_statistics M08C1JOINK' || p_k || ' */'
                   || ' o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
                   || ' from m08c1_ord o join m08c1_line l on l.order_id = o.id where o.id = 900001'
      bulk collect into jrows;
  end loop;
  r := m08_meter.delta('session logical reads');
  if jrows.count <> p_k then raise_application_error(-20851, 'join rows ' || jrows.count); end if;
  m08_meter.record(pfx || '-join-reads', greatest(r - ovr, 0));
  capture('join', null, 'M08C1JOINK' || p_k);

  for i in 1 .. ms.count loop
    measure_item('childtable', ms(i));
    measure_item('orderdocs-jsontable', ms(i));
    measure_item('orderdocs-serialized', ms(i));
    m08_meter.record(pfx || '-m' || ms(i) || '-orderdocs-reads',
                     least(v(pfx || '-m' || ms(i) || '-orderdocs-jsontable-reads'),
                           v(pfx || '-m' || ms(i) || '-orderdocs-serialized-reads')));
    m08_meter.record('tmp:' || pfx || '-m' || ms(i) || '-same-content', same_content(ms(i)));
  end loop;

  -- CPU and elapsed medians for the item readers at M = 100 and 500 (20 runs).
  -- The timed copies have no gather_plan_statistics, so their own marker; their
  -- plan hash is recorded to check it equals the counted cursor's.
  for mm in (select column_value m from table(sys.odcinumberlist(100, 500))) loop
    for rd in (select column_value rdr
                 from table(sys.odcivarchar2list('childtable', 'orderdocs-jsontable', 'orderdocs-serialized'))) loop
      declare
        mk  varchar2(30) := 'M08C1R' || case rd.rdr when 'childtable' then 'CT'
                                                    when 'orderdocs-jsontable' then 'OD'
                                                    else 'ODS' end || 'K' || p_k || 'M' || mm.m;
        sid varchar2(13);
        chn number;
        phv number;
      begin
        m08_meter.measure_repeat(pfx || '-m' || mm.m || '-' || rd.rdr,
                                 item_sql(rd.rdr, mm.m, mk, false), 20,
                                 p_allow_lob => rd.rdr = 'orderdocs-serialized');
        find_cursor(mk, sid, chn, phv);
        m08_meter.record('tmp:' || pfx || '-m' || mm.m || '-' || rd.rdr || '-repeat-phv', phv);
      end;
    end loop;
  end loop;
end;
/

-- k = 100 (the tables were built above)
begin
  m08c1_load(100);
  m08c1_measure(100);
end;
/

-- k = 1000 (a fresh build; the load runs in its own call, after its
-- procedures recompile against the new tables)
begin
  m08c1_build;
end;
/

begin
  m08c1_load(1000);
  m08c1_measure(1000);
end;
/

-- Crossover per point (formula in the header). It exists only when both terms
-- are positive; otherwise s1c-no-crossover-k<k>-m<M> = 1 is recorded.
declare
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  for k in (select column_value k from table(sys.odcinumberlist(100, 1000))) loop
    for m in (select column_value m from table(sys.odcinumberlist(5, 20, 100, 500))) loop
      declare
        p   varchar2(30) := 's1c-k' || k.k;
        num number := 1000 * (v(p || '-join-reads') - v(p || '-doc-reads'));
        den number := v(p || '-m' || m.m || '-orderdocs-reads') - v(p || '-m' || m.m || '-childtable-reads');
      begin
        if num > 0 and den > 0 then
          m08_meter.record(p || '-m' || m.m || '-crossover-item-queries-per-1000-order-reads',
                           round(num / den));
        else
          m08_meter.record(p || '-m' || m.m || '-no-crossover', 1);
        end if;
      end;
    end loop;
  end loop;
end;
/

-- ===== Measurements (as METRIC rows) and executed plans (as PLAN rows) =====
select 'METRIC:' || name || ':' || to_char(value, 'FM999999990')
  from m08_metrics
 where name like 's1c-%'
 order by name;

select 'PLAN:k' || k || nvl2(m, '-m' || m, '') || '-' || reader || ': ' || line
  from m08c1_plan
 order by k, m nulls first, reader, n;

-- ===== Assertions (read back from m08_metrics) =====

-- Every item reader returned the same M (line_id, qty) pairs at every point.
with pts as (select k.column_value k, m.column_value m
               from table(sys.odcinumberlist(100, 1000)) k,
                    table(sys.odcinumberlist(5, 20, 100, 500)) m)
select 'ASSERT:s1c-same-content-k' || k || '-m' || m || ':' ||
       case when (select value from m08_metrics
                   where name = 'tmp:s1c-k' || k || '-m' || m || '-same-content') = 1
            then 'PASS' else 'FAIL' end
  from pts
 order by k, m;

-- Plans: every measured statement has an executed plan with row-source
-- statistics (Buffers), the child-table reader is answered by the covering
-- index alone (no line-table visit) at every M, and each timed copy ran the
-- same plan as the counted cursor.
select 'ASSERT:s1c-plans-captured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1c-k%-xplan-buffers' and value > 0) = 2 * (2 + 4 * 3)
            then 'PASS' else 'FAIL' end
  from dual;

-- No measured statement scanned a whole table, and the order-document readers
-- found their orders through the multivalue index at every M.
select 'ASSERT:s1c-plans-indexed:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1c-k%-full-scans' and value = 0) = 2 * (2 + 4 * 3)
             and (select count(*) from m08_metrics
                   where name like 'tmp:s1c-k%-orderdocs-%-mvix' and value > 0) = 2 * 4 * 2
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1c-childtable-covered:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1c-k%-childtable-cov' and value > 0) = 8
             and (select count(*) from m08_metrics
                   where name like 'tmp:s1c-k%-childtable-linetab' and value = 0) = 8
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1c-timed-same-plan:' ||
       case when (select count(*) from m08_metrics r join m08_metrics c
                     on c.name = replace(r.name, '-repeat-phv', '-phv')
                   where r.name like 'tmp:s1c-k%-repeat-phv' and r.value = c.value) = 2 * 2 * 3
            then 'PASS' else 'FAIL' end
  from dual;

-- The crossover exists (a positive whole number), or the no-crossover row is
-- recorded, at every point; never both, never neither.
with pts as (select k.column_value k, m.column_value m
               from table(sys.odcinumberlist(100, 1000)) k,
                    table(sys.odcinumberlist(5, 20, 100, 500)) m)
select 'ASSERT:s1c-crossover-recorded:' ||
       case when (select count(*) from pts
                   where (select count(*) from m08_metrics
                           where name = 's1c-k' || k || '-m' || m || '-crossover-item-queries-per-1000-order-reads'
                             and value > 0)
                       + (select count(*) from m08_metrics
                           where name = 's1c-k' || k || '-m' || m || '-no-crossover' and value = 1) = 1) = 8
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's1c-%' or name like 'tmp:s1c-%';

drop procedure if exists m08c1_build;
drop procedure if exists m08c1_load;
drop procedure if exists m08c1_measure;
drop table if exists m08c1_line purge;
drop table if exists m08c1_ord purge;
drop table if exists m08c1_ord_doc purge;
drop table if exists m08c1_plan purge;

select 'ASSERT:s1c-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08C1\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 's1c-%' or name like 'tmp:s1c-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
