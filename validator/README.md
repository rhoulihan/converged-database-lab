# Validator

Runs every module's demo scripts against the live lab container and reports
pass/fail per script. This is the gate: a module is not done until the
validator passes against a fresh `docker compose up`.

## Discovery

Scripts live in `modules/NN-slug/scripts/` and run in lexical order (modules,
then scripts within each module):

- `*.sql` — executed statement-by-statement via python-oracledb (thin mode) as
  `LAB_USER` against `localhost:1521/FREEPDB1`. PL/SQL blocks end with a line
  containing only `/`; plain SQL statements end with `;`.
- `*.js` — executed with `mongosh` inside the `lab-oracle` container against
  the MongoDB API (port 27017, `lab_user` database).

Connection overrides: `LAB_DSN`, `LAB_USER`, `LAB_PASSWORD`, `LAB_MONGO_URI`.

## Assertions

SQL scripts assert by SELECTing literal strings of the form
`ASSERT:<name>:PASS|FAIL` as the first column:

```sql
SELECT 'ASSERT:customer-count:' || CASE WHEN COUNT(*) = 200 THEN 'PASS' ELSE 'FAIL' END
FROM customers;
```

JS scripts `print()` the same convention:

```js
print('ASSERT:dv-count:' + (db.customer_profile_dv.countDocuments({}) === 200 ? 'PASS' : 'FAIL'));
```

Every script must leave the domain unchanged. SQL scripts run in a single
transaction that the harness rolls back after the script completes. JS scripts
go through the MongoDB API (auto-commit), so they must clean up explicitly —
delete what they insert, restore what they update.

## Authoring rules (SQL comments)

- Standalone `--` comment lines before a statement are stripped by the
  harness and never attach to the statement that follows — safe to use freely.
- `--` comments inside a statement (after its first code line) and inline
  `/* ... */` comments are always safe.
- Do not end a file with a bare comment block followed by `;` — there is no
  statement there. (Trailing comment-only text after the last `;` is ignored.)
- `CREATE TYPE` and `CREATE TYPE BODY` are **not supported** in module scripts.
  The PL/SQL block detector recognises `DECLARE`, `BEGIN`, and named subprograms
  (`FUNCTION`, `PROCEDURE`, `PACKAGE`, `TRIGGER`) but not type definitions, so
  type DDL will be mis-parsed and silently dropped. Use anonymous blocks or
  stored procedures instead.

## Running

```bash
docker compose up -d --build oracle          # wait for healthy
pip install -r validator/requirements.txt
python validator/run.py
```

Exit code is 0 iff every assertion in every script is PASS and no script
errored. Full detail lands in `validator/results.json` (gitignored).
