-- Writes (D): writes through views, knob 3, etag propagation, and a
-- materialized-view arm. Object prefix M08D_, metrics wr-*.
--
-- S1 to S4 measured reads and one kind of write (a customer field copied into
-- many orders). This script measures the other writes:
--   1. insert an order with k lines (k = 10 and 100), three ways:
--        col : one document into a JSON collection table
--        dv  : one document through a duality view over orders + lines
--        sql : plain SQL, 1 order row plus k line rows (one FORALL)
--   2. knob 3 (Liu and Houlihan, The Elements of Data, forthcoming): change one
--      line's qty in a 1,000-line order, three ways:
--        col : JSON_TRANSFORM on the collection document (the line found by lineId)
--        dv  : the same JSON_TRANSFORM, through the duality view
--        sql : a one-row UPDATE on the lines table
--   3. etags (S4 shape): rename a customer through a customer-centric view and
--      count how many of its order documents (order-centric view, nested
--      read-only customer) get a new _metadata.etag; then write one order with
--      the etag read before the rename and record whether it is refused.
--   4. a materialized view arm: an order read with customer fields, and one
--      customer tier change plus COMMIT, for embedded documents (S2 style),
--      normalized tables, and normalized tables plus a join materialized view
--      M08D_ORD_CUST_MV refreshed FAST ON COMMIT (the refresh runs inside the
--      COMMIT, so the measured window includes it).
--
-- How each cost is taken: logical reads, redo bytes and CPU (centiseconds) from
-- the session statistics, snap before and delta after one write plus its
-- COMMIT. The COMMIT is inside every write window: a small transaction keeps its
-- redo in a private buffer until COMMIT and only then adds it to 'redo size', so
-- a window that closed before the COMMIT would show 0 redo for some writes. One
-- warm-up run is not counted, then 20 counted runs; the median is the lower
-- middle value of the 20 (an observed run), as in the meter. The meter's own
-- overhead (snap then delta, no work) is subtracted from reads and redo. Reads
-- use m08_meter.measure_repeat (20 runs).
-- Every measured statement carries gather_plan_statistics and a marker last in
-- its hint comment; its executed plan (ALLSTATS LAST) is printed as PLAN rows.
-- Session statistics include recursive SQL: the duality view's per-row writes
-- and etag checks, and the materialized view's refresh, are all counted.
--
-- No ASSERT compares costs. The ASSERTs check correctness only: the same
-- content from all three insert paths, the one-line change visible in every
-- read, the etag check working at all (controls), the MV matching the tables
-- after COMMIT, and plans captured.
--
-- Commits: this script commits its own M08D_ test data (the tier change must
-- commit to fire the refresh). It drops everything it creates.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08d_measure_mv;
drop procedure if exists m08d_measure;
drop materialized view if exists m08d_ord_cust_mv;
drop view if exists m08d_s4ord_dv;
drop view if exists m08d_s4cust_dv;
drop view if exists m08d_ord_dv;
drop table if exists m08d_s4etag purge;
drop table if exists m08d_s4line purge;
drop table if exists m08d_s4ord purge;
drop table if exists m08d_s4cust purge;
drop table if exists m08d_line purge;
drop table if exists m08d_ord purge;
drop table if exists m08d_doc purge;
drop table if exists m08d_cord purge;
drop table if exists m08d_emb purge;
drop table if exists m08d_cust purge;
drop table if exists m08d_samp purge;
drop table if exists m08d_plan purge;
delete from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%';

-- Scratch: one row per counted run, and the executed plans.
create table m08d_samp (stmt varchar2(40), run number, reads number, redo number,
                        cpu number, ela number);
create table m08d_plan (stmt varchar2(40), ln number, line varchar2(400));

-- ===== Parts 1 and 2: orders with lines, three projections =====
-- The relational projection: orders and lines. Lines are keyed by lineId, a
-- field the document carries; ord_id is a plain NOT NULL column, not selected
-- in the nested part of the view.
create table m08d_ord (
  ord_id  number constraint m08d_ord_pk primary key,
  cust_id number not null,
  status  varchar2(12) not null,
  total   number not null
);

create table m08d_line (
  line_id number constraint m08d_line_pk primary key,
  ord_id  number not null constraint m08d_line_ord_fk references m08d_ord,
  sku     varchar2(20) not null,
  qty     number not null
);

create index m08d_line_ord_ix on m08d_line (ord_id);

create json relational duality view m08d_ord_dv as
select json {'_id'    : o.ord_id,
             'custId' : o.cust_id,
             'status' : o.status,
             'total'  : o.total,
             'lines'  : [ select json {'lineId' : l.line_id,
                                       'sku'    : l.sku,
                                       'qty'    : l.qty}
                            from m08d_line l with insert update delete
                           where l.ord_id = o.ord_id ]}
  from m08d_ord o with insert update delete;

-- The document projection: a JSON collection table, _id index only.
create json collection table m08d_doc;

-- Data: order 1 has 1,000 lines (knob 3), orders 2 to 1001 have 10 lines each.
-- lineId = ord_id * 1000 + line number. The same rows in both projections.
insert into m08d_ord (ord_id, cust_id, status, total)
  select level, mod(level, 50) + 1, 'OPEN', level * 10 from dual connect by level <= 1001;

