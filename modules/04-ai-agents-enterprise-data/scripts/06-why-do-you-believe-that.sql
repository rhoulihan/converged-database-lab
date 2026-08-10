-- Module 04 proof 6: EXPLAINABILITY falls out of the model. Because the canonical
-- memory keeps the relationships between source -> memory -> related memory, the
-- agent can answer "Why do you believe that?" and "What else is related?" by
-- traversing the SAME store it recalled from — no separate lineage system. This is
-- Jeremy Daly's third premise: provenance is not bolted on; it is the model.
-- Requires proofs 4/5 (shared 'sess-atlas' fixture). This proof also TEARS DOWN the
-- shared fixture (proofs 4-6 share one canonical memory; cleanup is explicit and
-- asserted, since DDL and the committed seed are not reachable by the harness
-- rollback).

SELECT /* "WHY do you believe Atlas will use Oracle?" — trace the decision (M2)
   back through the property graph to the source it was derived from. One graph hop
   over the same canonical rows returns the originating conversation (S2). */
       'ASSERT:provenance-trace-to-source:' ||
       CASE WHEN (SELECT ref FROM GRAPH_TABLE (mem_graph
                    MATCH (m IS memory) -[e IS derived_from]-> (s IS source)
                    WHERE m.memory_id = 'M2'
                    COLUMNS (s.ref AS ref))) = 'Atlas planning meeting'
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* "What ELSE is related to this decision?" — graph traversal over the same
   canonical memory returns the related risk (M5), without a separate graph store. */
       'ASSERT:related-memory-traversal:' ||
       CASE WHEN (SELECT to_mem FROM GRAPH_TABLE (mem_graph
                    MATCH (m IS memory) -[e IS relates_to]-> (r IS memory)
                    WHERE m.memory_id = 'M2'
                    COLUMNS (r.memory_id AS to_mem))) = 'M5'
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the full explainability chain is intact end to end: from the source,
   through the memory it grounded, to the related memory — source -> memory ->
   related memory in one traversal over one canonical store */
       'ASSERT:explainability-chain-intact:' ||
       CASE WHEN EXISTS (
              SELECT 1 FROM GRAPH_TABLE (mem_graph
                MATCH (s IS source) <-[d IS derived_from]- (m IS memory) -[r IS relates_to]-> (rel IS memory)
                WHERE m.memory_id = 'M2'
                COLUMNS (s.source_id AS src, rel.memory_id AS related)))
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* TEARDOWN of the shared proofs-4-6 fixture: drop the duality view, the
   property graph and every module-local table; the seed was committed, so this is
   explicit (autocommitting DDL). Leaves the domain exactly as proofs 1-3 found it. */
BEGIN
  EXECUTE IMMEDIATE 'DROP VIEW mem_context_dv';
  EXECUTE IMMEDIATE 'DROP PROPERTY GRAPH mem_graph';
  EXECUTE IMMEDIATE 'DROP TABLE mem_relate PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE mem_provenance PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE mem_memory PURGE';
  EXECUTE IMMEDIATE 'DROP TABLE mem_source PURGE';
END;
/

SELECT /* nothing module-local survives — the shared-fixture proofs left the schema
          exactly as they found it */
       'ASSERT:projection-teardown-clean:' ||
       CASE WHEN (SELECT COUNT(*) FROM user_objects
                  WHERE object_name IN ('MEM_SOURCE','MEM_MEMORY','MEM_PROVENANCE','MEM_RELATE','MEM_GRAPH','MEM_CONTEXT_DV')) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
