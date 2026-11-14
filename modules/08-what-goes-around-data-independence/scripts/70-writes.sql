-- Writes (D): writes through views, knob 3, etag propagation, and a
-- materialized-view arm. Object prefix M08D_, metrics wr-*.
--
-- S1 to S4 measured reads and one kind of write (a customer field copied into
-- many orders). This script measures the other writes:
--   1. insert an order with k lines (k = 10 and 100), four ways:
--        col    : one document into a JSON collection table
--        dv     : one document through a duality view over orders + lines
--        sql    : plain SQL, 1 order row plus k line rows (one FORALL array insert)
--        sqlrow : plain SQL, 1 order row plus k single-row INSERTs in a loop
--   2. knob 3 (Liu and Houlihan, The Elements of Data, forthcoming): change one
--      line's qty in a 1,000-line order:
--        col    : JSON_TRANSFORM on the collection document, line found by lineId
--        colpos : JSON_TRANSFORM by array position ($.lines[499]), same-length value
--        colrep : the whole document replaced (the change made before the window),
--                 which is what the MongoDB API sends (see 71-writes-api.js)
--        dv     : the lineId JSON_TRANSFORM, through the duality view
--        sql    : a one-row UPDATE on the lines table
--      and SELECT ... FOR UPDATE of the order document (fu-col, fu-dv), the
--      first statement the MongoDB API runs for an updateOne, with the number of
--      undo records it creates (one per locked row).
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
-- overhead (snap then delta, no work) is subtracted from reads and redo. Samples
-- are kept in memory during a loop and stored after it, so no window carries
-- another write. Reads use m08_meter.measure_repeat (20 runs).
-- Every measured statement carries gather_plan_statistics and a marker last in
-- its hint comment; its executed plan (ALLSTATS LAST) is printed as PLAN rows.
-- Session statistics include recursive SQL: the duality view's per-row writes
-- and etag checks, and the materialized view's refresh, are all counted. Those
-- recursive statements are also listed from v$sql (growth over one loop, per
-- statement: executions, rows, buffer gets and text) as METRIC and PLAN rows.
--
-- CPU and elapsed in microseconds per write (wr-<stmt>-us, -ela-us, and
-- v$sql's buffer gets, -gets): the growth of v$sql over 100 more runs after
-- the 20 counted ones (m08d_h.c_cpu_runs), for the write's own statements (its
-- marker; the plain SQL inserts have two), divided by 100. The COMMIT is not a statement in v$sql, so it is not in these
-- figures, but the statement's undo and redo generation is. A duality view's
-- or an MV log's recursive statements run inside the write and are part of
-- its v$sql figures; the materialized view's refresh runs at COMMIT, so its
-- statements' CPU is listed separately (wr-vs-mv-refresh-*-us-per-call) and
-- added in wr-mv-upd-mv-total-us. Every marked cursor is purged once before
-- the first write that uses it (tmp:wr-us-purge-left-*).
--
-- No ASSERT compares costs. The ASSERTs check correctness only: the same
-- content from all four insert paths, the one-line change visible in every
-- read, the etag check working at all (controls), the MV refreshed by FAST
-- refresh at every COMMIT, and plans captured.
--
-- Commits: this script commits its own M08D_ test data (the tier change must
-- commit to fire the refresh). It drops everything it creates.

-- Clean up anything left by an earlier, interrupted run.
drop procedure if exists m08d_measure_mv;
drop procedure if exists m08d_measure;
drop package if exists m08d_h;
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
drop table if exists m08d_vs purge;
drop table if exists m08d_oson purge;
delete from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%';

-- Scratch: one row per counted run, the executed plans, and v$sql snapshots.
create table m08d_samp (stmt varchar2(40), run number, reads number, redo number,
                        cpu number, ela number);
create table m08d_plan (stmt varchar2(40), ln number, line varchar2(400));
create table m08d_vs (label varchar2(40), phase number, sql_id varchar2(13), child number,
                      execs number, rws number, gets number, txt varchar2(400),
                      cpu number, ela number);

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

-- The knob-3 document: its JSON text size, its stored (OSON) size, and whether
-- its body is stored out of the row. The OSON bytes are taken by serializing
-- the JSON value in PL/SQL into a BLOB column that only accepts OSON (the check
-- constraint proves the format). The column's in-row part (vsize) is a LOB
-- locator when the body is out of row.
create table m08d_oson (b blob check (b is json format oson));

declare
  j  json;
  ob number;
  ib number;
begin
  select d.data, vsize(d.data) into j, ib from m08d_doc d where d.data."_id" = 1;
  insert into m08d_oson values (json_serialize(j returning blob));
  select dbms_lob.getlength(b) into ob from m08d_oson;
  m08_meter.record('wr-k3-doc-oson-bytes', ob);
  m08_meter.record('wr-k3-doc-inrow-bytes', ib);
  m08_meter.record('wr-k3-doc-out-of-row', case when ib < ob then 1 else 0 end);
  commit;