insert into m08d_line (line_id, ord_id, sku, qty)
  select 1000 + level, 1, 'SKU-' || mod(level * 7, 97), mod(level, 5) + 1
    from dual connect by level <= 1000;

insert into m08d_line (line_id, ord_id, sku, qty)
  select o.ord_id * 1000 + n.i, o.ord_id, 'SKU-' || mod(n.i * 7, 97), mod(n.i, 5) + 1
    from (select level + 1 ord_id from dual connect by level <= 1000) o,
         (select level i from dual connect by level <= 10) n;

insert into m08d_doc (data)
  select json_object('_id' value o.ord_id, 'custId' value o.cust_id, 'status' value o.status,
                     'total' value o.total,
                     'lines' value (select json_arrayagg(json_object('lineId' value l.line_id,
                                                                     'sku' value l.sku,
                                                                     'qty' value l.qty)
                                                         order by l.line_id returning json)
                                      from m08d_line l where l.ord_id = o.ord_id)
                     returning json)
    from m08d_ord o order by o.ord_id;

-- ===== Part 3: the S4 shape, for etags =====
create table m08d_s4cust (
  cust_id number constraint m08d_s4cust_pk primary key,
  name    varchar2(40) not null
);

create table m08d_s4ord (
  ord_id  number constraint m08d_s4ord_pk primary key,
  cust_id number not null constraint m08d_s4ord_cust_fk references m08d_s4cust,
  status  varchar2(12) not null,
  total   number not null
);

create index m08d_s4ord_cust_ix on m08d_s4ord (cust_id);

create table m08d_s4line (
  line_id number constraint m08d_s4line_pk primary key,
  ord_id  number not null constraint m08d_s4line_ord_fk references m08d_s4ord,
  sku     varchar2(20) not null,
  qty     number not null
);

create index m08d_s4line_ord_ix on m08d_s4line (ord_id);

create json relational duality view m08d_s4cust_dv as
select json {'_id'    : c.cust_id,
             'name'   : c.name,
             'orders' : [ select json {'ordId'  : o.ord_id,
                                       'status' : o.status,
                                       'total'  : o.total,
                                       'lines'  : [ select json {'lineId' : l.line_id,
                                                                 'sku'    : l.sku,
                                                                 'qty'    : l.qty}
                                                      from m08d_s4line l with insert update delete
                                                     where l.ord_id = o.ord_id ]}
                            from m08d_s4ord o with insert update delete
                           where o.cust_id = c.cust_id ]}
  from m08d_s4cust c with insert update delete;

-- The nested customer is read-only here, as in S4. No etag annotation is
-- given, so every field takes part in the document's etag (the default).
create json relational duality view m08d_s4ord_dv as
select json {'_id'      : o.ord_id,
             'status'   : o.status,
             'total'    : o.total,
             'customer' : ( select json {'custId' : c.cust_id,
                                         'name'   : c.name}
                              from m08d_s4cust c with noinsert noupdate nodelete
                             where c.cust_id = o.cust_id ),
             'lines'    : [ select json {'lineId' : l.line_id,
                                         'sku'    : l.sku,
                                         'qty'    : l.qty}
                              from m08d_s4line l with insert update delete
                             where l.ord_id = o.ord_id ]}
  from m08d_s4ord o with insert update delete;

-- Customer 1 has orders 1 to 5, customer 2 has orders 6 to 8; 2 lines each.
insert into m08d_s4cust (cust_id, name)
  select level, 'Customer ' || level from dual connect by level <= 3;

insert into m08d_s4ord (ord_id, cust_id, status, total)
  select level, case when level <= 5 then 1 else 2 end, 'OPEN', level * 10
    from dual connect by level <= 8;

insert into m08d_s4line (line_id, ord_id, sku, qty)
  select level, ceil(level / 2), 'SKU-' || level, 1 from dual connect by level <= 16;

-- Each order document's etag and full text, as a client would hold them.
create table m08d_s4etag (ord_id number, etag varchar2(64), doc clob);

-- ===== Part 4: the MV arm, S2's data shape =====
-- 100,000 customers; 20,100 orders; customer 1 has 100 of them (every 201st).
create table m08d_cust (
  id   number constraint m08d_cust_pk primary key,
  name varchar2(40) not null,
  tier varchar2(10) not null
);

create table m08d_cord (
  id      number constraint m08d_cord_pk primary key,
  cust_id number not null constraint m08d_cord_cust_fk references m08d_cust,
  status  varchar2(12),
  total   number
);

create index m08d_cord_cust_ix on m08d_cord (cust_id);

create json collection table m08d_emb;

create index m08d_emb_cust_ix on m08d_emb d (d.data.customer.custId.number());

insert into m08d_cust (id, name, tier)
  select level, 'Customer ' || level, 'BRONZE' from dual connect by level <= 100000;

insert into m08d_cord (id, cust_id, status, total)
  select i, case when mod(i, 201) = 0 then 1 else i + 1 end, 'OPEN', mod(i, 997) + 10
    from (select level i from dual connect by level <= 20100)
   order by i;

