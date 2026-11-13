-- S2, duplication and write amplification, by change regime.
-- Stonebraker and Pavlo: "if the join is not one-to-many, then there will be
-- duplicated data". The duplication is real. What it costs depends on knob 2 (the
-- write-to-read ratio) and knob 3 (which fields the writes change).
--
-- An order embeds a snapshot of its customer: {custId, name, tier} (the Extended
-- Reference pattern). One customer has N = 100 orders.
--   embedded  : order documents in a JSON collection table, each carrying the
--               customer snapshot, with an index on the embedded custId
--   normalized: an orders table with a plain NOT NULL cust_id (indexed) that
--               references the customer table
-- Fields that never change (name) cost nothing to keep consistent: nothing ever
-- rewrites them. A field that does change (tier) must be rewritten in every
-- order that embeds it: one customer change becomes N document updates.
--
-- Measured, each on its 2nd execution, with the meter's own overhead removed:
--   update  : one tier change. Embedded: JSON_TRANSFORM on every embedding
--             document, found through the custId index. Normalized: one customer
--             row by primary key. Rows or documents touched, logical reads, redo.
--   read    : one order with its customer fields. Embedded: the document by _id,
--             serialized so its body is really read. Normalized: the order row
--             joined to its customer row by key; the cheaper of two plans counts
--             (primary keys, or covering indexes that answer without row visits).
--
-- Crossover (knobs 2 and 3), with logical reads as the work unit for reads and
-- updates alike. For 1,000 order reads plus q customer tier changes:
--   embedded  : 1000*emb_read  + q*emb_update_reads
--   normalized: 1000*norm_read + q*norm_update_reads
--   crossover : q = 1000 * (norm_read - emb_read) / (emb_update_reads - norm_update_reads)
-- Below q tier changes per 1,000 order reads, embedding does less work; above it,
-- normalized storage does. Redo is a separate cost axis, recorded but not in the
-- crossover; it makes the write side worse still for embedding. The crossover is
-- approximate: a one-block change in any term moves it.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08s2_measure;
drop table if exists m08s2_ord purge;
drop table if exists m08s2_ord_doc purge;
drop table if exists m08s2_cust purge;
delete from m08_metrics where name like 's2-%' or name like 'tmp:s2-%';

-- ===== Projections =====
create table m08s2_cust (
  id   number constraint m08s2_cust_pk primary key,
  name varchar2(40) not null,
  tier varchar2(10) not null
);

-- Covering index: the normalized read can take name and tier without a row visit.
-- Because it holds tier, the normalized tier change also pays to maintain it.
-- The order covering index below holds every order column, so it works like an
-- index-organized orders table: the normalized side's best case for the order read.
create index m08s2_cust_cov_ix on m08s2_cust (id, name, tier);

create table m08s2_ord (
  id      number constraint m08s2_ord_pk primary key,
  cust_id number not null constraint m08s2_ord_cust_fk references m08s2_cust,
  status  varchar2(12),
  total   number
);

create index m08s2_ord_cust_ix on m08s2_ord (cust_id);

create index m08s2_ord_cov_ix on m08s2_ord (id, cust_id, status, total);

create json collection table m08s2_ord_doc;

create index m08s2_doc_cust_ix on m08s2_ord_doc d (d.data.customer.custId.number());

-- ===== Data =====
-- Sized for realism, not for the result. 100,000 customers: a toy customer table
-- would let the normalized read's extra index probe hide inside a single index
-- block; at this size the customer indexes have a branch level, as in a real
-- system. 20,100 orders, the scale of S1 (about 22k), so the order-side indexes
-- also have realistic depth: customer 1 (the target) has 100 orders, and 20,000
-- more belong to other customers, one order per customer at most. Orders arrive
-- over time, so customer 1's orders are spread out: every 201st order id
-- (201, 402, ..., 20100) is theirs. All customers start at tier BRONZE.
insert into m08s2_cust (id, name, tier)
  select level, 'Customer ' || level, 'BRONZE' from dual connect by level <= 100000;

insert into m08s2_ord (id, cust_id, status, total)
  select i, case when mod(i, 201) = 0 then 1 else i + 1 end, 'OPEN', mod(i, 997) + 10
    from (select level i from dual connect by level <= 20100)
   order by i;

