-- S2 sweep (C): does the S2 crossover depend on the fan-out N?
-- S2 fixed the fan-out at N = 100 orders for the customer whose tier changes.
-- This script sweeps it: N = 10, 100 and 1000, on one data load. Customers 1,
-- 2 and 3 have 10, 100 and 1000 orders; every other order belongs to its own
-- customer. Otherwise the design is S2's:
--   embedded  : order documents in a JSON collection table, each carrying the
--               customer snapshot {custId, name, tier}, with an index on the
--               embedded custId
--   normalized: an orders table with a plain NOT NULL cust_id (indexed) that
--               references the customer table; covering indexes on both
-- Per N, each statement on its 2nd execution, the meter's overhead removed:
--   update : one tier change of the target customer. Embedded: JSON_TRANSFORM on
--            every embedding document. Normalized: one customer row. Documents
--            or rows touched, logical reads, redo.
--   read   : one order of the target customer with its customer fields.
--            Embedded: the document by _id, serialized. Normalized: the order
--            row joined to its customer row; the cheaper of two plans counts
--            (primary keys, or covering indexes with no row visits).
-- Crossover per N, the same formula as S2, on logical reads:
--   q = 1000 * (norm_read - emb_read) / (emb_update_reads - norm_update_reads)
-- Redo is reported separately and is not in the crossover.
--
-- The embedded update and the embedded read carry no hints; the two
-- normalized reads keep S2's index hints (one per plan, the cheaper counts),
-- and the normalized update has none. Statistics carry a histogram on every indexed column (FOR ALL
-- INDEXED COLUMNS SIZE 254), so the optimizer knows that customer 3 has 1,000
-- orders and may pick a different plan for it. Each N has its own literal
-- customer and order ids, so its own cursors. The executed plan of every
-- measured statement is captured with dbms_xplan.display_cursor(...,
-- 'ALLSTATS LAST') and printed as PLAN rows.
-- CPU and elapsed medians (20 timed runs, 1 cs resolution, each run committed
-- after its measurement) are recorded for the embedded update at N = 100 and 1000.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08c2_measure;
drop table if exists m08c2_ord purge;
drop table if exists m08c2_ord_doc purge;
drop table if exists m08c2_cust purge;
drop table if exists m08c2_plan purge;
delete from m08_metrics where name like 's2c-%' or name like 'tmp:s2c-%';

-- Executed plans, one row per plan line, printed below as PLAN rows.
create table m08c2_plan (n number, stmt varchar2(30), ln number, line varchar2(400));

-- ===== Projections =====
create table m08c2_cust (
  id   number constraint m08c2_cust_pk primary key,
  name varchar2(40) not null,
  tier varchar2(10) not null
);

create index m08c2_cust_cov_ix on m08c2_cust (id, name, tier);

create table m08c2_ord (
  id      number constraint m08c2_ord_pk primary key,
  cust_id number not null constraint m08c2_ord_cust_fk references m08c2_cust,
  status  varchar2(12),
  total   number
);

create index m08c2_ord_cust_ix on m08c2_ord (cust_id);

create index m08c2_ord_cov_ix on m08c2_ord (id, cust_id, status, total);

create json collection table m08c2_ord_doc;

create index m08c2_doc_cust_ix on m08c2_ord_doc d (d.data.customer.custId.number());

-- ===== Data =====
-- 100,000 customers, all BRONZE, as in S2. 21,110 orders: 20,000 of other
-- customers (one order each, customers 1001..21000) and the targets' 1,110.
-- Orders arrive over time, so each target's orders are spread evenly through
-- the order ids: the j-th of customer c's N orders sits at position
-- (j - 0.5) * 20000 / N among the others.
insert into m08c2_cust (id, name, tier)
  select level, 'Customer ' || level, 'BRONZE' from dual connect by level <= 100000;

insert into m08c2_ord (id, cust_id, status, total)
  select row_number() over (order by pos, cust_id), cust_id, 'OPEN', mod(cust_id * 7 + pos, 997) + 10
    from (select 1000 + level cust_id, level pos from dual connect by level <= 20000
          union all
          select t.c, (j.j - 0.5) * 20000 / t.n + t.c / 10
            from (select 1 c, 10 n from dual union all select 2, 100 from dual
                  union all select 3, 1000 from dual) t,
                 (select level j from dual connect by level <= 1000) j
           where j.j <= t.n)
   order by 1;

