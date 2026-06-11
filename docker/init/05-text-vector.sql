ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Oracle Text index on ticket bodies: keyword search in the same engine/transaction.
CREATE SEARCH INDEX ticket_text_idx ON support_tickets (body);

-- Vector index. IVF (NEIGHBOR PARTITIONS) — works within Free-tier memory without
-- carving VECTOR_MEMORY_SIZE; module 03 demonstrates HNSW + memory sizing.
CREATE VECTOR INDEX ticket_vec_idx ON support_tickets (embedding)
  ORGANIZATION NEIGHBOR PARTITIONS
  DISTANCE COSINE;
