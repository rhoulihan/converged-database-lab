-- S1b, child-centric query: "the line items with sku X1".
-- Each side gets its best available plan, and the cheaper of its two readers counts.
--   childtable (no join):
--     plain    : the sku index, then each line row
--     covered  : an index on (sku, line_id, qty) answers alone, with no row visits
--   orderdocs (order documents, found through a multivalue index on items[*].sku):
--     jsontable : JSON_TABLE pulls the matching item out of each order
--     serialized: the matching whole orders are fetched serialized, as a client
--                 would before filtering. Cheapest in reads, but it returns whole
--                 orders to find 20 pairs.
--   itemdv : an item-centric duality view rooted on the line table, filtered on sku.
-- Every reader returns the same content: line_id and qty for the 20 matching lines.
-- sku X1 sits in exactly 20 lines spread over 20 orders. The orders have k = 10,
-- 100 or 1000 lines; each k gets its own freshly built data, so one measurement
-- sees one k. Layout is clustered: each order's lines are inserted together.
-- Each read runs twice; only the second run is measured (no parse cost).
-- Cost is logical reads only (buffer visits; not parse CPU or bytes sent to the
-- client), corrected for the meter's own overhead.
--
-- What to expect. With a covering index, the decomposed form answers the
-- child-centric query in a few reads, whatever the order size. The order
-- documents pay about one block per matching order while each document fits in
-- its row (k = 10, 100), and more once it is stored out of the row (k = 1000,
-- about 50 KB; s1b-doc-bytes-k<k> records the size).
--
-- Knob 1 (how often each query runs). The same data also serves the S1 read, one
-- order by key, measured here at the same k:
--   doc  : the order document by _id, serialized so its body is really read
--   join : the order row joined to its line rows
-- For a workload of 1,000 order reads plus q item queries, where every order read
-- hits a k-line order, the two designs cost
--   documents : 1000*doc  + q*orderdocs
--   normalized: 1000*join + q*childtable
-- They are equal at the crossover
--   q = 1000 * (join - doc) / (orderdocs - childtable)
-- Below q item queries per 1,000 order reads, documents do fewer logical reads;
-- above it, normalized tables do. The crossover is approximate: a one-block change
-- in any term moves it.

