DECLARE /* Module 04 proof 2 (the thesis proof): the agent queries AS the acting
   user, not a privileged service account. The SAME agent semantic-retrieval SQL,
   run under two acting identities, returns DISJOINT governed result sets —
   enforced by the engine on every read, regardless of how the agent phrased the
   query. This is OWASP LLM06's mitigation verbatim — "execute actions on behalf
   of a user in the context of that specific user, with the minimum privileges
   necessary" and "implement authorization in downstream systems rather than
   relying on an LLM" — realized at the data layer, not in the prompt.

   The documented contrast (leaf-4 §4): a database MCP server "is a simple proxy
   ... there is no deep introspection" (Pavlo, Jan 2026), and the MCP spec itself
   states it "cannot enforce these security principles at the protocol level" —
   implementors must. An agent that connects through one shared, over-privileged
   service account inherits that account's reach; a successful prompt injection
   then acts with the whole account's permissions. Putting the permission check
   in the engine shrinks the blast radius to the acting user's own rows, on every
   read, no matter what SQL the model emits.

   Oracle Deep Data Security (GA in 26ai) states the principle directly: it
   "eliminates the need for highly privileged, shared database connections,"
   propagating end-user identity via OAuth 2.0 on-behalf-of tokens enforced by
   declarative DATA GRANT policies. The full OAuth2/OBO token path needs OCI IAM
   and is described-and-cited in the article, NOT run here. The RUNNABLE proof
   uses Virtual Private Database (DBMS_RLS) — included in 26ai Free (Licensing
   guide Table 1-11, Free column = Y) — which ANDs the acting-user predicate into
   the same VECTOR_DISTANCE FETCH APPROX query the agent already issues.

   MECHANISM (honest): scripting two real OS-authenticated end users as LAB_USER
   is awkward, so we model the acting user with an APPLICATION CONTEXT and toggle
   it between two identities ('alice','bob') within one session via
   DBMS_SESSION.SET_CONTEXT — exactly the SYS_CONTEXT('..','USER_IDENTITY')
   pattern Oracle's managed MCP server uses for VPD. The retrieval SQL is
   byte-for-byte identical across both identities; only the governed acting user
   differs — which is the whole point. Acting user 'alice' is scoped to
   even-customer tickets, 'bob' to odd-customer tickets; the two sets partition
   all 300 tickets and are disjoint.

   m04_-PREFIXED OBJECTS: distinct from module 03's m03_ names so the two modules
   never collide if both run.

   DDL / TEARDOWN EXCEPTION: this proof creates a context, a context-setter
   procedure, a policy-predicate function, a DBMS_RLS policy, and a capture
   table — all DDL, all autocommitting, none reversible by the validator's
   rollback. Cleanup is therefore explicit and asserted: every object is dropped
   before the script ends. This first block removes any leftovers from an
   interrupted prior run. */
BEGIN
  BEGIN DBMS_RLS.DROP_POLICY('LAB_USER','SUPPORT_TICKETS','M04_ACTING_USER_POL'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP FUNCTION m04_acting_user_pred'; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP PROCEDURE m04_set_acting_user'; EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP CONTEXT m04_agent_ctx';         EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN EXECUTE IMMEDIATE 'DROP TABLE m04_acting_proof PURGE';  EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

CREATE CONTEXT m04_agent_ctx USING m04_set_acting_user;

CREATE PROCEDURE m04_set_acting_user(p_user IN VARCHAR2) IS
BEGIN /* the agent host sets the acting end-user identity into the session
   context before issuing the retrieval — mirrors an MCP server stamping
   USER_IDENTITY, or Deep Sec establishing the security context from an OBO
   token. The engine reads it through SYS_CONTEXT in the VPD predicate. */
  DBMS_SESSION.SET_CONTEXT('M04_AGENT_CTX','ACTING_USER', p_user);
END;
/

CREATE FUNCTION m04_acting_user_pred(p_schema VARCHAR2, p_object VARCHAR2) RETURN VARCHAR2 IS
BEGIN /* the row-level predicate: a ticket is visible only if its customer's id
   parity matches the acting user (alice=even, bob=odd). The engine folds this
   into EVERY select on support_tickets, including the vector ORDER BY ... FETCH
   APPROX retrieval — the agent cannot phrase its way around it. */
  RETURN q'[customer_id IN (SELECT customer_id FROM customers
              WHERE MOD(customer_id,2) =
                    CASE WHEN SYS_CONTEXT('M04_AGENT_CTX','ACTING_USER')='alice' THEN 0 ELSE 1 END)]';
END;
/

