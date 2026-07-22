DECLARE /* Module 03 proof 3: the SAME vector query, run by two tenants, returns
   DIFFERENT governed rows — permission-aware retrieval enforced by the engine,
   query unchanged. This is the cleanest expression of the series' "one
   governance domain" guarantee: the row-level policy that governs SQL, the
   document API, and graph traversal also governs vector retrieval, because it is
   one engine over one set of rows.

   The documented contrast: permission-aware RAG is a named production problem —
   Pinecone's OWN access-control guide concedes the store does not enforce
   permissions and must integrate an external authorizer (e.g. SpiceDB), copy ids
   into metadata, and keep ACLs in sync with the source system. The permission
   model lives OUTSIDE the retrieval engine, a consistency gap by construction.
   Here it is a Virtual Private Database (DBMS_RLS) policy — available in 26ai
   Free (Licensing guide Table 1-11, Free column = Y) — that ANDs a predicate
   into the same FETCH APPROX query the app already issues.

   MECHANISM (honest): true OS-level multi-user auth is awkward to script as
   LAB_USER, so we use a VPD policy whose predicate keys off an APPLICATION
   CONTEXT, and toggle that context between two tenant identities ('A','B')
   within one session via DBMS_SESSION.SET_CONTEXT. The query is byte-for-byte
   identical across both; only the governed identity differs — which is exactly
   the point. Tenant A owns even-numbered customers' tickets, tenant B owns the
   odd-numbered ones; the sets are disjoint and partition all 10,000 tickets.

   DDL / TEARDOWN EXCEPTION: this proof creates a context, a context-setter
   procedure, a policy-predicate function, and a DBMS_RLS policy — all DDL, all
   autocommitting, none reversible by the validator's rollback. Cleanup is
   therefore explicit and asserted: the policy, function, procedure, context, and
   the helper table are all dropped before the script ends. This first block
   removes any leftovers from an interrupted run. */
BEGIN
  BEGIN DBMS_RLS.DROP_POLICY('LAB_USER','SUPPORT_TICKETS','M03_TENANT_POL'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP FUNCTION m03_tenant_pred';  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PROCEDURE m03_set_tenant';  EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP CONTEXT m03_tenant_ctx';    EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE m03_perm_proof PURGE';EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

CREATE CONTEXT m03_tenant_ctx USING m03_set_tenant;

CREATE PROCEDURE m03_set_tenant(p_tenant IN VARCHAR2) IS
BEGIN
  DBMS_SESSION.SET_CONTEXT('M03_TENANT_CTX','TENANT', p_tenant);
END;
/

CREATE FUNCTION m03_tenant_pred(p_schema VARCHAR2, p_object VARCHAR2) RETURN VARCHAR2 IS
BEGIN /* the row-level predicate: a ticket is visible only if its customer's id
   parity matches the current tenant (A=even, B=odd). Folded into every SELECT on
   support_tickets, including the vector ORDER BY ... FETCH APPROX query. */
  RETURN q'[customer_id IN (SELECT customer_id FROM customers
              WHERE MOD(customer_id,2) =
                    CASE WHEN SYS_CONTEXT('M03_TENANT_CTX','TENANT')='A' THEN 0 ELSE 1 END)]';
END;
/

BEGIN /* attach the VPD policy to support_tickets for SELECT — the engine now
   enforces the predicate on every read, no matter how the rows are retrieved */
  DBMS_RLS.ADD_POLICY(
    object_schema   => 'LAB_USER',
    object_name     => 'SUPPORT_TICKETS',
    policy_name     => 'M03_TENANT_POL',
    function_schema => 'LAB_USER',
    policy_function => 'M03_TENANT_PRED',
    statement_types => 'SELECT');
END;
/

CREATE TABLE m03_perm_proof (tenant VARCHAR2(1), ticket_id NUMBER, PRIMARY KEY (tenant, ticket_id));

DECLARE /* run the IDENTICAL approximate vector query as tenant A, then tenant B
   and capture each governed top-10 into the helper table. The only thing that
   changes between the two runs is the application context — the SQL text is the
   same. */
  PROCEDURE capture(p_tenant VARCHAR2) IS
  BEGIN
    m03_set_tenant(p_tenant);
    INSERT INTO m03_perm_proof (tenant, ticket_id)
    SELECT p_tenant, ticket_id FROM (
      SELECT ticket_id
      FROM support_tickets
      ORDER BY VECTOR_DISTANCE(body_vec,
                 VECTOR_EMBEDDING(MINILM_L12 USING 'refund for a damaged package' AS data),
                 COSINE)
      FETCH APPROX FIRST 10 ROWS ONLY WITH TARGET ACCURACY 90);
  END;
BEGIN
  capture('A');
  capture('B');
  COMMIT;
END;
/

SELECT /* both tenants got a non-empty governed result set from the same query */
       'ASSERT:both-tenants-nonempty:' ||
       CASE WHEN (SELECT COUNT(*) FROM m03_perm_proof WHERE tenant='A') > 0
             AND (SELECT COUNT(*) FROM m03_perm_proof WHERE tenant='B') > 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the two result sets are DISJOINT — no ticket visible to both tenants,
          unauthorized rows never entered the other tenant top-k */
       'ASSERT:results-disjoint:' ||
       CASE WHEN NOT EXISTS (
              SELECT ticket_id FROM m03_perm_proof WHERE tenant='A'
              INTERSECT
              SELECT ticket_id FROM m03_perm_proof WHERE tenant='B')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* tenant A rows really are even-customer tickets and tenant B rows really
          are odd-customer tickets — the governance predicate, not chance, split them */
       'ASSERT:governed-by-policy:' ||
       CASE WHEN (SELECT COUNT(*) FROM m03_perm_proof p JOIN support_tickets t ON t.ticket_id=p.ticket_id
                  WHERE p.tenant='A' AND MOD(t.customer_id,2) <> 0) = 0
             AND (SELECT COUNT(*) FROM m03_perm_proof p JOIN support_tickets t ON t.ticket_id=p.ticket_id
                  WHERE p.tenant='B' AND MOD(t.customer_id,2) <> 1) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* teardown: drop policy, predicate function, setter, context, helper
   table — all of it autocommitted DDL, so it must be explicit. The rollback the
   validator runs afterward has nothing of ours left to undo. */
BEGIN
  DBMS_RLS.DROP_POLICY('LAB_USER','SUPPORT_TICKETS','M03_TENANT_POL');
  EXECUTE IMMEDIATE 'DROP FUNCTION m03_tenant_pred';
  EXECUTE IMMEDIATE 'DROP PROCEDURE m03_set_tenant';
  EXECUTE IMMEDIATE 'DROP CONTEXT m03_tenant_ctx';
  EXECUTE IMMEDIATE 'DROP TABLE m03_perm_proof PURGE';
END;
/

SELECT /* nothing module-local survives: no policy, no predicate function, no
          setter procedure, no helper table — and support_tickets is unrestricted
          again (the context namespace, dropped above, is inert without its
          predicate function and is not visible in any lab_user dictionary view) */
       'ASSERT:teardown-clean:' ||
       CASE WHEN (SELECT COUNT(*) FROM user_policies WHERE policy_name='M03_TENANT_POL') = 0
             AND (SELECT COUNT(*) FROM user_objects
                  WHERE object_name IN ('M03_TENANT_PRED','M03_SET_TENANT','M03_PERM_PROOF')) = 0
             AND (SELECT COUNT(*) FROM support_tickets) = 10000
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