insert into m08d_emb (data)
  select json_object('_id' value o.id, 'status' value o.status, 'total' value o.total,
                     'customer' value json_object('custId' value c.id, 'name' value c.name,
                                                  'tier' value c.tier)
                     returning json)
    from m08d_cord o join m08d_cust c on c.id = o.cust_id
   order by o.id;

begin
  commit;
  for t in (select table_name from user_tables
             where table_name in ('M08D_ORD', 'M08D_LINE', 'M08D_DOC', 'M08D_S4CUST',
                                  'M08D_S4ORD', 'M08D_S4LINE', 'M08D_CUST', 'M08D_CORD',
                                  'M08D_EMB')) loop
    dbms_stats.gather_table_stats(user, t.table_name, cascade => true, no_invalidate => false);
  end loop;
end;
/

-- Meter overhead: snap then delta with no work, twice; the warm one is kept.
declare
  r number;
  d number;
begin
  for i in 1 .. 2 loop
    m08_meter.snap;
    r := m08_meter.delta('session logical reads');
    d := m08_meter.delta('redo size');
  end loop;
  m08_meter.record('wr-meter-overhead-reads', r);
  m08_meter.record('wr-meter-overhead-redo', d);
end;
/

-- Size of the knob-3 document, and whether its body is stored out of row.
insert into m08_metrics (name, value)
  select 'wr-k3-doc-bytes', dbms_lob.getlength(json_serialize(d.data returning blob))
    from m08d_doc d where d.data."_id" = 1;

