-- NOTE: on first boot this always defers — gvenzl initdb scripts run BEFORE the
-- entrypoint installs ORDS, so ORDS_METADATA does not exist yet. The entrypoint
-- (docker/scripts/entrypoint.sh) re-runs this exact enable call via sqlplus right
-- after `ords install` completes. This file documents the call and covers the
-- volume-reuse case where ORDS is already installed.
-- ORDS_ADMIN (not ORDS) is required to enable a schema other than the invoker's.
-- EXECUTE IMMEDIATE so the missing ORDS_METADATA package is a catchable runtime
-- error, not an anonymous-block compile error (ORA-06550) the handler can't see.
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  EXECUTE IMMEDIATE q'[
    BEGIN
      ORDS_METADATA.ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => TRUE, p_schema => 'LAB_USER',
                         p_url_mapping_type => 'BASE_PATH',
                         p_url_mapping_pattern => 'lab', p_auto_rest_auth => FALSE);
      COMMIT;
    END;]';
EXCEPTION
  WHEN OTHERS THEN
    -- ORDS may not be installed yet on first init; will be configured later by entrypoint.
    DBMS_OUTPUT.PUT_LINE('ORDS enable deferred: ' || SQLERRM);
END;
/
