-- Module 08 teardown: drop the measurement harness and check that the module
-- left nothing behind, so the next validator run starts clean.
-- Each scenario already drops its own objects; this script removes the
-- harness from 00-meter.sql and then checks every name the module uses.

-- m08_metrics is a session temporary table that keeps its rows across
-- commits. It cannot be dropped while this session still holds rows in it,
-- so empty it first. TRUNCATE also releases the session's hold on it.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM user_tables WHERE table_name = 'M08_METRICS';
  IF n > 0 THEN
    EXECUTE IMMEDIATE 'TRUNCATE TABLE m08_metrics';
  END IF;
END;
/

drop package if exists m08_meter;
drop table if exists m08_metrics purge;

-- Every prefix and name this module creates, matched case-insensitively.
-- The prefixes are listed one by one (not a broad M08%) so the check can
-- never match an object that belongs to another module.
select 'ASSERT:s08-module-clean:' ||
       case when (select count(*) from user_objects
                   where upper(object_name) like 'M08\_%'   escape '\'
                      or upper(object_name) like 'M08A\_%'  escape '\'
                      or upper(object_name) like 'M08B\_%'  escape '\'
                      or upper(object_name) like 'M08B3\_%' escape '\'
                      or upper(object_name) like 'M08C1\_%' escape '\'
                      or upper(object_name) like 'M08C2\_%' escape '\'
                      or upper(object_name) like 'M08D\_%'  escape '\'
                      or upper(object_name) like 'MLOG$\_M08D\_%' escape '\'
                      or upper(object_name) like 'RUPD$\_M08D\_%' escape '\'
                      or upper(object_name) like 'I\_MLOG$\_M08D\_%' escape '\'
                      or upper(object_name) like 'M08S2\_%' escape '\'
                      or upper(object_name) like 'M08S4\_%' escape '\'
                      or upper(object_name) like 'M08S5\_%' escape '\'
                      or upper(object_name) in ('SALES_ORDERS', 'SALES_ORDERS_T',
                                                'SALES_ORDER_LINES', 'SALES_ORDERS_V0',
                                                'PROBE_RUNS')
                      or upper(object_name) like 'SALES\_ORDER\_LINES\_%' escape '\') = 0
            then 'PASS' else 'FAIL' end
  from dual;
