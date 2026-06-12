DELETE /* Module 02 proof 3: transactional read-after-write text search.

   A row INSERTed and COMMITted is immediately findable through the Oracle
   Text search index (CONTAINS) — no refresh interval, no change-stream lag,
   no separate search process. The lab's ticket_text_idx is created with
   PARAMETERS ('SYNC (ON COMMIT)') (docker/init/05-text-vector.sql): the index
   syncs inside the committing transaction, so search visibility arrives WITH
   the commit, not eventually after it.

   COMMIT WARNING: this script intentionally COMMITs — a documented exception
   to the rollback contract (see the module README). Read-after-write through
   a text index can only be demonstrated across a real commit boundary.
   Explicit cleanup restores the domain: the probe ticket is deleted and the
   delete is committed. The script is also reseed-safe — ticket_id is
   identity-generated and nothing assumes a fixed id; the probe row is
   addressed only by its unique subject and marker token.

   This first statement is an idempotence guard: remove any probe rows left by
   a previously interrupted run (committed together with the INSERT below). */
FROM support_tickets WHERE subject = 'm02 rw-search probe';

INSERT INTO support_tickets (customer_id, subject, body, status)
VALUES (1, 'm02 rw-search probe',
        'read-after-write search probe, marker token zzqxw9347', 'open');

COMMIT;

SELECT /* the committed row is findable by CONTAINS immediately — same call
          stack, same second, no sync window */
       'ASSERT:contains-finds-committed-write:' ||
       CASE WHEN COUNT(*) = 1 THEN 'PASS' ELSE 'FAIL' END
FROM support_tickets WHERE CONTAINS(body, 'zzqxw9347') > 0;

DELETE /* explicit cleanup: remove the probe ticket */
FROM support_tickets WHERE subject = 'm02 rw-search probe';

COMMIT;

SELECT /* and the committed delete is just as immediately invisible to
          search — read-after-write holds in both directions */
       'ASSERT:contains-after-cleanup:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM support_tickets WHERE CONTAINS(body, 'zzqxw9347') > 0;

SELECT /* domain restored: no probe rows survive in the base table either */
       'ASSERT:probe-rows-gone:' ||
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM support_tickets WHERE subject = 'm02 rw-search probe';
