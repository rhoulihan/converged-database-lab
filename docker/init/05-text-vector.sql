ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Oracle Text index on ticket bodies: keyword search in the same engine/transaction.
-- SYNC (ON COMMIT): the index syncs inside the committing transaction, so a
-- committed row is immediately findable via CONTAINS — transactional
-- read-after-write search (module 02 proves this). The 26ai Free default for
-- CREATE SEARCH INDEX is MAINTENANCE AUTO with deferred background sync
-- (ctx_user_indexes showed IDX_SYNC_TYPE = MANUAL), under which a probe row was
-- NOT visible to CONTAINS immediately after COMMIT.
CREATE SEARCH INDEX ticket_text_idx ON support_tickets (body)
  PARAMETERS ('SYNC (ON COMMIT)');

-- Vector index. IVF (NEIGHBOR PARTITIONS) — works within Free-tier memory without
-- carving VECTOR_MEMORY_SIZE; module 03 demonstrates HNSW + memory sizing.
CREATE VECTOR INDEX ticket_vec_idx ON support_tickets (embedding)
  ORGANIZATION NEIGHBOR PARTITIONS
  DISTANCE COSINE;