-- CPU, elapsed and bytes (m08b_time, after each k's reads): every reader
-- again through m08_meter.measure_us, with its own marker (M08KIDT...): purge,
-- warm-up, 20 runs, the growth of v$sql per run in microseconds, and the bytes
-- one run returns. The same crossover is then computed in CPU microseconds
-- (s1b-crossover-...-k<k>-us), each side again the cheaper of its two readers,
-- this time in CPU.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08b_time;
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
--                  foreign key; indexes on order_id, on sku, and a covering
--                  index on (sku, line_id, qty)
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
  ddl('create index m08b_line_cov_ix on m08b_line (sku, line_id, qty)');
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
-- every item reader returned the same pairs and that every plan used an index.
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
  cc_key t_key; cc_qty t_num;
  od_key t_key; od_qty t_num;
  dv_key t_key; dv_qty t_num;
  docs   t_blob;
  jrows  t_rows;
  ovr    number;
  r      number;
  same   number := 1;
  ok     number;
  m      t_map;

  -- child table, plain: the sku index, then each line row. No join.
  -- (The marker follows the real hint inside the hint comment, so PL/SQL keeps it.)
  procedure childtable_plain is
  begin
    select /*+ index(l m08b_line_sku_ix) M08KIDCT */ l.line_id, l.qty bulk collect into ct_key, ct_qty
      from m08b_line l where l.sku = 'X1';
  end;
  -- child table, covered: the (sku, line_id, qty) index answers alone; no row visits.
  procedure childtable_covered is
  begin
    select /*+ index(l m08b_line_cov_ix) M08KIDCTC */ l.line_id, l.qty bulk collect into cc_key, cc_qty
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
        when 'childtable-plain'     then childtable_plain;
        when 'childtable-covered'   then childtable_covered;
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
  measure('childtable-plain');
  measure('childtable-covered');
  -- The child table's best plan: the cheaper of the two readers.
  m08_meter.record('s1b-childtable-k' || p_k || '-reads',
                   least(r_of('s1b-childtable-plain-k' || p_k || '-reads'),
                         r_of('s1b-childtable-covered-k' || p_k || '-reads')));
  measure('orderdocs-jsontable');
  measure('orderdocs-serialized');
  -- The documents' best plan: the cheaper of the two readers.
  m08_meter.record('s1b-orderdocs-k' || p_k || '-reads',
                   least(r_of('s1b-orderdocs-jsontable-k' || p_k || '-reads'),
                         r_of('s1b-orderdocs-serialized-k' || p_k || '-reads')));
  measure('itemdv');
  measure('doc');
  measure('join');
  -- Stored size of one k-line order document (serialized JSON text, in bytes).
  m08_meter.record('s1b-doc-bytes-k' || p_k, dbms_lob.getlength(docs(1)));

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
  if ct_key.count <> 20 or cc_key.count <> 20 or od_key.count <> 20
     or dv_key.count <> 20 or ser.count <> 20 then
    same := 0;
  else
    for i in 1 .. ct_key.count loop m(ct_key(i)) := ct_qty(i); end loop;
    if m.count <> 20 then same := 0; end if;
    for i in 1 .. 20 loop
      if not m.exists(cc_key(i)) or m(cc_key(i)) <> cc_qty(i)
         or not m.exists(od_key(i)) or m(od_key(i)) <> od_qty(i)
         or not m.exists(dv_key(i)) or m(dv_key(i)) <> dv_qty(i)
         or not m.exists(ser(i)) or m(ser(i)) <> serq(i) then
        same := 0;
      end if;
    end loop;
  end if;
  m08_meter.record('tmp:s1b-same-content-k' || p_k, same);

  -- Plans: every marker has a valid cursor with an INDEX step and no full table
  -- scan, and the covered child-table reader visits no table at all. Markers sit
  -- last in their hint comment, so they are matched as ' <marker> */'.
  select case when (select count(distinct mk.marker)
                      from (select 'M08KIDCT' marker from dual union all select 'M08KIDCTC' from dual
                            union all select 'M08KIDOD' from dual union all select 'M08KIDODS' from dual
                            union all select 'M08KIDDV' from dual union all select 'M08KIDDOC' from dual
                            union all select 'M08KIDJOIN' from dual) mk
                     where exists (select 1 from v$sql s join v$sql_plan p
                                       on p.sql_id = s.sql_id and p.child_number = s.child_number
                                    where upper(s.sql_text) like '% ' || mk.marker || ' */%'
                                      and s.object_status = 'VALID'
                                      and p.operation = 'INDEX')) = 7
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where upper(s.sql_text) like '%M08' || 'KID%'
                       and s.object_status = 'VALID'
                       and p.operation = 'TABLE ACCESS' and p.options like '%FULL%') = 0
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where upper(s.sql_text) like '% M08' || 'KIDCTC */%'
                       and s.object_status = 'VALID'
                       and p.operation = 'TABLE ACCESS') = 0
              then 1 else 0 end
    into ok from dual;
  m08_meter.record('tmp:s1b-plans-indexed-k' || p_k, ok);
end;
/

