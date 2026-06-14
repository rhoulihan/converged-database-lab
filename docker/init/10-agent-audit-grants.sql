ALTER SESSION SET CONTAINER = FREEPDB1;

-- Audit grants for module 04 (AI agents + enterprise data), proof 3
-- (unified audit trail). The base lab_user (01-lab-user.sql) is a least-privileged
-- application user with no audit rights — deliberately, because "who can see the
-- audit trail?" is itself a governance control. Module 04's audit proof needs two
-- capabilities that a least-privileged user does NOT get by default:
--
--   AUDIT SYSTEM  — create and enable a unified AUDIT POLICY on lab_user's own
--                   tables (CREATE AUDIT POLICY ... ; AUDIT POLICY ...). Without
--                   it, CREATE AUDIT POLICY raises ORA-41732.
--   AUDIT_VIEWER  — query UNIFIED_AUDIT_TRAIL. Without it the view resolves to
--                   ORA-00942 (it is owned by AUDSYS and not granted to app users).
--                   AUDIT_VIEWER is read-only on the trail — it cannot alter audit
--                   configuration, consistent with the auditor-vs-operator split.
--
-- This is the honest version of the article's "one audit trail" claim: the trail
-- exists for every model in one engine, but reading it is itself a privileged,
-- separately-granted role — the governance story, not a bug.
--
-- NOTE on flushing: 26ai Free writes the unified audit trail in immediate mode,
-- so audited statements appear in UNIFIED_AUDIT_TRAIL without an explicit
-- DBMS_AUDIT_MGMT.FLUSH_UNIFIED_AUDIT_TRAIL. The proof therefore needs NO grant on
-- DBMS_AUDIT_MGMT; module 04's audit script documents this and scopes every
-- assertion to a per-run nonce so persisted audit history never makes a re-run flaky.
--
-- Shared-file discipline: this script is NEW on the article/04 branch and does NOT
-- touch the shared init-01..08. It is additive and idempotent (GRANT is a no-op if
-- already held), so a recreated container over a persistent volume re-runs cleanly.
GRANT AUDIT SYSTEM TO lab_user;
GRANT AUDIT_VIEWER TO lab_user;