-- ===== Parts 1 to 3 =====
create or replace procedure m08d_measure as
  ovr number;
  ovd number;
  ok  number;
  n   number;
  v1  number;
  v2  number;
  v3  number;
  j   json;
  type t_num is table of number;
  type t_vc  is table of varchar2(20);
  ids  t_num;
  skus t_vc;
  qtys t_num;
  e    clob;

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  -- Close one counted window and store it.
  procedure sample(p_stmt varchar2, p_run number) is
    r  number := m08_meter.delta('session logical reads');
    d  number := m08_meter.delta('redo size');
    c  number := m08_meter.delta('CPU used by this session');
    el number := m08_meter.elapsed_cs;
  begin
    if p_run > 0 then
      insert into m08d_samp values (p_stmt, p_run, greatest(r - ovr, 0), greatest(d - ovd, 0), c, el);
    end if;
  end;

  -- Medians and maxima of the 20 counted runs, as wr-<stmt>-<stat>-median/-max.
  procedure summarize(p_stmt varchar2) is
  begin
    for s in (select percentile_disc(0.5) within group (order by reads) rm, max(reads) rx,
                     percentile_disc(0.5) within group (order by redo) dm, max(redo) dx,
                     percentile_disc(0.5) within group (order by cpu) cm, max(cpu) cx,
                     percentile_disc(0.5) within group (order by ela) em, count(*) cnt
                from m08d_samp where stmt = p_stmt) loop
      m08_meter.record('wr-' || p_stmt || '-reads-median', s.rm);
      m08_meter.record('wr-' || p_stmt || '-reads-max', s.rx);
      m08_meter.record('wr-' || p_stmt || '-redo-median', s.dm);
      m08_meter.record('wr-' || p_stmt || '-redo-max', s.dx);
      m08_meter.record('wr-' || p_stmt || '-cpu-cs-median', s.cm);
      m08_meter.record('wr-' || p_stmt || '-cpu-cs-max', s.cx);
      m08_meter.record('wr-' || p_stmt || '-elapsed-cs-median', s.em);
      m08_meter.record('tmp:wr-' || p_stmt || '-runs', s.cnt);
    end loop;
  end;

  -- Executed plan of the newest valid cursor carrying the marker.
  procedure capture(p_stmt varchar2, p_marker varchar2) is
    sid varchar2(13);
    chn number;
    nb  number;
  begin
    select sql_id, child_number into sid, chn
      from (select sql_id, child_number from v$sql
             where upper(sql_text) like '% ' || p_marker || ' */%'
               and upper(sql_text) not like '%V$SQL%' and object_status = 'VALID'
             order by last_active_time desc, child_number desc)
     where rownum = 1;
    insert into m08d_plan (stmt, ln, line)
      select p_stmt, rownum, substr(plan_table_output, 1, 400)
        from table(dbms_xplan.display_cursor(sid, chn, 'ALLSTATS LAST'));
    select count(*) into nb from m08d_plan where stmt = p_stmt and line like '%Buffers%';
    m08_meter.record('tmp:wr-' || p_stmt || '-xplan-buffers', nb);
    select count(case when operation = 'TABLE ACCESS' and options like '%FULL%'
                       and object_name like 'M08D%' then 1 end)
      into nb from v$sql_plan where sql_id = sid and child_number = chn;
    m08_meter.record('tmp:wr-' || p_stmt || '-full-scans', nb);
  exception
    when no_data_found then
      m08_meter.record('tmp:wr-' || p_stmt || '-xplan-buffers', 0);
  end;

  -- The document for order p_id with k lines; its content depends only on
  -- (k, total), never on the id, so the three paths can be compared.
  function build_doc(p_id number, p_k number, p_total number) return json is
    x json;
  begin
    select json_object('_id' value p_id, 'custId' value 7, 'status' value 'NEW',
                       'total' value p_total,
                       'lines' value (select json_arrayagg(
                                               json_object('lineId' value p_id * 1000 + level,
                                                           'sku' value 'SKU-' || mod(level * 7, 97),
                                                           'qty' value mod(level, 5) + 1)
                                               order by level returning json)
                                        from dual connect by level <= p_k)
                       returning json)
      into x from dual;
    return x;
  end;

  -- Content signature, id-free: custId|status|total|lines|lineNo:sku:qty,...
  function sig_doc(p_src varchar2, p_id number) return varchar2 is
    s varchar2(4000);
  begin
    execute immediate
      'select max(jt.cust) || ''|'' || max(jt.status) || ''|'' || max(jt.total) || ''|'' || count(*)
              || ''|'' || listagg((jt.line_id - jt.id * 1000) || '':'' || jt.sku || '':'' || jt.qty, '','')
                          within group (order by jt.line_id)
         from ' || p_src || ' d,
              json_table(d.data, ''$'' columns (id number path ''$._id'', cust number path ''$.custId'',
                         status varchar2(12) path ''$.status'', total number path ''$.total'',
                         nested path ''$.lines[*]'' columns (line_id number path ''$.lineId'',
                                                            sku varchar2(20) path ''$.sku'',
                                                            qty number path ''$.qty''))) jt
        where d.data."_id" = :1'
      into s using p_id;
    return s;
  end;

  function sig_sql(p_id number) return varchar2 is
    s varchar2(4000);
  begin
    select max(o.cust_id) || '|' || max(o.status) || '|' || max(o.total) || '|' || count(*)
           || '|' || listagg((l.line_id - o.ord_id * 1000) || ':' || l.sku || ':' || l.qty, ',')
                       within group (order by l.line_id)
      into s
      from m08d_ord o join m08d_line l on l.ord_id = o.ord_id
     where o.ord_id = p_id;
    return s;
  end;

  -- qty of one line, read four ways.
  function qty_col(p_line number) return number is
    x number;
  begin
    select jt.qty into x
      from m08d_doc d, json_table(d.data, '$.lines[*]' columns (line_id number path '$.lineId',
                                                               qty number path '$.qty')) jt
     where d.data."_id" = 1 and jt.line_id = p_line;
    return x;
  end;
  function qty_dv(p_line number) return number is
    x number;
  begin
    select jt.qty into x
      from m08d_ord_dv d, json_table(d.data, '$.lines[*]' columns (line_id number path '$.lineId',
                                                                  qty number path '$.qty')) jt
     where d.data."_id" = 1 and jt.line_id = p_line;
    return x;
  end;
  function qty_tab(p_line number) return number is
    x number;
  begin
    select qty into x from m08d_line where line_id = p_line;
    return x;
  end;

  -- One insert path, one k: 1 warm-up and 20 counted runs, each with its commit.
  procedure insert_path(p_path varchar2, p_k number) is
    base number := case p_path when 'col' then 100000 when 'dv' then 200000 else 300000 end
                   + p_k * 100;
    id   number;
  begin
    for r in 0 .. 20 loop
      id := base + r;
      -- Everything the statement needs is built before the window opens.
      if p_path in ('col', 'dv') then
        j := build_doc(id, p_k, p_k * 10 + r);
      else
        select id * 1000 + level, 'SKU-' || mod(level * 7, 97), mod(level, 5) + 1
          bulk collect into ids, skus, qtys
          from dual connect by level <= p_k;
      end if;
      m08_meter.snap;
      if p_path = 'col' then
        insert /*+ gather_plan_statistics M08DXIC */ into m08d_doc (data) values (j);
      elsif p_path = 'dv' then
        insert /*+ gather_plan_statistics M08DXID */ into m08d_ord_dv (data) values (j);
      else
        insert /*+ gather_plan_statistics M08DXIO */ into m08d_ord (ord_id, cust_id, status, total)
          values (id, 7, 'NEW', p_k * 10 + r);
        forall i in 1 .. ids.count
          insert /*+ gather_plan_statistics M08DXIL */ into m08d_line (line_id, ord_id, sku, qty)
            values (ids(i), id, skus(i), qtys(i));
      end if;
      commit;
      sample('ins-' || p_path || '-k' || p_k, r);
    end loop;
    summarize('ins-' || p_path || '-k' || p_k);
  end;

  -- Knob 3: change line 1500's qty in order 1 (1,000 lines). Run r sets qty
  -- 100 + r for col, 200 + r for dv, 300 + r for sql, so every run changes it.
  procedure knob3(p_path varchar2) is
  begin
    for r in 0 .. 20 loop
      m08_meter.snap;
      if p_path = 'col' then
        update /*+ gather_plan_statistics M08DXK3C */ m08d_doc d
           set d.data = json_transform(d.data, set '$.lines[*]?(@.lineId == 1500).qty' = 100 + r)
         where d.data."_id" = 1;
      elsif p_path = 'dv' then
        update /*+ gather_plan_statistics M08DXK3V */ m08d_ord_dv d
           set d.data = json_transform(d.data, set '$.lines[*]?(@.lineId == 1500).qty' = 200 + r)
         where d.data."_id" = 1;
      else
        update /*+ gather_plan_statistics M08DXK3S */ m08d_line l
           set l.qty = 300 + r
         where l.line_id = 1500;
      end if;
      n := sql%rowcount;
      commit;
      sample('k3-' || p_path, r);
    end loop;
    m08_meter.record('wr-k3-' || p_path || '-rows', n);
    summarize('k3-' || p_path);
  end;

