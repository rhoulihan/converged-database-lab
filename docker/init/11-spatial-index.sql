ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Spatial setup for the STORES.LOCATION SDO_GEOMETRY column (article-5 / module 05).
--
-- The shared domain (02-schema.sql / 06-seed.sql) already declares stores.location
-- as SDO_GEOMETRY and seeds 5 Texas store points (SRID 4326, WGS84 lon/lat) plus a
-- null-location 'Online' store. SDO_WITHIN_DISTANCE / SDO_NN as WHERE-clause
-- operators require TWO things this file adds, in order:
--   (1) a USER_SDO_GEOM_METADATA row describing the column's dimensions + SRID, and
--   (2) an R-tree spatial index (geodetic SRID 4326 is forced to R-tree).
-- Without both, the spatial operators raise (ORA-13226 "interface not supported
-- without a spatial index" / ORA-13203 "failed to read USER_SDO_GEOM_METADATA").
--
-- Tolerance for geodetic (4326) data is in METERS; 0.5 is a sane value (the seed
-- coordinates are 4 decimal places ~ 11 m). The 'Online' store's NULL location is
-- fine: the R-tree index simply skips null geometries.
--
-- Runs after 01-08 on first boot (gvenzl initdb, lexical order). Idempotent: the
-- metadata INSERT is guarded against a duplicate row, and the index is dropped
-- (if present) before being (re)created, so a container recreated over a
-- persistent volume re-runs cleanly.
--
-- IMAGE REQUIREMENT: this needs Oracle Spatial (MDSYS), which is present in the
-- FULL gvenzl/oracle-free:23.26.0-faststart image used by docker/Dockerfile.oracle.
-- The slim / slim-faststart variants UNINSTALL Oracle Spatial (and Oracle Text),
-- so this file — and the module 05 spatial proofs — silently break on slim.

DECLARE
  v_exists NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_exists
    FROM user_sdo_geom_metadata
   WHERE table_name = 'STORES' AND column_name = 'LOCATION';
  IF v_exists = 0 THEN
    INSERT INTO user_sdo_geom_metadata (table_name, column_name, diminfo, srid)
    VALUES ('STORES', 'LOCATION',
            SDO_DIM_ARRAY(
              SDO_DIM_ELEMENT('LONG', -180, 180, 0.5),
              SDO_DIM_ELEMENT('LAT',   -90,  90, 0.5)),
            4326);
  END IF;
END;
/

COMMIT;

DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX stores_geom_idx';
EXCEPTION WHEN OTHERS THEN NULL; /* absent — first run */
END;
/

CREATE INDEX stores_geom_idx ON stores (location)
  INDEXTYPE IS MDSYS.SPATIAL_INDEX_V2;
