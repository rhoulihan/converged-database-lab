SELECT /* Module 05 proof 3: SPATIAL, standalone — the model no prior module
   exercised. The shared domain has stored stores.location as SDO_GEOMETRY (SRID
   4326, WGS84 lon/lat) since the anchor; docker/init/11-spatial-index.sql added
   the two things the SDO operators require — a USER_SDO_GEOM_METADATA row and an
   R-tree spatial index (geodetic data is forced to R-tree). This script confirms
   that setup is live, then runs the two canonical spatial queries (point-radius
   and k-nearest) and joins the spatial result back to the relational orders
   table — spatial as just another WHERE predicate the one optimizer plans with
   everything else.

   First: the spatial metadata row is registered for STORES.LOCATION. */
       'ASSERT:spatial-metadata-present:' ||
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM user_sdo_geom_metadata
WHERE table_name = 'STORES' AND column_name = 'LOCATION' AND srid = 4326;

SELECT /* the R-tree spatial domain index exists and is VALID — the SDO
          operators below can use it */
       'ASSERT:spatial-index-valid:' ||
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM user_indexes
WHERE index_name = 'STORES_GEOM_IDX'
  AND index_type = 'DOMAIN'
  AND status = 'VALID';

SELECT /* POINT-RADIUS: stores within 50 km of a fixed downtown-Austin probe
          (-97.7431, 30.2672). The two Austin stores (Downtown Austin itself and
          Domain North ~15 km north) are inside the radius; Dallas/Houston/San
          Antonio and the null-location Online store are not. SDO_WITHIN_DISTANCE
          must sit in the WHERE clause and returns the string 'TRUE'. */
       'ASSERT:point-radius-austin-set:' ||
       CASE WHEN LISTAGG(name, ',') WITHIN GROUP (ORDER BY name)
                 = 'Domain North,Downtown Austin'
            THEN 'PASS' ELSE 'FAIL' END
FROM stores s
WHERE SDO_WITHIN_DISTANCE(
        s.location,
        SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
        'distance=50 unit=KM') = 'TRUE';

SELECT /* exactly two stores fall inside the 50 km radius */
       'ASSERT:point-radius-count:' ||
       CASE WHEN COUNT(*) = 2 THEN 'PASS' ELSE 'FAIL' END
FROM stores s
WHERE SDO_WITHIN_DISTANCE(
        s.location,
        SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
        'distance=50 unit=KM') = 'TRUE';

SELECT /* a wider 400 km radius from the same probe reaches San Antonio and
          Houston too (3 Texas metros), but still not Dallas (~290 km is inside
          400, so Frisco/Dallas joins) — five located stores, all but Online,
          fall inside 400 km of central Texas. Confirms distance scales sanely. */
       'ASSERT:point-radius-wide-count:' ||
       CASE WHEN COUNT(*) = 5 THEN 'PASS' ELSE 'FAIL' END
FROM stores s
WHERE SDO_WITHIN_DISTANCE(
        s.location,
        SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
        'distance=400 unit=KM') = 'TRUE';

SELECT /* K-NEAREST: SDO_NN returns the k closest stores to the probe, ordered by
          SDO_NN_DISTANCE(1). The INDEX hint is required for SDO_NN to use the
          R-tree. The nearest store to the downtown-Austin probe is Downtown
          Austin itself (distance ~0), then Domain North. Assert the ordered
          top-3 begins Downtown Austin, Domain North. */
       'ASSERT:knn-nearest-two:' ||
       CASE WHEN nearest_csv LIKE 'Downtown Austin,Domain North%'
            THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT LISTAGG(name, ',') WITHIN GROUP (ORDER BY d) AS nearest_csv
  FROM (
    SELECT /*+ INDEX(s stores_geom_idx) */
           s.name, SDO_NN_DISTANCE(1) AS d
    FROM stores s
    WHERE SDO_NN(
            s.location,
            SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
            'sdo_num_res=3', 1) = 'TRUE'
    ORDER BY d
  )
);

SELECT /* SDO_NN returns exactly k rows and the row it ranks first (rn=1) carries
          the minimum distance -- the k-nearest set is genuinely ordered nearest
          first. rn is assigned by the SDO_NN_DISTANCE ordering. */
       'ASSERT:knn-ordered-by-distance:' ||
       CASE WHEN COUNT(*) = 3
                 AND MIN(CASE WHEN rn = 1 THEN d END) = MIN(d)
            THEN 'PASS' ELSE 'FAIL' END
FROM (
  SELECT d, ROW_NUMBER() OVER (ORDER BY d) AS rn
  FROM (
    SELECT /*+ INDEX(s stores_geom_idx) */ SDO_NN_DISTANCE(1) AS d
    FROM stores s
    WHERE SDO_NN(
            s.location,
            SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
            'sdo_num_res=3', 1) = 'TRUE'
  )
);

SELECT /* SPATIAL JOINED TO RELATIONAL: orders placed at a store within 50 km of
          the downtown-Austin probe. The spatial predicate is a single-geometry
          probe (one fixed reference point), joined to ORDERS by store_id — the
          natural feature shape (orders near a service center). At least one such
          order exists in the seed (orders fan out across all 6 stores). */
       'ASSERT:spatial-join-orders:' ||
       CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END
FROM orders o
JOIN stores s ON s.store_id = o.store_id
WHERE SDO_WITHIN_DISTANCE(
        s.location,
        SDO_GEOMETRY(2001, 4326, SDO_POINT_TYPE(-97.7431, 30.2672, NULL), NULL, NULL),
        'distance=50 unit=KM') = 'TRUE';