end;
/

insert into m08_metrics (name, value)
  select 'wr-k3-doc-text-bytes', dbms_lob.getlength(json_serialize(d.data returning blob))
    from m08d_doc d where d.data."_id" = 1;

-- ===== Shared measuring helpers =====
create or replace package m08d_h as
  -- Extra runs per write for its v$sql CPU window. The session statistics
  -- (reads, redo) are sampled on runs 1 to 20 as before; the CPU window then
  -- covers the next c_cpu_runs runs, because v$sql CPU moves in steps of about
  -- 1 ms per window (10 microseconds per run over 100 runs).
  c_cpu_runs constant pls_integer := 100;
  -- The meter overhead recorded above (reads, redo).
  function ovr return number;
  function ovd return number;
  function v(p_name varchar2) return number;
  -- Close one counted window (run > 0) and keep it in memory.
  procedure sample(p_stmt varchar2, p_run number);
  -- Store the kept samples, then record wr-<stmt>-<stat>-median/-max.
  procedure summarize(p_stmt varchar2);
  -- Executed plan of the newest valid cursor carrying the marker.
  procedure capture(p_stmt varchar2, p_marker varchar2);
  -- v$sql growth of the statements whose upper-case text matches a regular
  -- expression: vs_snap purges their cursors (so the counts start fresh; a
  -- cursor reloaded after an earlier run's DROP would otherwise mis-count) and
  -- takes a snapshot before a loop; vs_done records the growth per statement
  -- class, per call, and one PLAN row per statement.
  procedure vs_snap(p_label varchar2, p_pattern varchar2);
  -- vs_mark: a second snapshot right after the warm-up call, so CPU and
  -- elapsed (-us-per-call, -ela-us-per-call) leave out the warm-up's parse.
  -- They are taken over p_calls - 1 calls; executions, rows and gets keep
  -- the whole window (p_calls calls) as before.
  procedure vs_mark(p_label varchar2);
  procedure vs_done(p_label varchar2, p_calls number);
end m08d_h;
/

create or replace package body m08d_h as
  type t_s is record (stmt varchar2(40), run number, reads number, redo number,
                      cpu number, ela number);
  type t_ss is table of t_s;
  g_buf t_ss := t_ss();
  type t_pat is table of varchar2(200) index by varchar2(40);
  g_pat t_pat;

  function v(p_name varchar2) return number is
    x number;
  begin
    select value into x from m08_metrics where name = p_name;
    return x;
  end;

  function ovr return number is begin return v('wr-meter-overhead-reads'); end;
  function ovd return number is begin return v('wr-meter-overhead-redo'); end;

  procedure sample(p_stmt varchar2, p_run number) is
    r  number := m08_meter.delta('session logical reads');
    d  number := m08_meter.delta('redo size');
    c  number := m08_meter.delta('CPU used by this session');
    el number := m08_meter.elapsed_cs;
  begin
    if p_run > 0 then
      g_buf.extend;
      g_buf(g_buf.count) := t_s(p_stmt, p_run, r, d, c, el);
    end if;
  end;

  procedure summarize(p_stmt varchar2) is
    o_r number := ovr;
    o_d number := ovd;
  begin
    for i in 1 .. g_buf.count loop
      insert into m08d_samp values (g_buf(i).stmt, g_buf(i).run, greatest(g_buf(i).reads - o_r, 0),
                                    greatest(g_buf(i).redo - o_d, 0), g_buf(i).cpu, g_buf(i).ela);
    end loop;
    g_buf.delete;
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

  procedure vs_take(p_label varchar2, p_phase number) is
  begin
    insert into m08d_vs (label, phase, sql_id, child, execs, rws, gets, txt, cpu, ela)
      select p_label, p_phase, sql_id, child_number, executions, rows_processed, buffer_gets,
             substr(sql_text, 1, 400), cpu_time, elapsed_time
        from v$sql
       where regexp_like(upper(sql_text), g_pat(p_label))
         and upper(sql_text) not like '%V$SQL%';
  end;

  procedure vs_snap(p_label varchar2, p_pattern varchar2) is
  begin
    g_pat(p_label) := p_pattern;
    for c in (select distinct address || ',' || hash_value n from v$sql
               where regexp_like(upper(sql_text), p_pattern)
                 and upper(sql_text) not like '%V$SQL%') loop
      begin
        sys.dbms_shared_pool.purge(c.n, 'C');
      exception
        -- A failed purge leaves an old count in the window; record it so it
        -- shows as wr-purge-failures instead of passing silently.
        when others then m08_meter.record('tmp:wr-purge-failed', 1);
      end;
    end loop;
    vs_take(p_label, 0);
  end;

  -- Statement class: refresh-del / refresh-ins for the MV refresh, otherwise
  -- the first word and the table, e.g. insert-line, update-line, insert-mlog-cust.
  procedure vs_mark(p_label varchar2) is
  begin
    vs_take(p_label, 2);
  end;

  procedure vs_done(p_label varchar2, p_calls number) is
    n number := 0;
  begin
    vs_take(p_label, 1);
    for c in (select cls, sum(de) de, sum(dr) dr, sum(dg) dg, sum(dc) dc, sum(dl) dl
                from (select case
                               when a.txt like '/* MV_REFRESH (DEL)%' then 'refresh-del'
                               when a.txt like '/* MV_REFRESH (INS)%' then 'refresh-ins'
                               else nvl(lower(regexp_substr(ltrim(a.txt), '^[A-Za-z]+')), 'other')
                                    || '-' || replace(regexp_replace(regexp_replace(
                                         lower(replace(regexp_substr(upper(a.txt),
                                           '"(MLOG\$_)?M08D_[A-Z0-9_]+"'), '"')),
                                         '^mlog\$_m08d_', 'mlog-'), '^m08d_', ''), '_', '-')
                             end cls,
                             a.execs - nvl(b.execs, 0) de, a.rws - nvl(b.rws, 0) dr,
                             a.gets - nvl(b.gets, 0) dg, a.cpu - nvl(m.cpu, 0) dc,
                             a.ela - nvl(m.ela, 0) dl
                        from m08d_vs a
                        left join m08d_vs b
                          on b.label = a.label and b.phase = 0 and b.sql_id = a.sql_id
                         and b.child = a.child
                        left join m08d_vs m
                          on m.label = a.label and m.phase = 2 and m.sql_id = a.sql_id
                         and m.child = a.child
                       where a.label = p_label and a.phase = 1
                         and a.execs - nvl(b.execs, 0) > 0)
               group by cls) loop
      n := n + 1;
      m08_meter.record('wr-vs-' || p_label || '-' || rtrim(c.cls, '-') || '-execs-per-call',
                       round(c.de / p_calls, 2));
      m08_meter.record('wr-vs-' || p_label || '-' || rtrim(c.cls, '-') || '-rows-per-call',
                       round(c.dr / p_calls, 2));
      m08_meter.record('wr-vs-' || p_label || '-' || rtrim(c.cls, '-') || '-gets-per-call',
                       round(c.dg / p_calls, 2));
      m08_meter.record('wr-vs-' || p_label || '-' || rtrim(c.cls, '-') || '-us-per-call',
                       round(c.dc / (p_calls - 1)));
      m08_meter.record('wr-vs-' || p_label || '-' || rtrim(c.cls, '-') || '-ela-us-per-call',
                       round(c.dl / (p_calls - 1)));
    end loop;
    -- One PLAN row per statement: growth per call and the text.
    insert into m08d_plan (stmt, ln, line)
      select 'vsql-' || p_label, rownum,
             substr('per call: execs ' || round(de / p_calls, 2) || ', rows ' || round(dr / p_calls, 2)
                    || ', gets ' || round(dg / p_calls, 2) || ' | ' || regexp_replace(txt, '\s+', ' '),
                    1, 400)
        from (select min(a.txt) txt, sum(a.execs - nvl(b.execs, 0)) de,
                     sum(a.rws - nvl(b.rws, 0)) dr, sum(a.gets - nvl(b.gets, 0)) dg
                from m08d_vs a
                left join m08d_vs b
                  on b.label = a.label and b.phase = 0 and b.sql_id = a.sql_id and b.child = a.child
               where a.label = p_label and a.phase = 1 and a.execs - nvl(b.execs, 0) > 0
               group by a.sql_id
               order by 4 desc);
    m08_meter.record('tmp:wr-vs-' || p_label || '-classes', n);
  end;
end m08d_h;
/

-- ===== Parts 1 to 3 =====
create or replace procedure m08d_measure as
  ok   number;
  n    number;
  v1   number;
  v2   number;
  v3   number;
  urec number;
  j    json;
  e    clob;
  type t_num  is table of number;
  type t_vc   is table of varchar2(20);
  type t_base is table of number index by varchar2(20);
  ids   t_num;
  skus  t_vc;
  qtys  t_num;
  bases t_base;
  -- Order ids are handed out in call order, so every insert into the orders
  -- and lines tables (dv, sql, sqlrow) lands at the right edge of its indexes.
  next_id number := 100000;

  -- The document for order p_id with k lines; its content depends only on
  -- (k, total), never on the id, so the paths can be compared.
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

  -- Content signature, without ids: custId|status|total|lines|lineNo:sku:qty,...
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

  -- qty of one line of order 1, read three ways.
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

  -- One insert path, one k: 1 warm-up, 20 counted runs and 100 CPU runs, each
  -- with its commit.
  -- The markers of each write path's statements, for its v$sql window.
  function mk_of(p_stmt varchar2) return varchar2 is
  begin
    return case p_stmt
      when 'ins-col' then 'M08DXIC'       when 'ins-dv' then 'M08DXID'
      when 'ins-sql' then 'M08DXIO,M08DXIL' when 'ins-sqlrow' then 'M08DXIRO,M08DXIRL'
      when 'k3-col' then 'M08DXK3C'       when 'k3-colpos' then 'M08DXK3P'
      when 'k3-colrep' then 'M08DXK3R'    when 'k3-dv' then 'M08DXK3V'
      when 'k3-sql' then 'M08DXK3S'       when 'fu-col' then 'M08DXFUC'
      when 'fu-dv' then 'M08DXFUV'
    end;
  end;

  procedure insert_path(p_path varchar2, p_k number) is
    base number := next_id;
    id   number;
  begin
    bases(p_path || p_k) := base;
    next_id := next_id + 21 + m08d_h.c_cpu_runs;
    for r in 0 .. 20 + m08d_h.c_cpu_runs loop
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
      elsif p_path = 'sql' then
        insert /*+ gather_plan_statistics M08DXIO */ into m08d_ord (ord_id, cust_id, status, total)
          values (id, 7, 'NEW', p_k * 10 + r);
        forall i in 1 .. ids.count
          insert /*+ gather_plan_statistics M08DXIL */ into m08d_line (line_id, ord_id, sku, qty)
            values (ids(i), id, skus(i), qtys(i));
      else
        insert /*+ gather_plan_statistics M08DXIRO */ into m08d_ord (ord_id, cust_id, status, total)
          values (id, 7, 'NEW', p_k * 10 + r);
        for i in 1 .. ids.count loop
          insert /*+ gather_plan_statistics M08DXIRL */ into m08d_line (line_id, ord_id, sku, qty)
            values (ids(i), id, skus(i), qtys(i));
        end loop;
      end if;
      commit;
      if r <= 20 then m08d_h.sample('ins-' || p_path || '-k' || p_k, r); end if;
      if r = 0 and p_path = 'dv' then m08d_h.vs_mark('ins-dv-k' || p_k); end if;
      if r = 20 then m08_meter.vs_begin(mk_of('ins-' || p_path)); end if;
    end loop;
    m08_meter.vs_end('wr-ins-' || p_path || '-k' || p_k, mk_of('ins-' || p_path), m08d_h.c_cpu_runs);
    m08d_h.summarize('ins-' || p_path || '-k' || p_k);
  end;

  -- Knob 3: change line 1500's qty in order 1 (1,000 lines). Every run writes a
  -- new 3-digit value (col 100 + r, colpos 400 + r, colrep 500 + r, dv 200 + r,
  -- sql 300 + r, r up to 120), so every run is a real change of the same length.
  procedure knob3(p_path varchar2) is
  begin
    for r in 0 .. 20 + m08d_h.c_cpu_runs loop
      if p_path = 'colrep' then
        -- The whole new document, built before the window opens.
        select json_transform(d.data, set '$.lines[499].qty' = 500 + r) into j
          from m08d_doc d where d.data."_id" = 1;
      end if;
      m08_meter.snap;
      if p_path = 'col' then
        update /*+ gather_plan_statistics M08DXK3C */ m08d_doc d
           set d.data = json_transform(d.data, set '$.lines[*]?(@.lineId == 1500).qty' = 100 + r)
         where d.data."_id" = 1;
      elsif p_path = 'colpos' then
        update /*+ gather_plan_statistics M08DXK3P */ m08d_doc d
           set d.data = json_transform(d.data, set '$.lines[499].qty' = 400 + r)
         where d.data."_id" = 1;
      elsif p_path = 'colrep' then
        update /*+ gather_plan_statistics M08DXK3R */ m08d_doc d
           set d.data = j
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
      if r <= 20 then m08d_h.sample('k3-' || p_path, r); end if;
      if r = 0 and p_path = 'dv' then m08d_h.vs_mark('k3-dv'); end if;
      if r = 20 then m08_meter.vs_begin(mk_of('k3-' || p_path)); end if;
    end loop;
    m08_meter.vs_end('wr-k3-' || p_path, mk_of('k3-' || p_path), m08d_h.c_cpu_runs);
    m08_meter.record('wr-k3-' || p_path || '-rows', n);
    m08d_h.summarize('k3-' || p_path);
  end;

  -- SELECT ... FOR UPDATE of order 1's document, then COMMIT. Before the
  -- COMMIT, the transaction's undo records are read: one per locked row.
  procedure for_update(p_what varchar2) is
  begin
    for r in 0 .. 20 + m08d_h.c_cpu_runs loop
      m08_meter.snap;
      if p_what = 'col' then
        select /*+ gather_plan_statistics M08DXFUC */ d.data into j
          from m08d_doc d where d.data."_id" = 1 for update;
      else
        select /*+ gather_plan_statistics M08DXFUV */ d.data into j
          from m08d_ord_dv d where d.data."_id" = 1 for update;
      end if;
      begin
        select t.used_urec into urec
          from v$transaction t join v$session s on s.taddr = t.addr
         where s.sid = sys_context('userenv', 'sid');
      exception
        when no_data_found then urec := 0;
      end;
      commit;
      if r <= 20 then m08d_h.sample('fu-' || p_what, r); end if;
      if r = 20 then m08_meter.vs_begin(mk_of('fu-' || p_what)); end if;
    end loop;
    m08_meter.vs_end('wr-fu-' || p_what, mk_of('fu-' || p_what), m08d_h.c_cpu_runs);
    m08_meter.record('wr-fu-' || p_what || '-undo-records', urec);
    m08d_h.summarize('fu-' || p_what);
  end;

begin
  -- Purge every marked write cursor once, before the first write.
  m08_meter.record('tmp:wr-us-purge-left-parts12',
                   m08_meter.vs_purge('M08DXIC,M08DXID,M08DXIO,M08DXIL,M08DXIRO,M08DXIRL,'
                                      || 'M08DXK3C,M08DXK3P,M08DXK3R,M08DXK3V,M08DXK3S,M08DXFUC,M08DXFUV'));
  -- ----- Part 1: inserts -----
  for k in (select 10 k from dual union all select 100 from dual) loop
    insert_path('col', k.k);
    m08d_h.vs_snap('ins-dv-k' || k.k, '"' || sys_context('userenv', 'current_schema') || '"\."M08D_');
    insert_path('dv', k.k);
    m08d_h.vs_done('ins-dv-k' || k.k, 21 + m08d_h.c_cpu_runs);
    insert_path('sql', k.k);
    insert_path('sqlrow', k.k);
  end loop;
  m08d_h.capture('ins-col', 'M08DXIC');
  m08d_h.capture('ins-dv', 'M08DXID');
  m08d_h.capture('ins-sql-ord', 'M08DXIO');
  m08d_h.capture('ins-sql-line', 'M08DXIL');
  m08d_h.capture('ins-sqlrow-ord', 'M08DXIRO');
  m08d_h.capture('ins-sqlrow-line', 'M08DXIRL');

  -- Same content: for every (k, run), the four paths hold the same order, read
  -- back as the collection document, the duality-view document and table rows.
  -- The k-line count is part of the signature.
  ok := 0;
  for k in (select 10 k from dual union all select 100 from dual) loop
    for r in 0 .. 20 loop
      if sig_doc('m08d_doc', bases('col' || k.k) + r) = sig_doc('m08d_ord_dv', bases('dv' || k.k) + r)
         and sig_doc('m08d_ord_dv', bases('dv' || k.k) + r) = sig_sql(bases('sql' || k.k) + r)
         and sig_sql(bases('sql' || k.k) + r) = sig_sql(bases('sqlrow' || k.k) + r)
         and sig_sql(bases('sql' || k.k) + r) like '7|NEW|' || (k.k * 10 + r) || '|' || k.k || '|%' then
        ok := ok + 1;
      end if;
    end loop;
  end loop;
  m08_meter.record('tmp:wr-ins-same-content', ok);

  -- ----- Part 2: knob 3 -----
  -- The positional arm needs line 1500 at position 499.
  select count(*) into n from m08d_doc d
   where d.data."_id" = 1 and json_value(d.data, '$.lines[499].lineId' returning number) = 1500;
  m08_meter.record('tmp:wr-k3-pos-is-1500', n);
  v1 := qty_tab(1499);
  knob3('col');
  knob3('colpos');
  knob3('colrep');
  m08d_h.vs_snap('k3-dv', '"' || sys_context('userenv', 'current_schema') || '"\."M08D_');
  knob3('dv');
  m08d_h.vs_done('k3-dv', 21 + m08d_h.c_cpu_runs);
  -- After the duality-view update, the change is in the line row.
  m08_meter.record('tmp:wr-k3-dv-in-table',
                   case when qty_tab(1500) = 220 + m08d_h.c_cpu_runs then 1 else 0 end);
  knob3('sql');
  for_update('col');
  for_update('dv');
  m08d_h.capture('k3-col', 'M08DXK3C');
  m08d_h.capture('k3-colpos', 'M08DXK3P');
  m08d_h.capture('k3-colrep', 'M08DXK3R');
  m08d_h.capture('k3-dv', 'M08DXK3V');
  m08d_h.capture('k3-sql', 'M08DXK3S');
  m08d_h.capture('fu-col', 'M08DXFUC');
  m08d_h.capture('fu-dv', 'M08DXFUV');
  -- Every read shows its last change; the neighbouring line is untouched; the
  -- documents still have 1,000 lines.
  select count(*) into n from m08d_doc d, json_table(d.data, '$.lines[*]' columns (x number path '$.lineId')) jt
   where d.data."_id" = 1;
  select count(*) into v2 from m08d_ord_dv d, json_table(d.data, '$.lines[*]' columns (x number path '$.lineId')) jt
   where d.data."_id" = 1;
  m08_meter.record('tmp:wr-k3-visible',
                   case when qty_col(1500) = 520 + m08d_h.c_cpu_runs
                         and qty_dv(1500) = 320 + m08d_h.c_cpu_runs
                         and qty_tab(1500) = 320 + m08d_h.c_cpu_runs
                         and qty_col(1499) = v1 and qty_dv(1499) = v1 and qty_tab(1499) = v1
                         and n = 1000 and v2 = 1000
                        then 1 else 0 end);

  -- ----- Part 3: etags -----
  -- Every order document's etag and text, as a client holds them.
  insert into m08d_s4etag (ord_id, etag, doc)
    select d.data."_id".number(), json_value(d.data, '$._metadata.etag'),
           json_serialize(d.data returning clob)
      from m08d_s4ord_dv d;
  commit;
  -- The one rename, through the customer-centric view, measured with its commit.
  m08_meter.snap;
  update m08d_s4cust_dv d
     set d.data = json_transform(d.data, set '$.name' = 'Renamed Customer')
   where d.data."_id" = 1;
  n := sql%rowcount;
  commit;
  v1 := m08_meter.delta('session logical reads');
  v2 := m08_meter.delta('redo size');
  m08_meter.record('wr-s4d-rename-reads', greatest(v1 - m08d_h.ovr, 0));
  m08_meter.record('wr-s4d-rename-redo', greatest(v2 - m08d_h.ovd, 0));
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
  n    number;
  cnt  number;
  nref number := 0;
  t    varchar2(10);

  -- One tier change on customer 1 plus COMMIT, 1 warm-up, 20 counted runs and
  -- 100 CPU runs.
  -- The tiers alternate, so every run is a real change. Phase 1 starts from
  -- BRONZE and ends on SILVER; phase 2 (offset 1) starts with GOLD, so its
  -- first run already differs from the MV's starting content, and ends on GOLD.
  -- In phase 2, after every COMMIT, the MV must show the new tier on all 100
  -- of customer 1's rows.
  procedure tier_change(p_stmt varchar2, p_off number) is
  begin
    for r in 0 .. 20 + m08d_h.c_cpu_runs loop
      t := case mod(r + p_off, 2) when 0 then 'SILVER' else 'GOLD' end;
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
      if r <= 20 then m08d_h.sample(p_stmt, r); end if;
      if r = 0 and p_stmt = 'mv-upd-mv' then m08d_h.vs_mark('mv-refresh'); end if;
      if r = 20 then
        m08_meter.vs_begin(case p_stmt when 'mv-upd-embedded' then 'M08DXMUE' else 'M08DXMU' end);
      end if;
      if p_stmt = 'mv-upd-mv' then
        execute immediate 'select count(*) from m08d_ord_cust_mv where cust_id = 1 and tier = :1'
          into cnt using t;
        if cnt = 100 then nref := nref + 1; end if;
      end if;
    end loop;
    m08_meter.record('wr-' || p_stmt || '-rows', n);
    m08_meter.vs_end('wr-' || p_stmt, case p_stmt when 'mv-upd-embedded' then 'M08DXMUE' else 'M08DXMU' end,
                     m08d_h.c_cpu_runs);
    m08d_h.summarize(p_stmt);
  end;
begin
  if p_phase = 1 then
    m08_meter.record('tmp:wr-us-purge-left-mv', m08_meter.vs_purge('M08DXMUE,M08DXMU'));
    m08_meter.measure_repeat('wr-mv-read-embedded',
      'select /*+ gather_plan_statistics M08DXMRE */ json_serialize(d.data returning blob)'
      || ' from m08d_emb d where d.data."_id" = 201', 20, p_allow_lob => true);
    m08_meter.measure_repeat('wr-mv-read-normalized',
      'select /*+ gather_plan_statistics index(o m08d_cord_pk) index(c m08d_cust_pk) M08DXMRN */'
      || ' o.id, o.status, o.total, c.id, c.name, c.tier'
      || ' from m08d_cord o join m08d_cust c on c.id = o.cust_id where o.id = 201', 20);
    m08d_h.capture('mv-read-embedded', 'M08DXMRE');
    m08d_h.capture('mv-read-normalized', 'M08DXMRN');
    -- CPU, elapsed and bytes of the two reads (v$sql, 200 runs), with their own
    -- markers and without gather_plan_statistics.
    m08_meter.measure_us('wr-mv-read-embedded',
      'select /*+ M08DXTMRE */ json_serialize(d.data returning blob)'
      || ' from m08d_emb d where d.data."_id" = 201', 'M08DXTMRE', p_allow_lob => true);
    m08_meter.measure_us('wr-mv-read-normalized',
      'select /*+ index(o m08d_cord_pk) index(c m08d_cust_pk) M08DXTMRN */'
      || ' o.id, o.status, o.total, c.id, c.name, c.tier'
      || ' from m08d_cord o join m08d_cust c on c.id = o.cust_id where o.id = 201', 'M08DXTMRN');
    tier_change('mv-upd-embedded', 0);
    m08d_h.capture('mv-upd-embedded', 'M08DXMUE');
    tier_change('mv-upd-normalized', 0);
    m08d_h.capture('mv-upd-normalized', 'M08DXMU');
  else
    m08_meter.measure_repeat('wr-mv-read-mv',
      'select /*+ gather_plan_statistics M08DXMRM */ m.id, m.status, m.total, m.cust_id, m.name, m.tier'
      || ' from m08d_ord_cust_mv m where m.id = 201', 20);
    m08d_h.capture('mv-read-mv', 'M08DXMRM');
    m08_meter.measure_us('wr-mv-read-mv',
      'select /*+ M08DXTMRM */ m.id, m.status, m.total, m.cust_id, m.name, m.tier'
      || ' from m08d_ord_cust_mv m where m.id = 201', 'M08DXTMRM');
    m08d_h.vs_snap('mv-refresh', '"(M08D_ORD_CUST_MV|MLOG\$_M08D_[A-Z_]+)"');
    tier_change('mv-upd-mv', 1);
    m08d_h.vs_done('mv-refresh', 21 + m08d_h.c_cpu_runs);
    m08_meter.record('tmp:wr-mv-refreshed-runs', nref);
    -- The tier change's CPU with its refresh: the update statement (its MV log
    -- insert is recursive inside it) plus every statement the COMMIT runs for
    -- the refresh (all refresh-window classes except the MV log insert).
    select m08d_h.v('wr-mv-upd-mv-us') + nvl(sum(value), 0) into n
      from m08_metrics
     where name like 'wr-vs-mv-refresh-%-us-per-call'
       and name not like '%-ela-us-per-call'
       and name not like 'wr-vs-mv-refresh-insert-mlog%';
    m08_meter.record('wr-mv-upd-mv-total-us', n);
    m08d_h.capture('mv-upd-mv', 'M08DXMU');
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

