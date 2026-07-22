ALTER SESSION SET CONTAINER = FREEPDB1;
ALTER SESSION SET CURRENT_SCHEMA = lab_user;

-- Hybrid Vector Index on the ticket body: one domain index unifying Oracle Text
-- (keyword) and a vector index (semantic) over the same column, queried via
-- DBMS_HYBRID_VECTOR.SEARCH with RRF/score fusion (module 03, 04-hybrid-search.sql).
-- Leaf-3-specific: the foundational model + body_vec + IVF live in 08 (on main);
-- this HVI is the article-3 hybrid-search showcase and stays on this branch.
--
-- COLLISION NOTE: a CONTEXT/SEARCH text index and the HVI's internal text
-- component are the SAME indextype, so two cannot sit on the same column
-- (ORA-29879). The shared 05-text-vector.sql creates ticket_text_idx (a SEARCH
-- index) on body; this module needs the richer body text for a meaningful hybrid
-- proof, so we DROP ticket_text_idx here and let the HVI own body's text search.
-- The HVI exposes the same CONTAINS(body, ...) capability, so keyword-only search
-- still works. (On the eventual merge with the module-02 branch, whose
-- read-after-write SEARCH proof uses ticket_text_idx, that proof moves to the HVI
-- or to the subject column — a merge-time decision.)
--
-- VECTOR_IDXTYPE IVF keeps the HVI's vector component off the Vector Pool
-- (Free-safe); MEMORY 256M caps the Oracle Text build memory modestly. Builds in
-- ~6s on the Free container.
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX tickets_hvi';
EXCEPTION WHEN OTHERS THEN NULL; /* absent — first run */
END;
/
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP INDEX ticket_text_idx';
EXCEPTION WHEN OTHERS THEN NULL; /* HVI takes over body text search */
END;
/
CREATE HYBRID VECTOR INDEX tickets_hvi ON support_tickets(body)
  PARAMETERS('MODEL MINILM_L12 VECTOR_IDXTYPE IVF MEMORY 256M');
