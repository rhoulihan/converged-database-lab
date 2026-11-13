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
  -- row (1,000 rows per fetch call), delta. The meter's own overhead (snap then
  -- delta with no work, measured once per call after one warm-up) is subtracted,
  -- floored at 0. Records:
  --   <p_name>-reads-median, -reads-max, -reads-min      ('session logical reads')
  --   <p_name>-cpu-cs-median, -cpu-cs-max                ('CPU used by this session')
  --   <p_name>-elapsed-cs-median, -elapsed-cs-max        (dbms_utility.get_time)
  -- The median of an even number of runs is the lower middle value (an
  -- observed run, never an average of two). p_sql must be a single SELECT or
  -- WITH query. LOB columns are fetched as locators, so a query that must read
  -- a document's bytes should select json_serialize(... returning blob), as S1
  -- does.
  PROCEDURE measure_repeat(p_name VARCHAR2, p_sql VARCHAR2, p_runs PLS_INTEGER DEFAULT 20);
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
  PROCEDURE define_all(p_cur INTEGER) IS
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
        WHEN d(i).col_type = 112       THEN dbms_sql.define_array(p_cur, i, v_cl, c_batch, 1);
        WHEN d(i).col_type IN (113, 119)
                                       THEN dbms_sql.define_array(p_cur, i, v_bl, c_batch, 1);
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

  PROCEDURE measure_repeat(p_name VARCHAR2, p_sql VARCHAR2, p_runs PLS_INTEGER DEFAULT 20) IS
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

    -- Meter overhead: snap then the same deltas with no work. One warm-up, then
    -- the measured one.
    FOR i IN 1 .. 2 LOOP
      snap;
      take(o_r, o_c, o_e);
    END LOOP;

    c := dbms_sql.open_cursor;
    BEGIN
      dbms_sql.parse(c, p_sql, dbms_sql.native);
      define_all(c);
      run_all(c);                       -- warm-up run, not measured
      reads.EXTEND(p_runs);
      cpus.EXTEND(p_runs);
      els.EXTEND(p_runs);
      FOR i IN 1 .. p_runs LOOP
        snap;
        run_all(c);
        take(r, cp, e);
        reads(i) := GREATEST(r  - o_r, 0);
        cpus(i)  := GREATEST(cp - o_c, 0);
        els(i)   := GREATEST(e  - o_e, 0);
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
  END measure_repeat;
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

-- Repeat helper: measure a trivial query; all 7 metric rows must exist with
-- non-negative values. The rows are removed afterwards.
BEGIN
  m08_meter.measure_repeat('m08-meter-selftest', 'select level n, rpad(''x'', 50, ''x'') s from dual connect by level <= 500');
END;
/

SELECT 'ASSERT:m08-meter-repeat-ready:' ||
       CASE WHEN COUNT(DISTINCT name) = 7 AND COUNT(*) = 7 AND MIN(value) >= 0 THEN 'PASS' ELSE 'FAIL' END
  FROM m08_metrics
 WHERE name IN ('m08-meter-selftest-reads-median', 'm08-meter-selftest-reads-max',
                'm08-meter-selftest-reads-min', 'm08-meter-selftest-cpu-cs-median',
                'm08-meter-selftest-cpu-cs-max', 'm08-meter-selftest-elapsed-cs-median',
                'm08-meter-selftest-elapsed-cs-max');

DELETE FROM m08_metrics WHERE name LIKE 'm08-meter-selftest-%';