insert into m08s2_ord_doc (data)
  select json_object('_id' value o.id, 'status' value o.status, 'total' value o.total,
                     'customer' value json_object('custId' value c.id, 'name' value c.name,
                                                  'tier' value c.tier)
                     returning json)
    from m08s2_ord o join m08s2_cust c on c.id = o.cust_id
   order by o.id;

begin
  commit;
  dbms_stats.gather_table_stats(user, 'M08S2_CUST', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08S2_ORD', cascade => true);
  dbms_stats.gather_table_stats(user, 'M08S2_ORD_DOC', cascade => true);
end;
/

-- Depth (blevel) of every index a measured statement uses: a probe costs blevel + 1 reads.
insert into m08_metrics (name, value)
  select 's2-idx-' || case i.index_name
                        when 'M08S2_CUST_PK'     then 'cust-pk'
                        when 'M08S2_CUST_COV_IX' then 'cust-cov'
                        when 'M08S2_ORD_PK'      then 'ord-pk'
                        when 'M08S2_ORD_COV_IX'  then 'ord-cov'
                        when 'M08S2_DOC_CUST_IX' then 'doc-cust'
                        else 'doc-pk' end || '-blevel',
         i.blevel
    from user_indexes i
   where i.index_name in ('M08S2_CUST_PK', 'M08S2_CUST_COV_IX', 'M08S2_ORD_PK',
                          'M08S2_ORD_COV_IX', 'M08S2_DOC_CUST_IX')
      or i.index_name = (select c.index_name from user_constraints c
                          where c.table_name = 'M08S2_ORD_DOC' and c.constraint_type = 'P');

-- ===== Measurement =====
-- Meter overhead: snap then delta with no work in between. Measured twice; the
-- second (warm) result is kept and subtracted from every measurement below.
declare
  r number;
  d number;
begin
  for i in 1 .. 2 loop
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
    d := m08_meter.delta('redo size');
  end loop;
  m08_meter.record('s2-meter-overhead-reads', r);
  m08_meter.record('s2-meter-overhead-redo', d);
end;
/

-- Markers sit last in each hint comment, so the plan check matches ' <marker> */'.
create or replace procedure m08s2_measure as
  type t_blob is table of blob;
  type t_row  is record (id number, status varchar2(12), total number,
                         cust_id number, name varchar2(40), tier varchar2(10));
  type t_rows is table of t_row;
  docs   t_blob;
  nrows  t_rows;
  ovr    number;
  ovd    number;
  r      number;
  rd     number;
  n      number;
  ok     number;
  c_ord  constant number := 201; -- an order of customer 1
  c_cust constant number := 1;

  -- embedded read: the order document by _id, serialized.
  procedure emb_read is
  begin
    select /*+ M08SXER */ json_serialize(d.data returning blob) bulk collect into docs
      from m08s2_ord_doc d where d.data."_id" = c_ord;
    if docs.count <> 1 then raise_application_error(-20830, 'doc rows ' || docs.count); end if;
  end;
  -- normalized read, primary keys: the order row, then its customer row.
  procedure norm_read_pk is
  begin
    select /*+ index(o m08s2_ord_pk) index(c m08s2_cust_pk) M08SXNR */
           o.id, o.status, o.total, c.id, c.name, c.tier
      bulk collect into nrows
      from m08s2_ord o join m08s2_cust c on c.id = o.cust_id
     where o.id = c_ord;
    if nrows.count <> 1 then raise_application_error(-20831, 'join rows ' || nrows.count); end if;
  end;
  -- normalized read, covering indexes: both sides answered from index entries alone.
  procedure norm_read_cov is
  begin
    select /*+ index(o m08s2_ord_cov_ix) index(c m08s2_cust_cov_ix) M08SXNRC */
           o.id, o.status, o.total, c.id, c.name, c.tier
      bulk collect into nrows
      from m08s2_ord o join m08s2_cust c on c.id = o.cust_id
     where o.id = c_ord;
    if nrows.count <> 1 then raise_application_error(-20831, 'join rows ' || nrows.count); end if;
  end;
  -- embedded tier change: every document that embeds customer 1.
  procedure emb_update(p_tier varchar2) is
  begin
    update /*+ index(d m08s2_doc_cust_ix) M08SXEU */ m08s2_ord_doc d
       set d.data = json_transform(d.data, set '$.customer.tier' = p_tier)
     where d.data.customer.custId.number() = c_cust;
    n := sql%rowcount;
  end;
  -- normalized tier change: one customer row by primary key.
  procedure norm_update(p_tier varchar2) is
  begin
    update /*+ index(c m08s2_cust_pk) M08SXNU */ m08s2_cust c
       set c.tier = p_tier
     where c.id = c_cust;
    n := sql%rowcount;
  end;

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  -- Reads: run twice, measure the 2nd run.
  procedure measure_read(p_name varchar2) is
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      case p_name
        when 'embedded-read'           then emb_read;
        when 'normalized-read-pk'      then norm_read_pk;
        when 'normalized-read-covered' then norm_read_cov;
      end case;
    end loop;
    r := m08_meter.delta('session logical reads');
    m08_meter.record('s2-' || p_name || '-reads', greatest(r - ovr, 0));
  end;

  -- Updates: the 1st run sets SILVER, the measured 2nd run sets GOLD.
  procedure measure_update(p_name varchar2, p_unit varchar2) is
  begin
    for i in 1 .. 2 loop
      if i = 2 then m08_meter.snap; end if;
      case p_name
        when 'embedded'   then emb_update(case i when 1 then 'SILVER' else 'GOLD' end);
        when 'normalized' then norm_update(case i when 1 then 'SILVER' else 'GOLD' end);
      end case;
    end loop;
    r := m08_meter.delta('session logical reads');
    rd := m08_meter.delta('redo size');
    m08_meter.record('s2-' || p_name || '-update-' || p_unit, n);
    m08_meter.record('s2-' || p_name || '-update-reads', greatest(r - ovr, 0));
    m08_meter.record('s2-' || p_name || '-update-redo', greatest(rd - ovd, 0));
  end;

  -- Same content: the embedded document and the normalized row carry the same
  -- order and customer fields.
  function same_content return number is
    x number;
  begin
    emb_read;
    norm_read_pk;
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
begin
  ovr := v('s2-meter-overhead-reads');
  ovd := v('s2-meter-overhead-redo');

  -- Reads first, on the starting data (tier BRONZE everywhere).
  measure_read('embedded-read');
  measure_read('normalized-read-pk');
  measure_read('normalized-read-covered');
  -- The normalized side's best plan: the cheaper of its two readers.
  m08_meter.record('s2-normalized-read-reads',
                   least(v('s2-normalized-read-pk-reads'), v('s2-normalized-read-covered-reads')));
  m08_meter.record('tmp:s2-same-content-before', same_content);

  -- One tier change in each model.
  measure_update('embedded', 'docs');
  measure_update('normalized', 'rows');
  m08_meter.record('tmp:s2-same-content-after', same_content);

  -- Fan-out consistency: every order of customer 1 now embeds the customer's tier.
  select case when count(*) = 100
               and count(case when json_value(d.data, '$.customer.tier') = c.tier then 1 end) = 100
              then 1 else 0 end
    into ok
    from m08s2_ord_doc d join m08s2_cust c on c.id = d.data.customer.custId.number()
   where c.id = c_cust;
  m08_meter.record('tmp:s2-fanout-consistent', ok);

  -- Plans: every marker has a valid cursor with an INDEX step and no full table
  -- scan, and the covering reader visits no table at all.
  select case when (select count(distinct mk.marker)
                      from (select 'M08SXER' marker from dual union all select 'M08SXNR' from dual
                            union all select 'M08SXNRC' from dual union all select 'M08SXEU' from dual
                            union all select 'M08SXNU' from dual) mk
                     where exists (select 1 from v$sql s join v$sql_plan p
                                       on p.sql_id = s.sql_id and p.child_number = s.child_number
                                    where upper(s.sql_text) like '% ' || mk.marker || ' */%'
                                      and s.object_status = 'VALID'
                                      and p.operation = 'INDEX')) = 5
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where upper(s.sql_text) like '%M08' || 'SX%'
                       and s.object_status = 'VALID'
                       and p.operation = 'TABLE ACCESS' and p.options like '%FULL%') = 0
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where upper(s.sql_text) like '% M08' || 'SXNRC */%'
                       and s.object_status = 'VALID'
                       and p.operation = 'TABLE ACCESS') = 0
              then 1 else 0 end
    into ok from dual;
  m08_meter.record('tmp:s2-plans-indexed', ok);
