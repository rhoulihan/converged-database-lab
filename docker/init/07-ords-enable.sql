ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  ORDS.ENABLE_SCHEMA(p_enabled => TRUE, p_schema => 'LAB_USER',
                     p_url_mapping_type => 'BASE_PATH',
                     p_url_mapping_pattern => 'lab', p_auto_rest_auth => FALSE);
  COMMIT;
EXCEPTION
  WHEN OTHERS THEN
    -- ORDS may not be installed yet on first init; will be configured later by entrypoint.
    DBMS_OUTPUT.PUT_LINE('ORDS enable deferred: ' || SQLERRM);
END;
/