begin
  ovr := v('wr-meter-overhead-reads');
  ovd := v('wr-meter-overhead-redo');

  -- ----- Part 1: inserts -----
  for k in (select 10 k from dual union all select 100 from dual) loop
    insert_path('col', k.k);
    insert_path('dv', k.k);
    insert_path('sql', k.k);
  end loop;
  capture('ins-col', 'M08DXIC');
  capture('ins-dv', 'M08DXID');
  capture('ins-sql-ord', 'M08DXIO');
  capture('ins-sql-line', 'M08DXIL');

  -- Same content: for every (k, run), the three paths hold the same order,
  -- read back as the collection document, the duality-view document and the
  -- table rows. The k-line count is part of the signature.
  ok := 0;
  for k in (select 10 k from dual union all select 100 from dual) loop
    for r in 0 .. 20 loop
      if sig_doc('m08d_doc', 100000 + k.k * 100 + r) = sig_doc('m08d_ord_dv', 200000 + k.k * 100 + r)
         and sig_doc('m08d_ord_dv', 200000 + k.k * 100 + r) = sig_sql(300000 + k.k * 100 + r)
         and sig_sql(300000 + k.k * 100 + r) like '7|NEW|' || (k.k * 10 + r) || '|' || k.k || '|%' then
        ok := ok + 1;
      end if;
    end loop;
  end loop;
  m08_meter.record('tmp:wr-ins-same-content', ok);

  -- ----- Part 2: knob 3 -----
  v1 := qty_tab(1499);
  knob3('col');
  knob3('dv');
  -- After the duality-view update, the change is in the line row, and only there.
  m08_meter.record('tmp:wr-k3-dv-in-table', case when qty_tab(1500) = 220 then 1 else 0 end);
  knob3('sql');
  capture('k3-col', 'M08DXK3C');
  capture('k3-dv', 'M08DXK3V');
  capture('k3-sql', 'M08DXK3S');
  -- Every read shows its last change; the neighbouring line is untouched; the
  -- documents still have 1,000 lines.
  select count(*) into n from m08d_doc d, json_table(d.data, '$.lines[*]' columns (x number path '$.lineId')) jt
   where d.data."_id" = 1;
  select count(*) into v2 from m08d_ord_dv d, json_table(d.data, '$.lines[*]' columns (x number path '$.lineId')) jt
   where d.data."_id" = 1;
  m08_meter.record('tmp:wr-k3-visible',
                   case when qty_col(1500) = 120 and qty_dv(1500) = 320 and qty_tab(1500) = 320
                         and qty_col(1499) = v1 and qty_dv(1499) = v1 and qty_tab(1499) = v1
                         and n = 1000 and v2 = 1000
                        then 1 else 0 end);

  -- ----- Part 3: etags -----
  -- Every order document's etag and text, as a client holds them.
  insert into m08d_s4etag (ord_id, etag, doc)
    select d.data."_id".number(), json_value(d.data, '$._metadata.etag'),
           json_serialize(d.data returning clob)
      from m08d_s4ord_dv d;
  -- The one rename, through the customer-centric view, measured.
  m08_meter.snap;
  update m08d_s4cust_dv d
     set d.data = json_transform(d.data, set '$.name' = 'Renamed Customer')
   where d.data."_id" = 1;
  n := sql%rowcount;
  commit;
  m08_meter.record('wr-s4d-rename-reads', greatest(m08_meter.delta('session logical reads') - ovr, 0));
  m08_meter.record('wr-s4d-rename-redo', greatest(m08_meter.delta('redo size') - ovd, 0));
  m08_meter.record('wr-s4d-rename-docs', n);
  -- Re-read: how many of customer 1's 5 order documents have a new etag, and
  -- how many of customer 2's 3 (not renamed).
  select count(case when s.ord_id <= 5 and s.etag <> json_value(d.data, '$._metadata.etag') then 1 end),
         count(case when s.ord_id > 5 and s.etag <> json_value(d.data, '$._metadata.etag') then 1 end),
         count(case when s.ord_id <= 5 and json_value(d.data, '$.customer.name') = 'Renamed Customer' then 1 end)
    into v1, v2, v3
    from m08d_s4etag s join m08d_s4ord_dv d on d.data."_id".number() = s.ord_id;
  m08_meter.record('wr-s4d-etags-changed', v1);
  m08_meter.record('wr-s4d-other-etags-changed', v2);
  m08_meter.record('wr-s4d-order-docs', 5);
  m08_meter.record('tmp:wr-s4d-new-name-visible', case when v3 = 5 then 1 else 0 end);

  -- The write with the etag read before the rename: order 1, status HELD, the
  -- rest of the document as the client held it.
  select doc into e from m08d_s4etag where ord_id = 1;
  begin
    update m08d_s4ord_dv d
       set d.data = json_transform(json(e), set '$.status' = 'HELD')
     where d.data."_id" = 1;
    m08_meter.record('wr-s4d-stale-write-rejected', 0);
    m08_meter.record('wr-s4d-stale-write-sqlcode', 0);
  exception
    when others then
      m08_meter.record('wr-s4d-stale-write-rejected', case when sqlcode = -42699 then 1 else 0 end);
      m08_meter.record('wr-s4d-stale-write-sqlcode', sqlcode);
  end;
  select count(*) into n from m08d_s4ord where ord_id = 1 and status = 'HELD';
  m08_meter.record('wr-s4d-stale-write-applied', n);

  -- Controls, so the result above means what it says.
  -- (a) A fresh read after the rename, written back: accepted.
  select json_serialize(d.data returning clob) into e from m08d_s4ord_dv d where d.data."_id" = 2;
  begin
    update m08d_s4ord_dv d
       set d.data = json_transform(json(e), set '$.status' = 'HELD')
     where d.data."_id" = 2;
    select count(*) into n from m08d_s4ord where ord_id = 2 and status = 'HELD';
    m08_meter.record('tmp:wr-s4d-fresh-write-accepted', n);
  exception
    when others then m08_meter.record('tmp:wr-s4d-fresh-write-accepted', 0);
  end;
  -- (b) Order 6 (customer 2, not renamed): change it through the order view,
  -- then write it with the etag read before that change: refused.
  update m08d_s4ord_dv d
     set d.data = json_transform(d.data, set '$.total' = 999)
   where d.data."_id" = 6;
  select doc into e from m08d_s4etag where ord_id = 6;
  begin
    update m08d_s4ord_dv d
       set d.data = json_transform(json(e), set '$.status' = 'HELD')
     where d.data."_id" = 6;
    m08_meter.record('tmp:wr-s4d-own-change-rejected', 0);
  exception
    when others then
      m08_meter.record('tmp:wr-s4d-own-change-rejected', case when sqlcode = -42699 then 1 else 0 end);
  end;
  commit;