end;
/

begin
  m08s2_measure;
end;
/

-- Crossover, in logical reads (formula in the header):
--   q = 1000 * (norm_read - emb_read) / (emb_update_reads - norm_update_reads),
-- rounded to one decimal: here it is near 1, so whole numbers would hide it.
-- If the denominator is not positive, there is no crossover: s2-no-crossover = 1.
declare
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  declare
    num number := 1000 * (v('s2-normalized-read-reads') - v('s2-embedded-read-reads'));
    den number := v('s2-embedded-update-reads') - v('s2-normalized-update-reads');
  begin
    if den > 0 then
      m08_meter.record('s2-crossover-updates-per-1000-reads', round(num / den, 1));
    else
      m08_meter.record('s2-no-crossover', 1);
    end if;
  end;
end;
/

-- ===== Measurements (as METRIC rows) =====
select 'METRIC:' || name || ':' ||
       case when value = trunc(value) then to_char(value, 'FM999999990')
            else to_char(value, 'FM999999990.0') end
  from m08_metrics
 where name like 's2-%'
 order by name;

-- ===== Assertions (read back from m08_metrics) =====

-- One tier change rewrites every embedding document: N = 100.
select 'ASSERT:s2-embedded-touches-N:' ||
       case when (select value from m08_metrics where name = 's2-embedded-update-docs') = 100
            then 'PASS' else 'FAIL' end
  from dual;