-- m08b_time(k): CPU, elapsed and bytes per reader (dynamic SQL only, so it
-- never needs recompiling when the tables are rebuilt), then the plan facts of
-- the timed cursors: an INDEX step each, no full table scan, and the covered
-- child-table reader visits no table.
create or replace procedure m08b_time(p_k number) as
  ok number;
  procedure t(p_rdr varchar2, p_mk varchar2, p_sql varchar2, p_lob boolean default false) is
  begin
    m08_meter.measure_us('s1b-' || p_rdr || '-k' || p_k, p_sql, p_mk, null, 20, p_lob);
  end;
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  t('childtable-plain', 'M08KIDTCT',
    'select /*+ index(l m08b_line_sku_ix) M08KIDTCT */ l.line_id, l.qty from m08b_line l where l.sku = ''X1''');
  t('childtable-covered', 'M08KIDTCTC',
    'select /*+ index(l m08b_line_cov_ix) M08KIDTCTC */ l.line_id, l.qty from m08b_line l where l.sku = ''X1''');
  t('orderdocs-jsontable', 'M08KIDTOD',
    'select /*+ M08KIDTOD */ jt.line_id, jt.qty from m08b_ord_doc d,'
    || ' json_table(d.data, ''$.items[*]'' columns (line_id varchar2(36) path ''$.lineId'','
    || ' sku varchar2(20) path ''$.sku'', qty number path ''$.qty'')) jt'
    || ' where json_exists(d.data, ''$.items[*]?(@.sku == "X1")'') and jt.sku = ''X1''');
  t('orderdocs-serialized', 'M08KIDTODS',
    'select /*+ M08KIDTODS */ json_serialize(d.data returning blob) from m08b_ord_doc d'
    || ' where json_exists(d.data, ''$.items[*]?(@.sku == "X1")'')', true);
  t('itemdv', 'M08KIDTDV',
    'select /*+ M08KIDTDV */ v.data."_id".string(), v.data.qty.number() from m08b_item_dv v'
    || ' where v.data.sku.string() = ''X1''');
  t('doc', 'M08KIDTDOC',
    'select /*+ M08KIDTDOC */ json_serialize(d.data returning blob) from m08b_ord_doc d'
    || ' where d.data."_id" = 900001', true);
  t('join', 'M08KIDTJOIN',
    'select /*+ M08KIDTJOIN */ o.id, o.customer, o.status, l.line_id, l.sku, l.qty'
    || ' from m08b_ord o join m08b_line l on l.order_id = o.id where o.id = 900001');
  -- Each side's best plan in CPU: the cheaper of its two readers.
  m08_meter.record('s1b-childtable-k' || p_k || '-us',
                   least(v('s1b-childtable-plain-k' || p_k || '-us'), v('s1b-childtable-covered-k' || p_k || '-us')));
  m08_meter.record('s1b-orderdocs-k' || p_k || '-us',
                   least(v('s1b-orderdocs-jsontable-k' || p_k || '-us'), v('s1b-orderdocs-serialized-k' || p_k || '-us')));
  select case when (select count(distinct mk.marker)
                      from (select column_value marker from table(sys.odcivarchar2list(
                              'M08KIDTCT', 'M08KIDTCTC', 'M08KIDTOD', 'M08KIDTODS', 'M08KIDTDV',
                              'M08KIDTDOC', 'M08KIDTJOIN'))) mk
                     where exists (select 1 from v$sql s join v$sql_plan p
                                       on p.sql_id = s.sql_id and p.child_number = s.child_number
                                    where s.sql_text like '% ' || mk.marker || ' */%'
                                      and s.object_status = 'VALID' and s.command_type = 3
                                      and p.operation = 'INDEX')) = 7
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where s.sql_text like '%M08KIDT%' and s.object_status = 'VALID'
                       and s.command_type = 3
                       and p.operation = 'TABLE ACCESS' and p.options like '%FULL%') = 0
               and (select count(*) from v$sql s join v$sql_plan p
                        on p.sql_id = s.sql_id and p.child_number = s.child_number
                     where s.sql_text like '% M08KIDTCTC */%' and s.object_status = 'VALID'
                       and s.command_type = 3 and p.operation = 'TABLE ACCESS') = 0
              then 1 else 0 end
    into ok from dual;
  m08_meter.record('tmp:s1b-us-plans-indexed-k' || p_k, ok);
end;
/

-- k = 10 (the tables were built above)
begin
  m08b_load(10);
  m08b_measure(10);
  m08b_time(10);
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
  m08b_time(100);
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
  m08b_time(1000);
end;
/

-- Crossover (knob 1), at every k:
--   q = 1000 * (join - doc) / (orderdocs - childtable), rounded,
-- with orderdocs and childtable each the cheaper of its two readers. It exists only
-- when both terms are positive; otherwise s1b-no-crossover-k<k> = 1 is recorded.
declare
  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;
