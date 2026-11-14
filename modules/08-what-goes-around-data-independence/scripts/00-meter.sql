-- Module 08 measurement harness. Idempotent: safe to run any number of times.
-- m08_meter.snap records the session's current statistics and the clock;
-- m08_meter.delta returns how much one statistic grew since the last snap.
-- Supported stats: 'session logical reads', 'redo size', 'execute count',
-- 'CPU used by this session' (centiseconds) and 'elapsed time' (centiseconds,
-- from dbms_utility.get_time; the same value as m08_meter.elapsed_cs).
-- m08_meter.record stores a named value in the session-private GTT m08_metrics.
-- m08_meter.measure_repeat runs one query many times and records its median,
-- min and max cost (see the package spec).

-- GTT for recorded measurements (created only if missing).
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM user_tables WHERE table_name = 'M08_METRICS';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE GLOBAL TEMPORARY TABLE m08_metrics (
                         name  VARCHAR2(100),
                         value NUMBER
                       ) ON COMMIT PRESERVE ROWS';
  END IF;
END;
/

CREATE OR REPLACE PACKAGE m08_meter AS
  PROCEDURE snap;
  FUNCTION delta(p_stat VARCHAR2) RETURN NUMBER;
  FUNCTION elapsed_cs RETURN NUMBER;
  PROCEDURE record(p_name VARCHAR2, p_value NUMBER);
  -- Runs the query p_sql once to warm it (parse and first execution are not
  -- measured), then p_runs more times. Each run is snap, execute, fetch every
  -- row (1,000 rows per fetch call), delta. It calls snap itself, so it
  -- overwrites any snap the caller took before.
  -- The meter's own overhead (snap then the same deltas with no work, measured
  -- once per call after one warm-up) is subtracted from reads only, floored at
  -- 0. CPU and elapsed are reported raw: at 1 cs resolution a single overhead
  -- sample is noise. All three overheads are recorded for audit. Records:
  --   <p_name>-reads-median, -reads-max, -reads-min      ('session logical reads')
  --   <p_name>-cpu-cs-median, -cpu-cs-max                ('CPU used by this session')
  --   <p_name>-elapsed-cs-median, -elapsed-cs-max        (dbms_utility.get_time)
  --   <p_name>-overhead-reads, -overhead-cpu-cs, -overhead-elapsed-cs
  -- The median of an even number of runs is the lower middle value (an
  -- observed run, never an average of two). p_sql must be a single SELECT or
  -- WITH query, and p_name at most 80 bytes (the longest name must fit the
  -- 100-byte metric name).
  -- JSON and LOB columns: a bare column is fetched as a locator, so the
  -- document or LOB body is never read and reads are under-counted. A JSON-type
  -- column always raises ORA-20802; select json_serialize(<col> returning blob)
  -- instead (it builds the whole document, as S1 does) and pass
  -- p_allow_lob => TRUE. Any BLOB or CLOB column raises ORA-20802 unless
  -- p_allow_lob is TRUE; read a stored LOB's bytes with dbms_lob instead.
  PROCEDURE measure_repeat(p_name VARCHAR2, p_sql VARCHAR2, p_runs PLS_INTEGER DEFAULT 20,
                           p_allow_lob BOOLEAN DEFAULT FALSE);

  -- ===== Microsecond CPU from v$sql (the S3 (B) pattern) =====
  -- The session statistic 'CPU used by this session' counts in centiseconds,
  -- too coarse for one small read. v$sql keeps CPU_TIME and ELAPSED_TIME per
  -- cursor in microseconds. These helpers take the growth of v$sql over a
  -- window of calls, for every cursor whose text carries one of the markers in
  -- p_markers (a comma-separated list; each marker sits last in a hint comment,
  -- as ' <marker> */'). The figures are database-side: the statement's own
  -- parse, execute and fetch calls, including recursive SQL it runs (a duality
  -- view's internal statements), but not the client or the network.
  --   vs_purge : purge those cursors, so the next call is parsed fresh, and
  --              return how many are still in v$sql afterwards (0 when the
  --              purge worked)
  --   vs_begin : snapshot their totals (call it after a warm-up run)
  --   vs_end   : record the growth per call, over p_calls calls:
  --                <p_name>-us      CPU microseconds per call
  --                <p_name>-ela-us  elapsed microseconds per call
  --                <p_name>-gets    buffer gets per call (v$sql's logical reads)
  --              and, for checks, tmp:<p_name>-execs-per-call and
  --              tmp:<p_name>-us-phv (plan hash of the child that ran most).
  -- A p_name starting with 'tmp:' records only tmp rows (per-target values
  -- that a script summarizes itself).
  FUNCTION vs_purge(p_markers VARCHAR2) RETURN NUMBER;
  PROCEDURE vs_begin(p_markers VARCHAR2);
  PROCEDURE vs_end(p_name VARCHAR2, p_markers VARCHAR2, p_calls PLS_INTEGER);
  -- Bytes of one execution's result as the client receives it in text form:
  -- for each row and column, dbms_lob.getlength of a LOB (a serialized
  -- document) or lengthb of the value as text (numbers through to_char).
  -- p_bind, when given, is bound to :id.
  FUNCTION result_bytes(p_sql VARCHAR2, p_bind NUMBER DEFAULT NULL) RETURN NUMBER;
  -- One query, the whole pattern: vs_purge (tmp:<p_name>-purge-left), parse,
  -- one warm-up run, vs_begin, p_runs runs fetching every row (as in
  -- measure_repeat), vs_end, then <p_name>-bytes from result_bytes. p_sql
  -- must carry p_marker, and :id when p_bind is given. p_name at most 80 bytes.
  -- p_bytes => FALSE skips the -bytes row (when the script records it already).
  PROCEDURE measure_us(p_name VARCHAR2, p_sql VARCHAR2, p_marker VARCHAR2,
                       p_bind NUMBER DEFAULT NULL, p_runs PLS_INTEGER DEFAULT 200,
                       p_allow_lob BOOLEAN DEFAULT FALSE, p_bytes BOOLEAN DEFAULT TRUE);
  -- The same window for one DML statement that binds :t: purge
  -- (tmp:<p_name>-purge-left), one warm-up run with p_vals(1) and COMMIT,
  -- vs_begin, then p_runs runs, run i binding p_vals(1 + mod(i, count)), each
  -- followed by COMMIT (outside the statement, so not in its CPU), vs_end.
  -- The statement's CPU includes its undo and redo generation.
  PROCEDURE measure_dml_us(p_name VARCHAR2, p_sql VARCHAR2, p_marker VARCHAR2,
                           p_vals sys.odcivarchar2list, p_runs PLS_INTEGER DEFAULT 200);
  -- Logical reads of one query's second execution (the first parses it), each
  -- fetching every row, less the meter's own overhead (measured in the call):
  -- records <p_name>-reads. Binds p_bind to :id when given.
  PROCEDURE measure_reads(p_name VARCHAR2, p_sql VARCHAR2, p_bind NUMBER DEFAULT NULL,
                          p_allow_lob BOOLEAN DEFAULT FALSE);
END m08_meter;
/

CREATE OR REPLACE PACKAGE BODY m08_meter AS
  g_logical_reads NUMBER := 0;
  g_redo_size     NUMBER := 0;
  g_execute_count NUMBER := 0;
  g_cpu           NUMBER := 0;
  g_time          NUMBER := 0;

  c_batch CONSTANT PLS_INTEGER := 1000;

  TYPE t_nums IS TABLE OF NUMBER;

  -- v$sql windows (vs_begin / vs_end): the sql_ids found and their totals.
  TYPE t_win IS RECORD (ids sys.odcivarchar2list, cpu NUMBER, ela NUMBER, gets NUMBER, execs NUMBER);
  TYPE t_wins IS TABLE OF t_win INDEX BY VARCHAR2(400);
  g_wins t_wins;

  FUNCTION cur(p_stat VARCHAR2) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT ms.value INTO v
      FROM v$mystat ms JOIN v$statname sn ON sn.statistic# = ms.statistic#
     WHERE sn.name = p_stat;
    RETURN v;
  END cur;

  -- The clock and CPU are captured first, so the three counters below are
  -- read last, right before the measured work starts.
  PROCEDURE snap IS
  BEGIN
    g_time          := dbms_utility.get_time;
    g_cpu           := cur('CPU used by this session');
    g_logical_reads := cur('session logical reads');
    g_redo_size     := cur('redo size');
    g_execute_count := cur('execute count');
  END snap;

  -- get_time wraps at 2^32; MOD keeps the difference correct across a wrap.
  FUNCTION elapsed_cs RETURN NUMBER IS
  BEGIN
    RETURN MOD(dbms_utility.get_time - g_time + 4294967296, 4294967296);
  END elapsed_cs;

  FUNCTION delta(p_stat VARCHAR2) RETURN NUMBER IS
  BEGIN
    CASE p_stat
      WHEN 'session logical reads'    THEN RETURN cur(p_stat) - g_logical_reads;
      WHEN 'redo size'                THEN RETURN cur(p_stat) - g_redo_size;
      WHEN 'execute count'            THEN RETURN cur(p_stat) - g_execute_count;
      WHEN 'CPU used by this session' THEN RETURN cur(p_stat) - g_cpu;
      WHEN 'elapsed time'             THEN RETURN elapsed_cs;
      ELSE RAISE_APPLICATION_ERROR(-20801, 'm08_meter.delta: unsupported stat ' || p_stat);
    END CASE;
  END delta;

  PROCEDURE record(p_name VARCHAR2, p_value NUMBER) IS
  BEGIN
    INSERT INTO m08_metrics (name, value) VALUES (p_name, p_value);
  END record;

  -- One measurement: the three deltas, always read in the same order, so the
  -- overhead run and the measured runs pay the same meter cost.
  PROCEDURE take(r OUT NUMBER, c OUT NUMBER, e OUT NUMBER) IS
  BEGIN
    r := delta('session logical reads');
    c := delta('CPU used by this session');
    e := elapsed_cs;
  END take;

  -- Defines every column of an open query cursor as an array of its own type,
  -- so each fetch call returns up to c_batch rows.
  PROCEDURE define_all(p_cur INTEGER, p_allow_lob BOOLEAN) IS
    n    INTEGER;
    d    dbms_sql.desc_tab2;
    v_vc dbms_sql.varchar2_table;
    v_n  dbms_sql.number_table;
    v_bf dbms_sql.binary_float_table;
    v_bd dbms_sql.binary_double_table;
    v_d  dbms_sql.date_table;
    v_cl dbms_sql.clob_table;
    v_bl dbms_sql.blob_table;
    v_ts dbms_sql.timestamp_table;
    v_tz dbms_sql.timestamp_with_time_zone_table;
    v_tl dbms_sql.timestamp_with_ltz_table;
    v_ym dbms_sql.interval_year_to_month_table;
    v_ds dbms_sql.interval_day_to_second_table;
    v_ur dbms_sql.urowid_table;
  BEGIN
    dbms_sql.describe_columns2(p_cur, n, d);
    FOR i IN 1 .. n LOOP
      CASE
        WHEN d(i).col_type IN (1, 96) AND d(i).col_max_len <= 2000
                                       THEN dbms_sql.define_array(p_cur, i, v_vc, c_batch, 1);
        WHEN d(i).col_type IN (1, 96)  THEN dbms_sql.define_array(p_cur, i, v_cl, c_batch, 1);
        WHEN d(i).col_type = 2         THEN dbms_sql.define_array(p_cur, i, v_n,  c_batch, 1);
        WHEN d(i).col_type = 100       THEN dbms_sql.define_array(p_cur, i, v_bf, c_batch, 1);
        WHEN d(i).col_type = 101       THEN dbms_sql.define_array(p_cur, i, v_bd, c_batch, 1);
        WHEN d(i).col_type = 12        THEN dbms_sql.define_array(p_cur, i, v_d,  c_batch, 1);
        WHEN d(i).col_type = 119 THEN
          RAISE_APPLICATION_ERROR(-20802, 'm08_meter.measure_repeat: column ' || i
            || ' is JSON and would be fetched as a locator (reads under-counted);'
            || ' select json_serialize(<col> returning blob) with p_allow_lob => TRUE');
        WHEN d(i).col_type IN (112, 113) AND NOT NVL(p_allow_lob, FALSE) THEN
          RAISE_APPLICATION_ERROR(-20802, 'm08_meter.measure_repeat: column ' || i
            || ' is a LOB and would be fetched as a locator (reads under-counted);'
            || ' read its bytes with dbms_lob, or pass p_allow_lob => TRUE for a'
            || ' serialized value such as json_serialize(<col> returning blob)');
        WHEN d(i).col_type = 112       THEN dbms_sql.define_array(p_cur, i, v_cl, c_batch, 1);
        WHEN d(i).col_type = 113       THEN dbms_sql.define_array(p_cur, i, v_bl, c_batch, 1);
        WHEN d(i).col_type = 180       THEN dbms_sql.define_array(p_cur, i, v_ts, c_batch, 1);
        WHEN d(i).col_type = 181       THEN dbms_sql.define_array(p_cur, i, v_tz, c_batch, 1);
        WHEN d(i).col_type = 231       THEN dbms_sql.define_array(p_cur, i, v_tl, c_batch, 1);
        WHEN d(i).col_type = 182       THEN dbms_sql.define_array(p_cur, i, v_ym, c_batch, 1);
        WHEN d(i).col_type = 183       THEN dbms_sql.define_array(p_cur, i, v_ds, c_batch, 1);
        WHEN d(i).col_type IN (11, 69, 208)
                                       THEN dbms_sql.define_array(p_cur, i, v_ur, c_batch, 1);
        ELSE RAISE_APPLICATION_ERROR(-20802, 'm08_meter.measure_repeat: column ' || i
                                     || ' has unsupported type ' || d(i).col_type);
      END CASE;
    END LOOP;
  END define_all;

  -- Executes the parsed query and fetches every row.
  PROCEDURE run_all(p_cur INTEGER) IS
    n INTEGER;
  BEGIN
    n := dbms_sql.execute(p_cur);
    LOOP
      n := dbms_sql.fetch_rows(p_cur);
      EXIT WHEN n < c_batch;
    END LOOP;
  END run_all;

  -- Ascending insertion sort; the runs are few.
  PROCEDURE sort_asc(p IN OUT NOCOPY t_nums) IS
    k NUMBER;
    j PLS_INTEGER;
  BEGIN
    FOR i IN 2 .. p.COUNT LOOP
      k := p(i);
      j := i - 1;
      WHILE j >= 1 AND p(j) > k LOOP
        p(j + 1) := p(j);
        j := j - 1;
      END LOOP;
      p(j + 1) := k;
    END LOOP;
  END sort_asc;

  -- Lower median: element TRUNC((n + 1) / 2) of the sorted values.
  FUNCTION median_low(p t_nums) RETURN NUMBER IS
    s t_nums := p;
  BEGIN
    sort_asc(s);
    RETURN s(TRUNC((s.COUNT + 1) / 2));
  END median_low;

  FUNCTION max_of(p t_nums) RETURN NUMBER IS
    m NUMBER := p(1);
  BEGIN
    FOR i IN 2 .. p.COUNT LOOP m := GREATEST(m, p(i)); END LOOP;
    RETURN m;
  END max_of;

  FUNCTION min_of(p t_nums) RETURN NUMBER IS
    m NUMBER := p(1);
  BEGIN
    FOR i IN 2 .. p.COUNT LOOP m := LEAST(m, p(i)); END LOOP;
    RETURN m;
  END min_of;

  PROCEDURE measure_repeat(p_name VARCHAR2, p_sql VARCHAR2, p_runs PLS_INTEGER DEFAULT 20,
                           p_allow_lob BOOLEAN DEFAULT FALSE) IS
    c     INTEGER;
    reads t_nums := t_nums();
    cpus  t_nums := t_nums();
    els   t_nums := t_nums();
    o_r   NUMBER;
    o_c   NUMBER;
    o_e   NUMBER;
    r     NUMBER;
    cp    NUMBER;
    e     NUMBER;
  BEGIN
    IF p_runs IS NULL OR p_runs < 1 THEN
      RAISE_APPLICATION_ERROR(-20803, 'm08_meter.measure_repeat: p_runs must be >= 1');
    END IF;
    IF NOT REGEXP_LIKE(p_sql, '^\s*(\(\s*)*(select|with)\s', 'i') THEN
      RAISE_APPLICATION_ERROR(-20804, 'm08_meter.measure_repeat: p_sql must be a query');
    END IF;
    -- '-overhead-elapsed-cs' (20 bytes) is the longest suffix; names are VARCHAR2(100).
    IF p_name IS NULL OR LENGTHB(p_name) + 20 > 100 THEN
      RAISE_APPLICATION_ERROR(-20805, 'm08_meter.measure_repeat: p_name must be 1 to 80 bytes');
    END IF;

    -- Meter overhead: snap then the same deltas with no work. One warm-up, then
    -- the measured one.
    FOR i IN 1 .. 2 LOOP
      snap;
      take(o_r, o_c, o_e);
    END LOOP;

    c := dbms_sql.open_cursor;
    BEGIN
      dbms_sql.parse(c, p_sql, dbms_sql.native);
      define_all(c, p_allow_lob);
      run_all(c);                       -- warm-up run, not measured
      reads.EXTEND(p_runs);
      cpus.EXTEND(p_runs);
      els.EXTEND(p_runs);
      FOR i IN 1 .. p_runs LOOP
        snap;
        run_all(c);
        take(r, cp, e);
        reads(i) := GREATEST(r  - o_r, 0);
        cpus(i)  := cp;                  -- raw: see the spec comment
        els(i)   := e;
      END LOOP;
      dbms_sql.close_cursor(c);
    EXCEPTION
      WHEN OTHERS THEN
        IF dbms_sql.is_open(c) THEN dbms_sql.close_cursor(c); END IF;
        RAISE;
    END;

    record(p_name || '-reads-median',      median_low(reads));
    record(p_name || '-reads-max',         max_of(reads));
    record(p_name || '-reads-min',         min_of(reads));
    record(p_name || '-cpu-cs-median',     median_low(cpus));
    record(p_name || '-cpu-cs-max',        max_of(cpus));
    record(p_name || '-elapsed-cs-median', median_low(els));
    record(p_name || '-elapsed-cs-max',    max_of(els));
    record(p_name || '-overhead-reads',      o_r);
    record(p_name || '-overhead-cpu-cs',     o_c);
    record(p_name || '-overhead-elapsed-cs', o_e);
  END measure_repeat;

  -- ----- v$sql windows -----

  -- ' <m1> */', ' <m2> */', ... as LIKE patterns.
  FUNCTION pats(p_markers VARCHAR2) RETURN sys.odcivarchar2list IS
    l sys.odcivarchar2list := sys.odcivarchar2list();
  BEGIN
    FOR m IN (SELECT trim(regexp_substr(p_markers, '[^,]+', 1, level)) mk FROM dual
               CONNECT BY regexp_substr(p_markers, '[^,]+', 1, level) IS NOT NULL) LOOP
      l.EXTEND;
      l(l.COUNT) := '% ' || m.mk || ' */%';
    END LOOP;
    RETURN l;
  END pats;

  -- The sql_ids of the statements carrying the markers (never a PL/SQL block,
  -- never a query on v$sql).
  FUNCTION ids_of(p_markers VARCHAR2) RETURN sys.odcivarchar2list IS
    l   sys.odcivarchar2list := pats(p_markers);
    ids sys.odcivarchar2list;
  BEGIN
    SELECT DISTINCT s.sql_id BULK COLLECT INTO ids
      FROM v$sql s
     WHERE EXISTS (SELECT 1 FROM TABLE(l) p WHERE s.sql_text LIKE p.column_value)
       AND s.command_type <> 47
       AND upper(s.sql_text) NOT LIKE '%V$SQL%';
    RETURN ids;
  END ids_of;

  -- Purge every cursor of the given sql_ids; return how many are left.
  FUNCTION purge_ids(ids sys.odcivarchar2list) RETURN NUMBER IS
    n_left NUMBER;
  BEGIN
    FOR c IN (SELECT address || ',' || hash_value n FROM v$sql
               WHERE sql_id IN (SELECT column_value FROM TABLE(ids))) LOOP
      BEGIN
        sys.dbms_shared_pool.purge(c.n, 'C');
      EXCEPTION
        WHEN OTHERS THEN NULL;                       -- counted below as a cursor left
      END;
    END LOOP;
    SELECT COUNT(*) INTO n_left FROM v$sql WHERE sql_id IN (SELECT column_value FROM TABLE(ids));
    RETURN n_left;
  END purge_ids;

  FUNCTION vs_purge(p_markers VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN purge_ids(ids_of(p_markers));
  END vs_purge;

  -- Snapshot the totals of the given sql_ids under the window key p_key.
  PROCEDURE begin_ids(p_key VARCHAR2, ids sys.odcivarchar2list) IS
    w t_win;
  BEGIN
    w.ids := ids;
    SELECT nvl(SUM(cpu_time), 0), nvl(SUM(elapsed_time), 0), nvl(SUM(buffer_gets), 0),
           nvl(SUM(executions), 0)
      INTO w.cpu, w.ela, w.gets, w.execs
      FROM v$sql WHERE sql_id IN (SELECT column_value FROM TABLE(w.ids));
    g_wins(p_key) := w;
  END begin_ids;

  PROCEDURE vs_begin(p_markers VARCHAR2) IS
  BEGIN
    begin_ids(p_markers, ids_of(p_markers));
  END vs_begin;

  PROCEDURE vs_end(p_name VARCHAR2, p_markers VARCHAR2, p_calls PLS_INTEGER) IS
    w   t_win := g_wins(p_markers);
    c   NUMBER;
    e   NUMBER;
    g   NUMBER;
    x   NUMBER;
    phv NUMBER;
    tn  VARCHAR2(100) := CASE WHEN p_name LIKE 'tmp:%' THEN p_name ELSE 'tmp:' || p_name END;
  BEGIN
    SELECT nvl(SUM(cpu_time), 0), nvl(SUM(elapsed_time), 0), nvl(SUM(buffer_gets), 0),
           nvl(SUM(executions), 0),
           MAX(plan_hash_value) KEEP (DENSE_RANK LAST ORDER BY executions)
      INTO c, e, g, x, phv
      FROM v$sql WHERE sql_id IN (SELECT column_value FROM TABLE(w.ids));
    record(p_name || '-us',     round((c - w.cpu) / p_calls));
    record(p_name || '-ela-us', round((e - w.ela) / p_calls));
    record(p_name || '-gets',   round((g - w.gets) / p_calls, 1));
    record(tn || '-execs-per-call', round((x - w.execs) / p_calls, 2));
    record(tn || '-us-phv', phv);
    g_wins.DELETE(p_markers);
  END vs_end;

  FUNCTION result_bytes(p_sql VARCHAR2, p_bind NUMBER DEFAULT NULL) RETURN NUMBER IS
    c   INTEGER;
    n   INTEGER;
    d   dbms_sql.desc_tab2;
    vc  VARCHAR2(32767);
    nm  NUMBER;
    bl  BLOB;
    cl  CLOB;
    tot NUMBER := 0;
  BEGIN
    c := dbms_sql.open_cursor;
    BEGIN
      dbms_sql.parse(c, p_sql, dbms_sql.native);
      IF p_bind IS NOT NULL THEN dbms_sql.bind_variable(c, ':id', p_bind); END IF;
      dbms_sql.describe_columns2(c, n, d);
      FOR i IN 1 .. n LOOP
        CASE
          WHEN d(i).col_type IN (1, 96) THEN dbms_sql.define_column(c, i, vc, 32767);
          WHEN d(i).col_type = 2        THEN dbms_sql.define_column(c, i, nm);
          WHEN d(i).col_type = 113      THEN dbms_sql.define_column(c, i, bl);
          WHEN d(i).col_type = 112      THEN dbms_sql.define_column(c, i, cl);
          ELSE RAISE_APPLICATION_ERROR(-20806, 'm08_meter.result_bytes: column ' || i
                                       || ' has unsupported type ' || d(i).col_type);
        END CASE;
      END LOOP;
      n := dbms_sql.execute(c);
      WHILE dbms_sql.fetch_rows(c) > 0 LOOP
        FOR i IN 1 .. d.COUNT LOOP
          CASE
            WHEN d(i).col_type IN (1, 96) THEN
              dbms_sql.column_value(c, i, vc); tot := tot + nvl(lengthb(vc), 0);
            WHEN d(i).col_type = 2 THEN
              dbms_sql.column_value(c, i, nm); tot := tot + nvl(lengthb(to_char(nm)), 0);
            WHEN d(i).col_type = 113 THEN
              dbms_sql.column_value(c, i, bl); tot := tot + nvl(dbms_lob.getlength(bl), 0);
            ELSE
              dbms_sql.column_value(c, i, cl); tot := tot + nvl(dbms_lob.getlength(cl), 0);
          END CASE;
        END LOOP;
      END LOOP;
      dbms_sql.close_cursor(c);
    EXCEPTION
      WHEN OTHERS THEN
        IF dbms_sql.is_open(c) THEN dbms_sql.close_cursor(c); END IF;
        RAISE;
    END;
    RETURN tot;
  END result_bytes;

  PROCEDURE measure_us(p_name VARCHAR2, p_sql VARCHAR2, p_marker VARCHAR2,
                       p_bind NUMBER DEFAULT NULL, p_runs PLS_INTEGER DEFAULT 200,
                       p_allow_lob BOOLEAN DEFAULT FALSE, p_bytes BOOLEAN DEFAULT TRUE) IS
    c   INTEGER;
    ids sys.odcivarchar2list;
    tn  VARCHAR2(100) := CASE WHEN p_name LIKE 'tmp:%' THEN p_name ELSE 'tmp:' || p_name END;
  BEGIN
    IF p_name IS NULL OR LENGTHB(p_name) > 80 THEN
      RAISE_APPLICATION_ERROR(-20805, 'm08_meter.measure_us: p_name must be 1 to 80 bytes');
    END IF;
    IF instr(p_sql, ' ' || p_marker || ' */') = 0 THEN
      RAISE_APPLICATION_ERROR(-20807, 'm08_meter.measure_us: p_sql does not carry ' || p_marker);
    END IF;
    -- The window is the statement's own sql_id, computed from its text (the
    -- same id v$sql shows), so no scan of v$sql is needed.
    ids := sys.odcivarchar2list(dbms_sql_translator.sql_id(p_sql));
    record(tn || '-purge-left', purge_ids(ids));
    c := dbms_sql.open_cursor;
    BEGIN
      dbms_sql.parse(c, p_sql, dbms_sql.native);
      IF p_bind IS NOT NULL THEN dbms_sql.bind_variable(c, ':id', p_bind); END IF;
      define_all(c, p_allow_lob);
      run_all(c);                                   -- warm-up: parse and first run
      begin_ids(p_marker, ids);
      FOR i IN 1 .. p_runs LOOP
        run_all(c);
      END LOOP;
      vs_end(p_name, p_marker, p_runs);
      dbms_sql.close_cursor(c);
    EXCEPTION
      WHEN OTHERS THEN
        IF dbms_sql.is_open(c) THEN dbms_sql.close_cursor(c); END IF;
        RAISE;
    END;
    IF p_bytes THEN
      record(p_name || '-bytes', result_bytes(p_sql, p_bind));
    END IF;
  END measure_us;

  PROCEDURE measure_dml_us(p_name VARCHAR2, p_sql VARCHAR2, p_marker VARCHAR2,
                           p_vals sys.odcivarchar2list, p_runs PLS_INTEGER DEFAULT 200) IS
    ids sys.odcivarchar2list;
    tn  VARCHAR2(100) := CASE WHEN p_name LIKE 'tmp:%' THEN p_name ELSE 'tmp:' || p_name END;
  BEGIN
    IF instr(p_sql, ' ' || p_marker || ' */') = 0 THEN
      RAISE_APPLICATION_ERROR(-20807, 'm08_meter.measure_dml_us: p_sql does not carry ' || p_marker);
    END IF;
    ids := sys.odcivarchar2list(dbms_sql_translator.sql_id(p_sql));
    record(tn || '-purge-left', purge_ids(ids));
    EXECUTE IMMEDIATE p_sql USING p_vals(1);        -- warm-up: parse and first run
    COMMIT;
    begin_ids(p_marker, ids);
    FOR i IN 1 .. p_runs LOOP
      EXECUTE IMMEDIATE p_sql USING p_vals(1 + MOD(i, p_vals.COUNT));
      COMMIT;
    END LOOP;
    vs_end(p_name, p_marker, p_runs);
  END measure_dml_us;

  PROCEDURE measure_reads(p_name VARCHAR2, p_sql VARCHAR2, p_bind NUMBER DEFAULT NULL,
                          p_allow_lob BOOLEAN DEFAULT FALSE) IS
    c   INTEGER;
    o_r NUMBER;
    r   NUMBER;
  BEGIN
    FOR i IN 1 .. 2 LOOP                            -- meter overhead, warm one kept
      snap;
      o_r := delta('session logical reads');
    END LOOP;
    c := dbms_sql.open_cursor;
    BEGIN
      dbms_sql.parse(c, p_sql, dbms_sql.native);
      IF p_bind IS NOT NULL THEN dbms_sql.bind_variable(c, ':id', p_bind); END IF;
      define_all(c, p_allow_lob);
      run_all(c);                                   -- first execution, not counted
      snap;
      run_all(c);
      r := delta('session logical reads');
      dbms_sql.close_cursor(c);
    EXCEPTION
      WHEN OTHERS THEN
        IF dbms_sql.is_open(c) THEN dbms_sql.close_cursor(c); END IF;
        RAISE;
    END;
    record(p_name || '-reads', GREATEST(r - o_r, 0));
  END measure_reads;
END m08_meter;
/

BEGIN
  m08_meter.snap;
END;
/

SELECT 'ASSERT:m08-meter-ready:' || CASE WHEN m08_meter.delta('session logical reads') >= 0 THEN 'PASS' ELSE 'FAIL' END FROM dual;

-- CPU: burn a little CPU after a snap; the CPU delta must not be negative.
BEGIN
  m08_meter.snap;
  FOR i IN 1 .. 200000 LOOP
    NULL;
  END LOOP;
END;
/

SELECT 'ASSERT:m08-meter-cpu-ready:' || CASE WHEN m08_meter.delta('CPU used by this session') >= 0 THEN 'PASS' ELSE 'FAIL' END FROM dual;

-- Repeat helper self-test against a small real table (dropped at the end).
drop table if exists m08_meter_selftest purge;

create table m08_meter_selftest (id number primary key, s varchar2(50), j json);

insert into m08_meter_selftest
  select level, rpad('x', 50, 'x'), json_object('id' value level)
    from dual connect by level <= 500;

BEGIN
  m08_meter.measure_repeat('m08-meter-selftest', 'select id, s from m08_meter_selftest');
END;
/

-- All 10 rows exist, none negative, reads min <= median <= max, and a real
-- table read costs at least one logical read.
SELECT 'ASSERT:m08-meter-repeat-ready:' ||
       CASE WHEN COUNT(DISTINCT name) = 10 AND COUNT(*) = 10 AND MIN(value) >= 0
             AND MAX(CASE WHEN name = 'm08-meter-selftest-reads-min'    THEN value END)
              <= MAX(CASE WHEN name = 'm08-meter-selftest-reads-median' THEN value END)
             AND MAX(CASE WHEN name = 'm08-meter-selftest-reads-median' THEN value END)
              <= MAX(CASE WHEN name = 'm08-meter-selftest-reads-max'    THEN value END)
             AND MAX(CASE WHEN name = 'm08-meter-selftest-reads-median' THEN value END) > 0
            THEN 'PASS' ELSE 'FAIL' END
  FROM m08_metrics
 WHERE name IN ('m08-meter-selftest-reads-median', 'm08-meter-selftest-reads-max',
                'm08-meter-selftest-reads-min', 'm08-meter-selftest-cpu-cs-median',
                'm08-meter-selftest-cpu-cs-max', 'm08-meter-selftest-elapsed-cs-median',
                'm08-meter-selftest-elapsed-cs-max', 'm08-meter-selftest-overhead-reads',
                'm08-meter-selftest-overhead-cpu-cs', 'm08-meter-selftest-overhead-elapsed-cs');

-- A bare JSON column would be fetched as a locator and under-count reads, so
-- the helper must refuse it (ORA-20802).
BEGIN
  BEGIN
    m08_meter.measure_repeat('m08-meter-selftest-json', 'select j from m08_meter_selftest', 1);
    m08_meter.record('m08-meter-selftest-json-guard', 0);
  EXCEPTION
    WHEN OTHERS THEN
      m08_meter.record('m08-meter-selftest-json-guard', CASE WHEN SQLCODE = -20802 THEN 1 ELSE 0 END);
  END;
END;
/

SELECT 'ASSERT:m08-meter-lob-guard:' ||
       CASE WHEN (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-json-guard') = 1
            THEN 'PASS' ELSE 'FAIL' END
  FROM dual;

-- A bare JSON column is refused even when the caller opts in to LOBs: the
-- opt-in covers serialized values only, never a locator-fetched document.
BEGIN
  BEGIN
    m08_meter.measure_repeat('m08-meter-selftest-json2', 'select j from m08_meter_selftest', 1,
                             p_allow_lob => TRUE);
    m08_meter.record('m08-meter-selftest-json-optin-guard', 0);
  EXCEPTION
    WHEN OTHERS THEN
      m08_meter.record('m08-meter-selftest-json-optin-guard', CASE WHEN SQLCODE = -20802 THEN 1 ELSE 0 END);
  END;
END;
/

SELECT 'ASSERT:m08-meter-json-always-rejected:' ||
       CASE WHEN (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-json-optin-guard') = 1
            THEN 'PASS' ELSE 'FAIL' END
  FROM dual;

-- The LOB guard is NULL-safe: p_allow_lob => NULL counts as FALSE, so a LOB
-- column is still refused.
BEGIN
  BEGIN
    m08_meter.measure_repeat('m08-meter-selftest-lobnull',
                             'select json_serialize(j returning blob) from m08_meter_selftest', 1,
                             p_allow_lob => NULL);
    m08_meter.record('m08-meter-selftest-lob-null-guard', 0);
  EXCEPTION
    WHEN OTHERS THEN
      m08_meter.record('m08-meter-selftest-lob-null-guard', CASE WHEN SQLCODE = -20802 THEN 1 ELSE 0 END);
  END;
END;
/

SELECT 'ASSERT:m08-meter-lob-guard-null-safe:' ||
       CASE WHEN (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-lob-null-guard') = 1
            THEN 'PASS' ELSE 'FAIL' END
  FROM dual;

-- The v$sql helper: one marked query, 200 runs (the default). CPU and elapsed are never
-- negative, each run executed the query once, the purge left no cursor, and
-- the bytes equal the result's text length computed in SQL.
BEGIN
  m08_meter.measure_us('m08-meter-selftest-v',
    'select /*+ M08METERSELFTEST */ id, s from m08_meter_selftest where id <= 100',
    'M08METERSELFTEST');
END;
/

SELECT 'ASSERT:m08-meter-us-ready:' ||
       CASE WHEN (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-v-us') >= 0
             AND (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-v-ela-us') >= 0
             AND (SELECT value FROM m08_metrics WHERE name = 'tmp:m08-meter-selftest-v-execs-per-call') = 1
             AND (SELECT value FROM m08_metrics WHERE name = 'tmp:m08-meter-selftest-v-purge-left') = 0
             AND (SELECT value FROM m08_metrics WHERE name = 'm08-meter-selftest-v-bytes') =
                 (SELECT SUM(lengthb(to_char(id)) + lengthb(s)) FROM m08_meter_selftest WHERE id <= 100)
            THEN 'PASS' ELSE 'FAIL' END
  FROM dual;

DELETE FROM m08_metrics WHERE name LIKE 'm08-meter-selftest%' OR name LIKE 'tmp:m08-meter-selftest%';

drop table if exists m08_meter_selftest purge;
