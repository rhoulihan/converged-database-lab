DECLARE /* Module 04 proof 3: every agent query lands in ONE attributed audit
   stream. When an agent acts on enterprise data, "what did it read, as whom,
   when?" is a compliance question, not a curiosity. In a converged engine every
   agent-issued query — SQL, document API, or vector retrieval — is captured by
   unified auditing (the default and only audit mode in 26ai), attributed to the
   acting identity, in one queryable, tamper-resistant trail (AUD$UNIFIED in
   AUDSYS is insert-only).

   Here we create an AUDIT POLICY on support_tickets, run the agent's vector
   retrieval under TWO acting identities (tagged via DBMS_SESSION.SET_IDENTIFIER,
   which lands in UNIFIED_AUDIT_TRAIL.CLIENT_IDENTIFIER), then query the trail and
   assert BOTH retrievals were captured with their identity, the acting DB user,
   the object, and the full SQL text. The contrast (leaf-4 §6): assembling an
   audit story across a polyglot agent stack means correlating logs from three
   systems with three identity models; here it is one SELECT over one trail.

   DETERMINISM: audit history rows PERSIST (the trail is append-only and survives
   the validator's rollback — auditing is non-transactional by design). So every
   assertion is scoped to a PER-RUN NONCE (a SYS_GUID stamped into an application
   context once per run and prefixed onto both CLIENT_IDENTIFIERs); re-runs never
   collide with prior runs' rows. 26ai Free writes the trail in IMMEDIATE mode, so
   rows are visible without DBMS_AUDIT_MGMT.FLUSH_UNIFIED_AUDIT_TRAIL (the flush
   procedure is not granted to the least-privileged lab_user and is not needed).

   ACCESS NOTE: a least-privileged app user can neither CREATE an audit policy nor
   read UNIFIED_AUDIT_TRAIL by default — both are privileged. Module 04 grants
   lab_user AUDIT SYSTEM (create/enable a policy on its own tables) and AUDIT_VIEWER
   (read-only on the trail) in docker/init/10-agent-audit-grants.sql on this branch.
   That "who can see the audit trail is itself a separately-granted role" IS the
   governance story, not a workaround.

   DDL / TEARDOWN EXCEPTION: this proof creates an application context + setter
   (DDL) and an audit policy (DDL/autocommitting), and SET_IDENTIFIER is a session
   side effect — none reversible by the validator's rollback. Teardown is explicit
   and asserted: identifier cleared, policy NOAUDIT'd + dropped, context + setter
   dropped. This first block removes any leftovers from an interrupted prior run. */
BEGIN
  BEGIN DBMS_SESSION.SET_IDENTIFIER(NULL);                       EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'NOAUDIT POLICY m04_agent_audit';      EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP AUDIT POLICY m04_agent_audit';   EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP CONTEXT m04_audit_ctx';          EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PROCEDURE m04_set_audit_run';    EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

CREATE CONTEXT m04_audit_ctx USING m04_set_audit_run;

CREATE PROCEDURE m04_set_audit_run(p IN VARCHAR2) IS
BEGIN /* hold this run's unique nonce so the SET_IDENTIFIER tags and the trail
   assertions share one per-run key, making re-runs deterministic */
  DBMS_SESSION.SET_CONTEXT('M04_AUDIT_CTX','NONCE', p);
END;
/

BEGIN /* stamp a fresh per-run nonce */
  m04_set_audit_run('m04run_' || RAWTOHEX(SYS_GUID()));
END;
/

CREATE AUDIT POLICY m04_agent_audit ACTIONS SELECT ON lab_user.support_tickets;

AUDIT POLICY m04_agent_audit;