begin
  for k in (select column_value k from table(sys.odcinumberlist(10, 100, 1000))) loop
    declare
      num number := 1000 * (v('s1b-join-k' || k.k || '-reads') - v('s1b-doc-k' || k.k || '-reads'));
      den number := v('s1b-orderdocs-k' || k.k || '-reads') - v('s1b-childtable-k' || k.k || '-reads');
    begin
      if num > 0 and den > 0 then
        m08_meter.record('s1b-crossover-item-queries-per-1000-order-reads-k' || k.k, round(num / den));
      else
        m08_meter.record('s1b-no-crossover-k' || k.k, 1);
      end if;
    end;
    -- The same crossover in CPU microseconds, rounded to two decimals.
    declare
      num number := 1000 * (v('s1b-join-k' || k.k || '-us') - v('s1b-doc-k' || k.k || '-us'));
      den number := v('s1b-orderdocs-k' || k.k || '-us') - v('s1b-childtable-k' || k.k || '-us');
    begin
      if num > 0 and den > 0 then
        m08_meter.record('s1b-crossover-item-queries-per-1000-order-reads-k' || k.k || '-us', round(num / den, 2));
      else
        m08_meter.record('s1b-no-crossover-k' || k.k || '-us', 1);
      end if;
    end;
  end loop;
end;
/

-- ===== Measurements (as METRIC rows) =====
select 'METRIC:' || name || ':' ||
       case when value = trunc(value) then to_char(value, 'FM999999990')
            else to_char(value, 'FM999999990.00') end
  from m08_metrics
 where name like 's1b-%'
 order by name;

-- ===== Assertions (read back from m08_metrics) =====

-- Directions are reported as METRIC rows (1 or 0), not asserted.
-- Out-of-row documents: 1 when the order documents read more than twice the child table.
select 'METRIC:s1b-outofrow-penalty-k1000:' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k1000-reads') >
                 2 * (select value from m08_metrics where name = 's1b-childtable-k1000-reads')
            then '1' else '0' end
  from dual;

-- 1 when the item-centric duality view reads at most twice the child table.
with ks as (select column_value k from table(sys.odcinumberlist(10, 100, 1000)))
select 'METRIC:s1b-itemdv-close-to-childtable-k' || k || ':' ||
       case when (select value from m08_metrics where name = 's1b-itemdv-k' || k || '-reads') <=
                 2 * (select value from m08_metrics where name = 's1b-childtable-k' || k || '-reads')
            then '1' else '0' end
  from ks
 order by k;

-- 1 when the documents' read ratio over the child table is larger at k = 1000 than at k = 10.
select 'METRIC:s1b-gap-grows-with-k:' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k1000-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k1000-reads'), 0) >
                 (select value from m08_metrics where name = 's1b-orderdocs-k10-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k10-reads'), 0)
            then '1' else '0' end
  from dual;

-- 1 when that ratio is larger at k = 1000 than at k = 100.
select 'METRIC:s1b-penalty-ratio-grows:' ||
       case when (select value from m08_metrics where name = 's1b-orderdocs-k1000-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k1000-reads'), 0) >
                 (select value from m08_metrics where name = 's1b-orderdocs-k100-reads') /
                 nullif((select value from m08_metrics where name = 's1b-childtable-k100-reads'), 0)
            then '1' else '0' end
  from dual;

-- At each k where the order documents read more per item query: 1 when the
-- crossover is a finite number above zero.
with ks as (select column_value k from table(sys.odcinumberlist(10, 100, 1000)))
select 'METRIC:s1b-crossover-k' || k || '-positive:' ||
       case when (select value from m08_metrics
                   where name = 's1b-crossover-item-queries-per-1000-order-reads-k' || k) > 0
            then '1' else '0' end
  from ks
 where (select value from m08_metrics where name = 's1b-orderdocs-k' || k || '-reads') >
       (select value from m08_metrics where name = 's1b-childtable-k' || k || '-reads')
 order by k;

-- The v$sql windows: 7 readers at 3 k, each cursor run once per call, every
-- purge effective, and the timed cursors' plans indexed with no full scan.
select 'ASSERT:s1b-us-measured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1b-%-execs-per-call' and value = 1) = 21
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1b-us-purge-effective:' ||
       case when (select count(*) from m08_metrics where name like 'tmp:s1b-%-purge-left') = 21
             and (select count(*) from m08_metrics where name like 'tmp:s1b-%-purge-left' and value <> 0) = 0
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:s1b-us-plans-indexed:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:s1b-us-plans-indexed-k%' and value = 1) = 3
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

drop procedure if exists m08b_time;
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
