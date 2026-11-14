-- Lab schema owner. Runs as SYS in FREEPDB1 (gvenzl initdb convention).
-- The gvenzl image already creates APP_USER (=LAB_USER per compose), so user
-- creation is wrapped idempotently; the grants always run.
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  BEGIN
    EXECUTE IMMEDIATE 'CREATE USER lab_user IDENTIFIED BY "LabUser2026" QUOTA UNLIMITED ON users';
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE != -1920 THEN RAISE; END IF;  -- ORA-01920: user exists (created by image)
  END;
  EXECUTE IMMEDIATE 'ALTER USER lab_user QUOTA UNLIMITED ON users';
  EXECUTE IMMEDIATE 'GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE PROCEDURE,
    CREATE SEQUENCE, CREATE MATERIALIZED VIEW, CREATE PROPERTY GRAPH, SODA_APP TO lab_user';
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON CTXSYS.CTX_DDL TO lab_user';
  -- Module 08 measures session statistics and checks plans (dbms_xplan.display_cursor).
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$MYSTAT TO lab_user';
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$STATNAME TO lab_user';
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$SQL TO lab_user';
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$SQL_PLAN TO lab_user';
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$SESSION TO lab_user';
  -- Module 08 S3 (B): executed-plan row-source statistics (dbms_xplan
  -- 'ALLSTATS LAST') and purging one statement's cursor between measurements.
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$SQL_PLAN_STATISTICS_ALL TO lab_user';
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$SQL_PLAN_STATISTICS TO lab_user';
  EXECUTE IMMEDIATE 'GRANT EXECUTE ON SYS.DBMS_SHARED_POOL TO lab_user';
  -- Module 08 writes (D): undo records of the session's open transaction
  -- (how many rows a SELECT ... FOR UPDATE locked).
  EXECUTE IMMEDIATE 'GRANT SELECT ON SYS.V_$TRANSACTION TO lab_user';
END;
/