-- The same change in normalized storage touches one row.
select 'ASSERT:s2-normalized-touches-1:' ||
       case when (select value from m08_metrics where name = 's2-normalized-update-rows') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The fan-out writes more redo than the single-row update.
select 'ASSERT:s2-embedded-redo-gt-normalized:' ||
       case when (select value from m08_metrics where name = 's2-embedded-update-redo') >
                 (select value from m08_metrics where name = 's2-normalized-update-redo')
            then 'PASS' else 'FAIL' end
  from dual;

-- Reading an order with its customer fields is cheaper embedded than through the join.
select 'ASSERT:s2-embedded-read-cheaper:' ||
       case when (select value from m08_metrics where name = 's2-embedded-read-reads') <
                 (select value from m08_metrics where name = 's2-normalized-read-reads')
            then 'PASS' else 'FAIL' end
  from dual;

-- Immutable regime (0 customer updates per 1,000 order reads): embedded costs less in total.
select 'ASSERT:s2-immutable-total-cheaper:' ||
       case when 1000 * (select value from m08_metrics where name = 's2-embedded-read-reads') <
                 1000 * (select value from m08_metrics where name = 's2-normalized-read-reads')
            then 'PASS' else 'FAIL' end
  from dual;

-- There is a finite crossover above zero.
select 'ASSERT:s2-crossover-positive:' ||
       case when (select value from m08_metrics where name = 's2-crossover-updates-per-1000-reads') > 0
            then 'PASS' else 'FAIL' end
  from dual;

-- Same order and customer fields from both models, before and after the tier
-- change, and every embedded copy carries the new tier.
select 'ASSERT:s2-same-content:' ||
       case when (select count(*) from m08_metrics
                   where name in ('tmp:s2-same-content-before', 'tmp:s2-same-content-after',
                                  'tmp:s2-fanout-consistent')
                     and value = 1) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- Every measured statement used an index, and none scanned a whole table.
select 'ASSERT:s2-plans-indexed:' ||
       case when (select value from m08_metrics where name = 'tmp:s2-plans-indexed') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 's2-%' or name like 'tmp:s2-%';

drop procedure if exists m08s2_measure;
drop table if exists m08s2_ord purge;
drop table if exists m08s2_ord_doc purge;
drop table if exists m08s2_cust purge;

select 'ASSERT:s2-teardown-clean:' ||
       case when (select count(*) from user_objects where object_name like 'M08S2\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 's2-%' or name like 'tmp:s2-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