end;
/

begin
  m08d_measure;
end;
/

-- ===== Part 4: the MV arm =====
-- Phase 1, before any materialized view log exists: embedded and normalized.
-- Phase 2: MV logs and the MV, then the MV read and the tier change through it.
-- The normalized tier change is measured first so it pays no MV log cost.
create or replace procedure m08d_measure_mv(p_phase number) as
  ovr number;
  ovd number;
  n   number;
  t   varchar2(10);

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  procedure sample(p_stmt varchar2, p_run number) is
    r  number := m08_meter.delta('session logical reads');
    d  number := m08_meter.delta('redo size');
    c  number := m08_meter.delta('CPU used by this session');
    el number := m08_meter.elapsed_cs;
  begin
    if p_run > 0 then
      insert into m08d_samp values (p_stmt, p_run, greatest(r - ovr, 0), greatest(d - ovd, 0), c, el);
    end if;
  end;

  procedure summarize(p_stmt varchar2) is
  begin
    for s in (select percentile_disc(0.5) within group (order by reads) rm, max(reads) rx,
                     percentile_disc(0.5) within group (order by redo) dm, max(redo) dx,
                     percentile_disc(0.5) within group (order by cpu) cm, max(cpu) cx,
                     percentile_disc(0.5) within group (order by ela) em, count(*) cnt
                from m08d_samp where stmt = p_stmt) loop
      m08_meter.record('wr-' || p_stmt || '-reads-median', s.rm);
      m08_meter.record('wr-' || p_stmt || '-reads-max', s.rx);
      m08_meter.record('wr-' || p_stmt || '-redo-median', s.dm);
      m08_meter.record('wr-' || p_stmt || '-redo-max', s.dx);
      m08_meter.record('wr-' || p_stmt || '-cpu-cs-median', s.cm);
      m08_meter.record('wr-' || p_stmt || '-cpu-cs-max', s.cx);
      m08_meter.record('wr-' || p_stmt || '-elapsed-cs-median', s.em);
      m08_meter.record('tmp:wr-' || p_stmt || '-runs', s.cnt);
    end loop;
  end;

  procedure capture(p_stmt varchar2, p_marker varchar2) is
    sid varchar2(13);
    chn number;
    nb  number;
  begin
    select sql_id, child_number into sid, chn
      from (select sql_id, child_number from v$sql
             where upper(sql_text) like '% ' || p_marker || ' */%'
               and upper(sql_text) not like '%V$SQL%' and object_status = 'VALID'
             order by last_active_time desc, child_number desc)
     where rownum = 1;
    insert into m08d_plan (stmt, ln, line)
      select p_stmt, rownum, substr(plan_table_output, 1, 400)
        from table(dbms_xplan.display_cursor(sid, chn, 'ALLSTATS LAST'));
    select count(*) into nb from m08d_plan where stmt = p_stmt and line like '%Buffers%';
    m08_meter.record('tmp:wr-' || p_stmt || '-xplan-buffers', nb);
    select count(case when operation = 'TABLE ACCESS' and options like '%FULL%'
                       and object_name like 'M08D%' then 1 end)
      into nb from v$sql_plan where sql_id = sid and child_number = chn;
    m08_meter.record('tmp:wr-' || p_stmt || '-full-scans', nb);
  exception
    when no_data_found then
      m08_meter.record('tmp:wr-' || p_stmt || '-xplan-buffers', 0);
  end;

  -- One tier change on customer 1 plus COMMIT, 1 warm-up and 20 counted runs.
  -- The tiers alternate, so every run is a real change.
  procedure tier_change(p_stmt varchar2) is
  begin
    for r in 0 .. 20 loop
      t := case mod(r, 2) when 0 then 'SILVER' else 'GOLD' end;
      m08_meter.snap;
      if p_stmt = 'mv-upd-embedded' then
        update /*+ gather_plan_statistics M08DXMUE */ m08d_emb d
           set d.data = json_transform(d.data, set '$.customer.tier' = t)
         where d.data.customer.custId.number() = 1;
      else
        -- normalized and mv: the same statement; in phase 2 the MV log and
        -- the on-commit refresh come with it.
        update /*+ gather_plan_statistics M08DXMU */ m08d_cust c
           set c.tier = t
         where c.id = 1;
      end if;
      n := sql%rowcount;
      commit;
      sample(p_stmt, r);
    end loop;
    m08_meter.record('wr-' || p_stmt || '-rows', n);
    summarize(p_stmt);
  end;