insert into m08c2_ord_doc (data)
  select json_object('_id' value o.id, 'status' value o.status, 'total' value o.total,
                     'customer' value json_object('custId' value c.id, 'name' value c.name,
                                                  'tier' value c.tier)
                     returning json)
    from m08c2_ord o join m08c2_cust c on c.id = o.cust_id
   order by o.id;

begin
  commit;
  for t in (select column_value tn from table(sys.odcivarchar2list('M08C2_CUST', 'M08C2_ORD', 'M08C2_ORD_DOC'))) loop
    dbms_stats.gather_table_stats(user, t.tn,
      method_opt => 'FOR ALL COLUMNS SIZE 1 FOR ALL INDEXED COLUMNS SIZE 254',
      cascade => true, no_invalidate => false);
  end loop;
end;
/

-- Depth (blevel) of every index a measured statement may use.
insert into m08_metrics (name, value)
  select 's2c-idx-' || case i.index_name
                         when 'M08C2_CUST_PK'     then 'cust-pk'
                         when 'M08C2_CUST_COV_IX' then 'cust-cov'
                         when 'M08C2_ORD_PK'      then 'ord-pk'
                         when 'M08C2_ORD_COV_IX'  then 'ord-cov'
                         when 'M08C2_DOC_CUST_IX' then 'doc-cust'
                         else 'doc-pk' end || '-blevel',
         i.blevel
    from user_indexes i
   where i.index_name in ('M08C2_CUST_PK', 'M08C2_CUST_COV_IX', 'M08C2_ORD_PK',
                          'M08C2_ORD_COV_IX', 'M08C2_DOC_CUST_IX')
      or i.index_name = (select c.index_name from user_constraints c
                          where c.table_name = 'M08C2_ORD_DOC' and c.constraint_type = 'P');

-- ===== Measurement =====
-- Meter overhead: snap then delta with no work in between, twice; the second
-- (warm) result is kept and subtracted below.
declare
  r number;
  d number;
begin
  for i in 1 .. 2 loop
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
    d := m08_meter.delta('redo size');
  end loop;
  m08_meter.record('s2c-meter-overhead-reads', r);
  m08_meter.record('s2c-meter-overhead-redo', d);
end;
/