-- The MV starts with customer 1 at SILVER (phase 1's last change).
insert into m08_metrics (name, value)
  select 'tmp:wr-mv-start-silver', count(*)
    from m08d_ord_cust_mv where cust_id = 1 and tier = 'SILVER';

begin
  m08d_measure_mv(2);
end;
/

-- How the MV was refreshed, as the dictionary reports it after phase 2.
insert into m08_metrics (name, value)
  select 'tmp:wr-mv-mode-ok', case when refresh_mode = 'COMMIT' then 1 else 0 end
    from user_mviews where mview_name = 'M08D_ORD_CUST_MV';

insert into m08_metrics (name, value)
  select 'tmp:wr-mv-last-refresh-fast', case when last_refresh_type = 'FAST' then 1 else 0 end
    from user_mviews where mview_name = 'M08D_ORD_CUST_MV';

-- After the last committed tier change (GOLD, not the MV's starting SILVER):
-- the MV matches the tables for every one of customer 1's orders.
declare
  ok number;
begin
  select case when count(*) = 100
               and count(case when m.tier = 'GOLD' and m.tier = c.tier and m.name = c.name
                               and m.status = o.status and m.total = o.total then 1 end) = 100
              then 1 else 0 end
    into ok
    from m08d_ord_cust_mv m join m08d_cord o on o.id = m.id join m08d_cust c on c.id = o.cust_id
   where c.id = 1;
  m08_meter.record('tmp:wr-mv-reflects', ok);
end;
/

-- ===== Measurements (as METRIC rows) and executed plans (as PLAN rows) =====
-- Cursor purges that failed in vs_snap (0 when every purge worked).
select 'METRIC:wr-purge-failures:' || count(*) from m08_metrics where name = 'tmp:wr-purge-failed';

select 'METRIC:' || name || ':' ||
       case when value = trunc(value) then to_char(value, 'FM999999990')
            else to_char(value, 'FM999999990.00') end
  from m08_metrics
 where name like 'wr-%'
 order by name;

select 'METRIC:wr-mv-refresh-method:' || refresh_method from user_mviews
 where mview_name = 'M08D_ORD_CUST_MV'
union all
select 'METRIC:wr-mv-last-refresh-type:' || last_refresh_type from user_mviews
 where mview_name = 'M08D_ORD_CUST_MV'
union all
select 'METRIC:wr-mv-staleness:' || staleness from user_mviews
 where mview_name = 'M08D_ORD_CUST_MV';

select 'PLAN:' || stmt || ': ' || line
  from m08d_plan
 order by stmt, ln;

-- ===== Assertions (read back from m08_metrics) =====

-- The four insert paths store the same order, for k = 10 and 100, all 21 runs each.
select 'ASSERT:wr-insert-same-content:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-ins-same-content') = 42
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-ins-%-runs' and value = 20) = 8
            then 'PASS' else 'FAIL' end
  from dual;

-- Knob 3: each path ran 121 times (warm-up, 20 counted, 100 CPU runs) with 20
-- counted samples, its last run changed one row or document, the last
-- change is visible in every read (collection, view, table), the neighbouring
-- line is untouched, the view update landed in the line row, and the
-- positional path addressed the same line.
select 'ASSERT:wr-k3-change-visible:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-k3-visible') = 1
             and (select value from m08_metrics where name = 'tmp:wr-k3-dv-in-table') = 1
             and (select value from m08_metrics where name = 'tmp:wr-k3-pos-is-1500') = 1
             and (select count(*) from m08_metrics
                   where name in ('wr-k3-col-rows', 'wr-k3-colpos-rows', 'wr-k3-colrep-rows',
                                  'wr-k3-dv-rows', 'wr-k3-sql-rows') and value = 1) = 5
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-k3-%-runs' and value = 20) = 5
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-fu-%-runs' and value = 20) = 2
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