BEGIN /* attach the VPD policy to support_tickets for SELECT — the engine now
   enforces the acting-user predicate on every read, however the rows are
   retrieved (SQL, document API, or vector ANN) */
  DBMS_RLS.ADD_POLICY(
    object_schema   => 'LAB_USER',
    object_name     => 'SUPPORT_TICKETS',
    policy_name     => 'M04_ACTING_USER_POL',
    function_schema => 'LAB_USER',
    policy_function => 'M04_ACTING_USER_PRED',
    statement_types => 'SELECT');
END;
/

CREATE TABLE m04_acting_proof (acting_user VARCHAR2(8), ticket_id NUMBER, PRIMARY KEY (acting_user, ticket_id));

DECLARE /* the agent runs the IDENTICAL semantic-retrieval query as acting user
   alice, then as bob, capturing each governed top-10 into the helper table. The
   probe text and the SQL are the same both times; only the acting context
   changes. The probe is embedded in-database by the same model that embedded the
   ticket bodies, so this is a real semantic retrieval, not a canned vector. */
  PROCEDURE retrieve_as(p_user VARCHAR2) IS
  BEGIN
    m04_set_acting_user(p_user);
    INSERT INTO m04_acting_proof (acting_user, ticket_id)
    SELECT p_user, ticket_id FROM (
      SELECT ticket_id
      FROM support_tickets
      ORDER BY VECTOR_DISTANCE(body_vec,
                 VECTOR_EMBEDDING(MINILM_L12 USING 'refund for a damaged package' AS data),
                 COSINE)
      FETCH APPROX FIRST 10 ROWS ONLY WITH TARGET ACCURACY 90);
  END;
BEGIN
  retrieve_as('alice');
  retrieve_as('bob');
  COMMIT;
END;
/

SELECT /* both acting users got a non-empty governed result from the same query */
       'ASSERT:both-identities-nonempty:' ||
       CASE WHEN (SELECT COUNT(*) FROM m04_acting_proof WHERE acting_user='alice') > 0
             AND (SELECT COUNT(*) FROM m04_acting_proof WHERE acting_user='bob')   > 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* the two governed result sets are DISJOINT — no ticket leaked across
          identities; an unauthorized row never entered the other agent's top-k */
       'ASSERT:identities-disjoint:' ||
       CASE WHEN NOT EXISTS (
              SELECT ticket_id FROM m04_acting_proof WHERE acting_user='alice'
              INTERSECT
              SELECT ticket_id FROM m04_acting_proof WHERE acting_user='bob')
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

SELECT /* parity-correctness: alice's rows really are even-customer tickets and
          bob's really are odd-customer tickets — the acting-user policy, not
          chance, split them. The agent acted AS the user. */
       'ASSERT:governed-as-user:' ||
       CASE WHEN (SELECT COUNT(*) FROM m04_acting_proof p JOIN support_tickets t ON t.ticket_id=p.ticket_id
                  WHERE p.acting_user='alice' AND MOD(t.customer_id,2) <> 0) = 0
             AND (SELECT COUNT(*) FROM m04_acting_proof p JOIN support_tickets t ON t.ticket_id=p.ticket_id
                  WHERE p.acting_user='bob'   AND MOD(t.customer_id,2) <> 1) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;

DECLARE /* teardown: drop policy, predicate function, setter, context, capture
   table — all autocommitted DDL, so it must be explicit. The validator's
   rollback afterward has nothing of ours left to undo. */
BEGIN
  DBMS_RLS.DROP_POLICY('LAB_USER','SUPPORT_TICKETS','M04_ACTING_USER_POL');
  EXECUTE IMMEDIATE 'DROP FUNCTION m04_acting_user_pred';
  EXECUTE IMMEDIATE 'DROP PROCEDURE m04_set_acting_user';
  EXECUTE IMMEDIATE 'DROP CONTEXT m04_agent_ctx';
  EXECUTE IMMEDIATE 'DROP TABLE m04_acting_proof PURGE';
END;
/

SELECT /* nothing module-local survives: no policy, no predicate function, no
          setter, no capture table — and support_tickets is unrestricted again
          at the seeded 300 rows */
       'ASSERT:teardown-clean:' ||
       CASE WHEN (SELECT COUNT(*) FROM user_policies WHERE policy_name='M04_ACTING_USER_POL') = 0
             AND (SELECT COUNT(*) FROM user_objects
                  WHERE object_name IN ('M04_ACTING_USER_PRED','M04_SET_ACTING_USER','M04_ACTING_PROOF')) = 0
             AND (SELECT COUNT(*) FROM support_tickets) = 300
            THEN 'PASS' ELSE 'FAIL' END
FROM dual;