-- m08c2_measure(n, cust): every statement for one fan-out. Each statement has a
-- marker last in its hint comment (' <marker> */') so its cursor can be found,
-- and gather_plan_statistics so its executed plan shows rows and buffers.
create or replace procedure m08c2_measure(p_n number, p_cust number) as
  type t_blob is table of blob;
  type t_row  is record (id number, status varchar2(12), total number,
                         cust_id number, name varchar2(40), tier varchar2(10));
  type t_rows is table of t_row;
  docs  t_blob;
  nrows t_rows;
  ovr   number;
  ovd   number;
  r     number;
  rd    number;
  cnt   number;
  ok    number;
  ordid number;
  pfx   varchar2(30) := 's2c-n' || p_n;
  sfx   varchar2(30) := 'N' || p_n;

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

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
  procedure capture(p_stmt varchar2, p_marker varchar2) is
    sid varchar2(13);
    chn number;
    phv number;
    nb  number;
  begin
    find_cursor(p_marker, sid, chn, phv);
    insert into m08c2_plan (n, stmt, ln, line)
      select p_n, p_stmt, rownum, substr(plan_table_output, 1, 400)
        from table(dbms_xplan.display_cursor(sid, chn, 'ALLSTATS LAST'));
    select count(*) into nb from m08c2_plan where n = p_n and stmt = p_stmt and line like '%Buffers%';
    m08_meter.record('tmp:' || pfx || '-' || p_stmt || '-xplan-buffers', nb);
    m08_meter.record('tmp:' || pfx || '-' || p_stmt || '-phv', phv);
    for p in (select count(case when operation = 'INDEX' then 1 end) idx,
                     count(case when operation = 'TABLE ACCESS' and options like '%FULL%' then 1 end) fulls,
                     count(case when operation = 'TABLE ACCESS' then 1 end) tabs
                from v$sql_plan where sql_id = sid and child_number = chn) loop
      m08_meter.record('tmp:' || pfx || '-' || p_stmt || '-index-steps', p.idx);
      m08_meter.record('tmp:' || pfx || '-' || p_stmt || '-full-scans', p.fulls);
      m08_meter.record('tmp:' || pfx || '-' || p_stmt || '-table-steps', p.tabs);
    end loop;
  end;

  function read_sql(p_stmt varchar2, p_marker varchar2) return varchar2 is
    h varchar2(60) := '/*+ gather_plan_statistics ' || p_marker || ' */';
  begin
    return case p_stmt
      when 'embedded-read' then
        'select ' || h || ' json_serialize(d.data returning blob) from m08c2_ord_doc d'
        || ' where d.data."_id" = ' || ordid
      when 'normalized-read-pk' then
        'select /*+ gather_plan_statistics index(o m08c2_ord_pk) index(c m08c2_cust_pk) ' || p_marker || ' */'
        || ' o.id, o.status, o.total, c.id, c.name, c.tier'
        || ' from m08c2_ord o join m08c2_cust c on c.id = o.cust_id where o.id = ' || ordid
      when 'normalized-read-covered' then
        'select /*+ gather_plan_statistics index(o m08c2_ord_cov_ix) index(c m08c2_cust_cov_ix) ' || p_marker || ' */'
        || ' o.id, o.status, o.total, c.id, c.name, c.tier'
        || ' from m08c2_ord o join m08c2_cust c on c.id = o.cust_id where o.id = ' || ordid
    end;
  end;

  function upd_sql(p_stmt varchar2, p_marker varchar2, p_stats boolean) return varchar2 is
    h varchar2(60) := '/*+ ' || case when p_stats then 'gather_plan_statistics ' end || p_marker || ' */';
  begin
    return case p_stmt
      when 'embedded-update' then
        'update ' || h || ' m08c2_ord_doc d set d.data = json_transform(d.data, set ''$.customer.tier'' = :t)'
        || ' where d.data.customer.custId.number() = ' || p_cust
      when 'normalized-update' then
        'update ' || h || ' m08c2_cust c set c.tier = :t where c.id = ' || p_cust
    end;
  end;

  procedure measure_read(p_stmt varchar2, p_code varchar2) is
    mk varchar2(30) := 'M08C2' || p_code || sfx;
    s  varchar2(4000) := read_sql(p_stmt, mk);
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      if p_stmt = 'embedded-read' then
        execute immediate s bulk collect into docs;
      else
        execute immediate s bulk collect into nrows;
      end if;
    end loop;
    r := m08_meter.delta('session logical reads');
    m08_meter.record(pfx || '-' || p_stmt || '-reads', greatest(r - ovr, 0));
    capture(p_stmt, mk);
  end;

  -- Updates: the 1st run sets SILVER, the measured 2nd run sets GOLD.
  procedure measure_update(p_stmt varchar2, p_code varchar2, p_unit varchar2) is
    mk varchar2(30) := 'M08C2' || p_code || sfx;
    s  varchar2(4000) := upd_sql(p_stmt, mk, true);
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      execute immediate s using case i when 1 then 'SILVER' else 'GOLD' end;
      cnt := sql%rowcount;
    end loop;
    r := m08_meter.delta('session logical reads');
    rd := m08_meter.delta('redo size');
    m08_meter.record(pfx || '-' || p_stmt || '-' || p_unit, cnt);
    m08_meter.record(pfx || '-' || p_stmt || '-reads', greatest(r - ovr, 0));
    m08_meter.record(pfx || '-' || p_stmt || '-redo', greatest(rd - ovd, 0));
    capture(p_stmt, mk);
  end;

  -- Same content: the embedded document and the normalized row carry the same
  -- order and customer fields.
  function same_content return number is
    x number;
  begin
    execute immediate read_sql('embedded-read', 'M08C2SCE' || sfx) bulk collect into docs;
    execute immediate read_sql('normalized-read-pk', 'M08C2SCN' || sfx) bulk collect into nrows;
    if docs.count <> 1 or nrows.count <> 1 then return 0; end if;
    select count(*) into x
      from json_table(docs(1) format json, '$'
                      columns (id      number       path '$._id',
                               status  varchar2(12) path '$.status',
                               total   number       path '$.total',
                               cust_id number       path '$.customer.custId',
                               name    varchar2(40) path '$.customer.name',
                               tier    varchar2(10) path '$.customer.tier')) jt
     where jt.id = nrows(1).id and jt.status = nrows(1).status and jt.total = nrows(1).total
       and jt.cust_id = nrows(1).cust_id and jt.name = nrows(1).name and jt.tier = nrows(1).tier;
    return x;
  end;

  -- 20 timed runs of the embedded update, committed after each measurement.
  procedure time_update is
    mk  varchar2(30) := 'M08C2RTEU' || sfx;
    s   varchar2(4000) := upd_sql('embedded-update', mk, false);
    rs  sys.odcinumberlist := sys.odcinumberlist();
    cs  sys.odcinumberlist := sys.odcinumberlist();
    es  sys.odcinumberlist := sys.odcinumberlist();
    sid varchar2(13);
    chn number;
    phv number;
    function med(p sys.odcinumberlist) return number is
      x sys.odcinumberlist;
    begin
      select column_value bulk collect into x from table(p) order by column_value;
      return x(trunc((x.count + 1) / 2));
    end;
    function mx(p sys.odcinumberlist) return number is
      x number;
    begin
      select max(column_value) into x from table(p);
      return x;
    end;
  begin
    execute immediate s using 'SILVER';   -- warm-up, not measured
    commit;
    rs.extend(20); cs.extend(20); es.extend(20);
    for i in 1 .. 20 loop
      m08_meter.snap;
      execute immediate s using case mod(i, 2) when 1 then 'GOLD' else 'SILVER' end;
      rs(i) := greatest(m08_meter.delta('session logical reads') - ovr, 0);
      cs(i) := m08_meter.delta('CPU used by this session');
      es(i) := m08_meter.elapsed_cs;
      commit;
    end loop;
    m08_meter.record(pfx || '-embedded-update-timed-reads-median', med(rs));
    m08_meter.record(pfx || '-embedded-update-cpu-cs-median', med(cs));
    m08_meter.record(pfx || '-embedded-update-cpu-cs-max', mx(cs));
    m08_meter.record(pfx || '-embedded-update-elapsed-cs-median', med(es));
    m08_meter.record(pfx || '-embedded-update-elapsed-cs-max', mx(es));
    find_cursor(mk, sid, chn, phv);
    m08_meter.record('tmp:' || pfx || '-embedded-update-repeat-phv', phv);
    -- The last timed run set SILVER; bring the customer row to the same tier.
    update m08c2_cust set tier = 'SILVER' where id = p_cust;
    commit;
  end;
