-- Module 08 measurement harness. Idempotent: safe to run any number of times.
-- m08_meter.snap records the session's current statistics; m08_meter.delta
-- returns how much one statistic grew since the last snap. Supported stats:
-- 'session logical reads', 'redo size', 'execute count'.
-- m08_meter.record stores a named value in the session-private GTT m08_metrics.

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
  PROCEDURE record(p_name VARCHAR2, p_value NUMBER);
END m08_meter;
/

CREATE OR REPLACE PACKAGE BODY m08_meter AS
  g_logical_reads NUMBER := 0;
  g_redo_size     NUMBER := 0;
  g_execute_count NUMBER := 0;

  FUNCTION cur(p_stat VARCHAR2) RETURN NUMBER IS
    v NUMBER;
  BEGIN
    SELECT ms.value INTO v
      FROM v$mystat ms JOIN v$statname sn ON sn.statistic# = ms.statistic#
     WHERE sn.name = p_stat;
    RETURN v;
  END cur;

  PROCEDURE snap IS
  BEGIN
    g_logical_reads := cur('session logical reads');
    g_redo_size     := cur('redo size');
    g_execute_count := cur('execute count');
  END snap;

  FUNCTION delta(p_stat VARCHAR2) RETURN NUMBER IS
  BEGIN
    CASE p_stat
      WHEN 'session logical reads' THEN RETURN cur(p_stat) - g_logical_reads;
      WHEN 'redo size'             THEN RETURN cur(p_stat) - g_redo_size;
      WHEN 'execute count'         THEN RETURN cur(p_stat) - g_execute_count;
      ELSE RAISE_APPLICATION_ERROR(-20801, 'm08_meter.delta: unsupported stat ' || p_stat);
    END CASE;
  END delta;

  PROCEDURE record(p_name VARCHAR2, p_value NUMBER) IS
  BEGIN
    INSERT INTO m08_metrics (name, value) VALUES (p_name, p_value);
  END record;
END m08_meter;
/

BEGIN
  m08_meter.snap;
END;
/

SELECT 'ASSERT:m08-meter-ready:' || CASE WHEN m08_meter.delta('session logical reads') >= 0 THEN 'PASS' ELSE 'FAIL' END FROM dual;