-- The MV refreshes at every COMMIT: it started at SILVER, every one of the 121
-- phase-2 commits showed its new tier on all 100 MV rows, and after the last
-- (GOLD) the MV matches the tables. Each arm changed the expected rows.
select 'ASSERT:wr-mv-reflects-commit:' ||
       case when (select value from m08_metrics where name = 'tmp:wr-mv-reflects') = 1
             and (select value from m08_metrics where name = 'tmp:wr-mv-start-silver') = 100
             and (select value from m08_metrics where name = 'tmp:wr-mv-refreshed-runs') = 121
             and (select value from m08_metrics where name = 'tmp:wr-mv-mode-ok') = 1
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-mv-upd-%-runs' and value = 20) = 3
             and (select value from m08_metrics where name = 'wr-mv-upd-embedded-rows') = 100
             and (select value from m08_metrics where name = 'wr-mv-upd-normalized-rows') = 1
             and (select value from m08_metrics where name = 'wr-mv-upd-mv-rows') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- When FAST ON COMMIT was accepted, the refreshes really were FAST.
select 'ASSERT:wr-mv-refresh-fast:' ||
       case when (select value from m08_metrics where name = 'wr-mv-fast-on-commit') = 0
              or (select value from m08_metrics where name = 'tmp:wr-mv-last-refresh-fast') = 1
            then 'PASS' else 'FAIL' end
  from dual;