begin
  ovr := v('s2c-meter-overhead-reads');
  ovd := v('s2c-meter-overhead-redo');
  select min(id) into ordid from m08c2_ord where cust_id = p_cust;

  measure_read('embedded-read', 'ER');
  measure_read('normalized-read-pk', 'NR');
  measure_read('normalized-read-covered', 'NRC');
  m08_meter.record(pfx || '-normalized-read-reads',
                   least(v(pfx || '-normalized-read-pk-reads'), v(pfx || '-normalized-read-covered-reads')));
  m08_meter.record('tmp:' || pfx || '-same-content-before', same_content);

  measure_update('embedded-update', 'EU', 'docs');
  measure_update('normalized-update', 'NU', 'rows');
  m08_meter.record('tmp:' || pfx || '-same-content-after', same_content);

  -- Fan-out consistency: every order of the customer embeds the customer's tier.
  select case when count(*) = p_n
               and count(case when json_value(d.data, '$.customer.tier') = c.tier then 1 end) = p_n
              then 1 else 0 end
    into ok
    from m08c2_ord_doc d join m08c2_cust c on c.id = d.data.customer.custId.number()
   where c.id = p_cust;
  m08_meter.record('tmp:' || pfx || '-fanout-consistent', ok);
  commit;

  if p_n in (100, 1000) then
    time_update;
  end if;
end;
/

begin
  m08c2_measure(10, 1);
  m08c2_measure(100, 2);
  m08c2_measure(1000, 3);
end;
/