begin
  ovr := v('wr-meter-overhead-reads');
  ovd := v('wr-meter-overhead-redo');
  if p_phase = 1 then
    m08_meter.measure_repeat('wr-mv-read-embedded',
      'select /*+ gather_plan_statistics M08DXMRE */ json_serialize(d.data returning blob)'
      || ' from m08d_emb d where d.data."_id" = 201', 20, p_allow_lob => true);
    m08_meter.measure_repeat('wr-mv-read-normalized',
      'select /*+ gather_plan_statistics index(o m08d_cord_pk) index(c m08d_cust_pk) M08DXMRN */'
      || ' o.id, o.status, o.total, c.id, c.name, c.tier'
      || ' from m08d_cord o join m08d_cust c on c.id = o.cust_id where o.id = 201', 20);
    capture('mv-read-embedded', 'M08DXMRE');
    capture('mv-read-normalized', 'M08DXMRN');
    tier_change('mv-upd-embedded');
    capture('mv-upd-embedded', 'M08DXMUE');
    tier_change('mv-upd-normalized');
    capture('mv-upd-normalized', 'M08DXMU');
  else
    m08_meter.measure_repeat('wr-mv-read-mv',
      'select /*+ gather_plan_statistics M08DXMRM */ m.id, m.status, m.total, m.cust_id, m.name, m.tier'
      || ' from m08d_ord_cust_mv m where m.id = 201', 20);
    capture('mv-read-mv', 'M08DXMRM');
    tier_change('mv-upd-mv');
    capture('mv-upd-mv', 'M08DXMU');
  end if;
end;
/

begin
  m08d_measure_mv(1);
end;
/

-- Materialized view logs (with rowid, as a fast-refreshable join MV needs),
-- then the MV. FAST ON COMMIT is tried first; if this stack refuses it, the MV
-- is built COMPLETE ON COMMIT instead and wr-mv-fast-on-commit records 0.
-- The rowid columns are indexed, as the documentation advises for join MVs.
create materialized view log on m08d_cust with rowid;

create materialized view log on m08d_cord with rowid;

declare
  q varchar2(1000) := ' on commit as
      select o.id, o.status, o.total, o.cust_id, c.name, c.tier,
             o.rowid ord_rid, c.rowid cust_rid
        from m08d_cord o, m08d_cust c
       where c.id = o.cust_id';
begin
  begin
    execute immediate 'create materialized view m08d_ord_cust_mv refresh fast' || q;
    m08_meter.record('wr-mv-fast-on-commit', 1);
  exception
    when others then
      m08_meter.record('wr-mv-fast-on-commit', 0);
      m08_meter.record('wr-mv-fast-sqlcode', sqlcode);
      execute immediate 'create materialized view m08d_ord_cust_mv refresh complete' || q;
  end;
  execute immediate 'create unique index m08d_mv_id_ix on m08d_ord_cust_mv (id)';
  execute immediate 'create index m08d_mv_ordrid_ix on m08d_ord_cust_mv (ord_rid)';
  execute immediate 'create index m08d_mv_custrid_ix on m08d_ord_cust_mv (cust_rid)';
  dbms_stats.gather_table_stats(user, 'M08D_ORD_CUST_MV', cascade => true, no_invalidate => false);
end;
/

insert into m08_metrics (name, value)
  select 'tmp:wr-mv-mode-ok', case when refresh_mode = 'COMMIT' then 1 else 0 end
    from user_mviews where mview_name = 'M08D_ORD_CUST_MV';

begin
  m08d_measure_mv(2);
end;
/

-- After the last committed tier change: the MV matches the tables for every
-- one of customer 1's orders, and the order read gives the same row from the
-- MV and from the join.
declare
  ok number;
  et varchar2(10);