-- Every measured statement has an executed plan with buffers, none of them
-- scanned a whole M08D_ table, and every v$sql window found statements.
select 'ASSERT:wr-plans-captured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:wr-%-xplan-buffers' and value > 0) = 19
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-%-full-scans' and value > 0) = 0
             and (select count(*) from m08_metrics
                   where name like 'tmp:wr-vs-%-classes' and value > 0) = 4
            then 'PASS' else 'FAIL' end
  from dual;

-- The v$sql windows: every write's marked statements ran in every counted
-- run (at least once per call) and the purges left no marked cursor.
select 'ASSERT:wr-us-measured:' ||
       case when (select count(*) from m08_metrics
                   where name like 'tmp:wr-%-execs-per-call' and value >= 1) = 21
            then 'PASS' else 'FAIL' end
  from dual;

select 'ASSERT:wr-us-purge-effective:' ||
       case when (select count(*) from m08_metrics where name like 'tmp:wr-us-purge-left-%') = 2
             and (select count(*) from m08_metrics where name like 'tmp:wr-us-purge-left-%' and value <> 0) = 0
             and (select count(*) from m08_metrics where name like 'tmp:wr-mv-read-%-purge-left' and value = 0) = 3
            then 'PASS' else 'FAIL' end
  from dual;

-- ===== Teardown =====
-- Clear this script's rows first: the DDL below commits, so the validator's
-- rollback would not remove them. The meter package and m08_metrics stay.
delete from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%';

drop procedure if exists m08d_measure_mv;
drop procedure if exists m08d_measure;
drop package if exists m08d_h;
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
drop table if exists m08d_vs purge;
drop table if exists m08d_oson purge;

select 'ASSERT:wr-teardown-clean:' ||
       case when (select count(*) from user_objects
                   where upper(object_name) like 'M08D\_%' escape '\'
                      or upper(object_name) like 'MLOG$\_M08D\_%' escape '\'
                      or upper(object_name) like 'RUPD$\_M08D\_%' escape '\'
                      or upper(object_name) like 'I\_MLOG$\_M08D\_%' escape '\') = 0
             and (select count(*) from m08_metrics where name like 'wr-%' or name like 'tmp:wr-%') = 0
            then 'PASS' else 'FAIL' end
  from dual;