-- Crossover per N, in logical reads (formula in the header), rounded to two
-- decimals: at large N it is well below 1. If the read advantage or the update
-- penalty is not positive, s2c-n<N>-no-crossover = 1 is recorded instead.
declare
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  for n in (select column_value n from table(sys.odcinumberlist(10, 100, 1000))) loop
    declare
      p   varchar2(30) := 's2c-n' || n.n;
      num number := 1000 * (v(p || '-normalized-read-reads') - v(p || '-embedded-read-reads'));
      den number := v(p || '-embedded-update-reads') - v(p || '-normalized-update-reads');
    begin
      if num > 0 and den > 0 then
        m08_meter.record(p || '-crossover-updates-per-1000-reads', round(num / den, 2));
      else
        m08_meter.record(p || '-no-crossover', 1);
      end if;
    end;
  end loop;
end;
/

-- ===== Measurements (as METRIC rows) and executed plans (as PLAN rows) =====
select 'METRIC:' || name || ':' ||
       case when value = trunc(value) then to_char(value, 'FM999999990')
            else to_char(value, 'FM999999990.00') end
  from m08_metrics
 where name like 's2c-%'
 order by name;

select 'PLAN:n' || n || '-' || stmt || ': ' || line
  from m08c2_plan
 order by n, stmt, ln;

-- ===== Assertions (read back from m08_metrics) =====

-- One tier change rewrites every embedding document: N of them, at every N.
with ns as (select column_value n from table(sys.odcinumberlist(10, 100, 1000)))
select 'ASSERT:s2c-embedded-touches-N-n' || n || ':' ||
       case when (select value from m08_metrics where name = 's2c-n' || n || '-embedded-update-docs') = n
             and (select value from m08_metrics where name = 's2c-n' || n || '-normalized-update-rows') = 1
            then 'PASS' else 'FAIL' end
  from ns
 order by n;

-- Same order and customer fields from both models, before and after the tier
-- change, and every embedded copy carries the new tier, at every N.
with ns as (select column_value n from table(sys.odcinumberlist(10, 100, 1000)))
select 'ASSERT:s2c-same-content-n' || n || ':' ||
       case when (select count(*) from m08_metrics
                   where name in ('tmp:s2c-n' || n || '-same-content-before',
                                  'tmp:s2c-n' || n || '-same-content-after',
                                  'tmp:s2c-n' || n || '-fanout-consistent')
                     and value = 1) = 3
            then 'PASS' else 'FAIL' end
  from ns
 order by n;

-- Plans: every measured statement has an executed plan with row-source
-- statistics (Buffers) and an index step, the reads scan no whole table, the
-- covering read visits no table, and each timed update ran the counted plan.
select 'ASSERT:s2c-plans-captured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s2c-n%-xplan-buffers' and value > 0) = 3 * 5
             and (select count(*) from m08_metrics
                   where name like 'tmp:s2c-n%-index-steps' and value > 0) = 3 * 5
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s2c-reads-indexed:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s2c-n%-read%-full-scans' and value = 0) = 3 * 3
             and (select count(*) from m08_metrics
                   where name like 'tmp:s2c-n%-normalized-read-covered-table-steps' and value = 0) = 3
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s2c-timed-same-plan:' ||
       case when (select count(*) from m08_metrics r join m08_metrics c
                     on c.name = replace(r.name, '-repeat-phv', '-phv')
                   where r.name like 'tmp:s2c-n%-embedded-update-repeat-phv' and r.value = c.value) = 2
            then 'PASS' else 'FAIL' end
  from dual;

-- The crossover exists (positive) or the no-crossover row is recorded, at
-- every N; never both, never neither.
with ns as (select column_value n from table(sys.odcinumberlist(10, 100, 1000)))
select 'ASSERT:s2c-crossover-recorded:' ||
       case when (select count(*) from ns
                   where (select count(*) from m08_metrics
                           where name = 's2c-n' || n || '-crossover-updates-per-1000-reads' and value > 0)
                       + (select count(*) from m08_metrics
                           where name = 's2c-n' || n || '-no-crossover' and value = 1) = 1) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's2c-%' or name like 'tmp:s2c-%';

drop procedure if exists m08c2_measure;
drop table if exists m08c2_ord purge;
drop table if exists m08c2_ord_doc purge;
drop table if exists m08c2_cust purge;
drop table if exists m08c2_plan purge;

select 'ASSERT:s2c-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08C2\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 's2c-%' or name like 'tmp:s2c-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