BEGIN /* the agent runs its semantic retrieval AS acting user "alice": tag the
   session identity, then issue the vector query. Both land in the audit trail. */
  DBMS_SESSION.SET_IDENTIFIER(SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_alice');
  FOR r IN (
    SELECT ticket_id FROM support_tickets
    ORDER BY VECTOR_DISTANCE(body_vec,
               VECTOR_EMBEDDING(MINILM_L12 USING 'refund for a damaged package' AS data),
               COSINE)
    FETCH APPROX FIRST 5 ROWS ONLY WITH TARGET ACCURACY 90
  ) LOOP NULL; END LOOP;
END;
/

BEGIN /* the SAME agent retrieval AS acting user "bob", a different identity and a
   different probe — a second attributed query in the same trail */
  DBMS_SESSION.SET_IDENTIFIER(SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_bob');
  FOR r IN (
    SELECT ticket_id FROM support_tickets
    ORDER BY VECTOR_DISTANCE(body_vec,
               VECTOR_EMBEDDING(MINILM_L12 USING 'cannot sign in after password reset' AS data),
               COSINE)
    FETCH APPROX FIRST 5 ROWS ONLY WITH TARGET ACCURACY 90
  ) LOOP NULL; END LOOP;
  DBMS_SESSION.SET_IDENTIFIER(NULL);
END;
/

SELECT /* BOTH acting identities were captured in the one trail — two distinct
          CLIENT_IDENTIFIER values for this run's nonce */
       'ASSERT:both-identities-audited:' ||
       CASE WHEN (SELECT COUNT(DISTINCT client_identifier) FROM unified_audit_trail
                  WHERE client_identifier LIKE SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_%'
                    AND object_name='SUPPORT_TICKETS') = 2
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* each captured query is attributed to the acting DB user and the object,
          with action SELECT — full who/what attribution, both retrievals */
       'ASSERT:audit-attributes-user-and-object:' ||
       CASE WHEN (SELECT COUNT(*) FROM unified_audit_trail
                  WHERE client_identifier LIKE SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_%'
                    AND dbusername='LAB_USER'
                    AND action_name='SELECT'
                    AND object_name='SUPPORT_TICKETS') = 2
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the actual agent SQL is captured verbatim — both rows show the
          VECTOR_DISTANCE retrieval text (SQL_TEXT is a CLOB, matched in-SQL via
          DBMS_LOB.INSTR so the assertion never ships the LOB to the client) */
       'ASSERT:audit-captures-sql-text:' ||
       CASE WHEN (SELECT COUNT(*) FROM unified_audit_trail
                  WHERE client_identifier LIKE SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_%'
                    AND object_name='SUPPORT_TICKETS'
                    AND DBMS_LOB.INSTR(sql_text, 'VECTOR_DISTANCE') > 0) = 2
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the two identities are distinguishable in the trail — alice's query and
          bob's query are separately attributed (one row each for this run) */
       'ASSERT:identities-distinguished:' ||
       CASE WHEN (SELECT COUNT(*) FROM unified_audit_trail
                  WHERE client_identifier = SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_alice') = 1
             AND (SELECT COUNT(*) FROM unified_audit_trail
                  WHERE client_identifier = SYS_CONTEXT('M04_AUDIT_CTX','NONCE') || '_bob') = 1
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* TEARDOWN: clear the identifier, disable + drop the policy, drop the
   context + setter — all autocommitting/session DDL, so explicit. */
BEGIN
  DBMS_SESSION.SET_IDENTIFIER(NULL);
  EXECUTE IMMEDIATE 'NOAUDIT POLICY m04_agent_audit';
  EXECUTE IMMEDIATE 'DROP AUDIT POLICY m04_agent_audit';
  EXECUTE IMMEDIATE 'DROP CONTEXT m04_audit_ctx';
  EXECUTE IMMEDIATE 'DROP PROCEDURE m04_set_audit_run';
END;
/

SELECT /* the audit policy is gone (AUDIT_UNIFIED_POLICIES, visible via
          AUDIT_VIEWER) and the module-local context-setter is dropped —
          support_tickets is no longer audited and the domain is unchanged. The
          append-only trail rows we wrote remain by design (auditing is
          non-transactional); they are scoped to this run's nonce and harm nothing. */
       'ASSERT:teardown-clean:' ||
       CASE WHEN (SELECT COUNT(*) FROM audit_unified_policies WHERE policy_name='M04_AGENT_AUDIT') = 0
             AND (SELECT COUNT(*) FROM user_objects WHERE object_name='M04_SET_AUDIT_RUN') = 0
             AND (SELECT COUNT(*) FROM support_tickets) = 300
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