begin
  select json_value(d.data, '$.customer.tier') into et from m08d_emb d where d.data."_id" = 201;
  select case when count(*) = 100
               and count(case when m.tier = c.tier and m.name = c.name and m.status = o.status
                               and m.total = o.total then 1 end) = 100
              then 1 else 0 end
    into ok
    from m08d_ord_cust_mv m join m08d_cord o on o.id = m.id join m08d_cust c on c.id = o.cust_id
   where c.id = 1;
  select case when ok = 1 and count(*) = 1 then 1 else 0 end into ok
    from m08d_ord_cust_mv m join m08d_cord o on o.id = m.id join m08d_cust c on c.id = o.cust_id
   where m.id = 201 and m.tier = c.tier and m.name = c.name and m.status = o.status
     and m.total = o.total and m.tier = et;
  m08_meter.record('tmp:wr-mv-reflects', ok);
end;
/

-- ===== Measurements (as METRIC rows) and executed plans (as PLAN rows) =====
select 'METRIC:' || name || ':' ||
       case when value = trunc(value) then to_char(value, 'FM999999990')
            else to_char(value, 'FM999999990.00') end
  from m08_metrics
 where name like 'wr-%'
 order by name;

select 'PLAN:' || stmt || ': ' || line
  from m08d_plan
 order by stmt, ln;

-- ===== Assertions (read back from m08_metrics) =====

-- The three insert paths store the same order, for k = 10 and 100, all 21 runs each.
select 'ASSERT:wr-insert-same-content:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-ins-same-content') = 42
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-ins-%-runs' and value = 20) = 6
            then 'PASS' else 'FAIL' end
  from dual;

-- Knob 3: each path changed one row or document, the change is visible in
-- every read (collection, view, table), the neighbouring line is untouched,
-- and the view update landed in the line row.
select 'ASSERT:wr-k3-change-visible:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-k3-visible') = 1
             and (select value from m08_metrics where name = 'tmp:wr-k3-dv-in-table') = 1
             and (select count(*) from m08_metrics
                   where name in ('wr-k3-col-rows', 'wr-k3-dv-rows', 'wr-k3-sql-rows') and value = 1) = 3
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-k3-%-runs' and value = 20) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- Etags: the rename changed one customer document and every order document
-- shows the new name; the etag result itself is recorded, not asserted.
select 'ASSERT:wr-s4d-rename-visible:' ||
       case when (select value from m08_metrics where name = 'wr-s4d-rename-docs') = 1
             and (select value from m08_metrics where name = 'tmp:wr-s4d-new-name-visible') = 1
             and (select count(*) from m08_metrics where name = 'wr-s4d-etags-changed') = 1
             and (select count(*) from m08_metrics where name = 'wr-s4d-stale-write-rejected') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The etag check works at all: a fresh document is accepted, and a document
-- changed since it was read is refused with the etag error.
select 'ASSERT:wr-s4d-etag-controls:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-s4d-fresh-write-accepted') = 1
             and (select value from m08_metrics where name = 'tmp:wr-s4d-own-change-rejected') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- The MV refreshes at COMMIT and matches the tables after the last tier change.
select 'ASSERT:wr-mv-reflects-commit:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-mv-reflects') = 1
             and (select value from m08_metrics where name = 'tmp:wr-mv-mode-ok') = 1
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-mv-upd-%-runs' and value = 20) = 3
             and (select value from m08_metrics where name = 'wr-mv-upd-embedded-rows') = 100
             and (select value from m08_metrics where name = 'wr-mv-upd-normalized-rows') = 1
             and (select value from m08_metrics where name = 'wr-mv-upd-mv-rows') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- Every measured statement has an executed plan with buffers, and none of the
-- updates or reads scanned a whole M08D_ table.
select 'ASSERT:wr-plans-captured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:wr-%-xplan-buffers' and value > 0) = 13
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-%-full-scans' and value > 0) = 0
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%';

drop procedure if exists m08d_measure_mv;
drop procedure if exists m08d_measure;
drop materialized view if exists m08d_ord_cust_mv;
drop view if exists m08d_s4ord_dv;
drop view if exists m08d_s4cust_dv;
drop view if exists m08d_ord_dv;
drop table if exists m08d_s4etag purge;
drop table if exists m08d_s4line purge;
drop table if exists m08d_s4ord purge;
drop table if exists m08d_s4cust purge;
drop table if exists m08d_line purge;
drop table if exists m08d_ord purge;
drop table if exists m08d_doc purge;
drop table if exists m08d_cord purge;
drop table if exists m08d_emb purge;
drop table if exists m08d_cust purge;
drop table if exists m08d_samp purge;
drop table if exists m08d_plan purge;

select 'ASSERT:wr-teardown-clean:' ||
       case when (select count(*) from user_objects
                   where upper(object_name) like 'M08D\_%' escape '\'
                      or upper(object_name) like 'MLOG$\_M08D\_%' escape '\'
                      or upper(object_name) like 'RUPD$\_M08D\_%' escape '\'
                      or upper(object_name) like 'I\_MLOG$\_M08D\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
