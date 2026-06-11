#!/bin/bash
# Custom entrypoint: starts Oracle Database and ORDS.
# Oracle is started via the gvenzl base image entrypoint.
# ORDS is started after Oracle is healthy.

set -uo pipefail

ORDS_CONFIG="/etc/ords/config"
ORDS_LOG="/tmp/ords.log"
ORACLE_PDB="FREEPDB1"
# The install gate is the pool config INSIDE the container (not a marker on the
# data volume): /etc/ords/config is container-local, so a recreated container
# loses the pool config even though the database volume persists. `ords install`
# is a validate/no-op against a database that already has the ORDS schema, and
# it regenerates the client-side pool config + wallet either way.
ORDS_POOL_CONFIG="$ORDS_CONFIG/databases/default/pool.xml"

# Start Oracle using the gvenzl base image entrypoint (runs in background)
/opt/oracle/container-entrypoint.sh &
ORACLE_PID=$!

# Wait for Oracle to be ready
echo "=== Waiting for Oracle to be ready ==="
until /opt/oracle/healthcheck.sh > /dev/null 2>&1; do
  sleep 2
done
echo "=== Oracle is ready ==="

# Install ORDS when this container has no pool config yet (first run, or a
# recreated container against an existing database volume).
if [ ! -f "$ORDS_POOL_CONFIG" ]; then
  echo "=== No ORDS pool config: installing/validating ORDS ==="

  ADMIN_PWD="${ORACLE_PASSWORD:-LabAdmin2026}"

  # If the database already has ORDS (recreated container, persistent volume),
  # the installer also needs the ORDS_PUBLIC_USER password to rebuild the local
  # wallet — and that password was generated on the original install. Reset it
  # to a known value so the non-interactive install can proceed.
  sqlplus -s / as sysdba <<SQL
ALTER SESSION SET CONTAINER = $ORACLE_PDB;
DECLARE
  c PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO c FROM dba_users WHERE username = 'ORDS_PUBLIC_USER';
  IF c = 1 THEN
    EXECUTE IMMEDIATE 'ALTER USER ORDS_PUBLIC_USER IDENTIFIED BY "$ADMIN_PWD" ACCOUNT UNLOCK';
  END IF;
END;
/
SQL

  # Install (fresh) or validate (existing schema) ORDS in the PDB. --proxy-user
  # makes the installer read the ORDS_PUBLIC_USER password from stdin as well
  # (line 2); without it a re-install against an existing ORDS schema aborts
  # with "Missing the ORDS_PUBLIC_USER password". Both lines carry the same
  # value (see the ALTER USER above), so prompt order does not matter.
  printf '%s\n%s\n' "$ADMIN_PWD" "$ADMIN_PWD" | ords --config "$ORDS_CONFIG" install \
    --db-hostname localhost \
    --db-port 1521 \
    --db-servicename "$ORACLE_PDB" \
    --admin-user SYS \
    --proxy-user \
    --password-stdin \
    --feature-sdw true \
    --feature-db-api true \
    --log-folder /tmp 2>&1 || {
      echo "=== ORDS install exited with code $?. Checking logs... ==="
      ls -la /tmp/*.log 2>/dev/null
      tail -50 /tmp/*.log 2>/dev/null || true
    }

  # ORDS-enable the lab schema. The initdb-time attempt (07-ords-enable.sql)
  # always defers on first boot because gvenzl runs init scripts BEFORE this
  # ORDS install — without this, the MongoDB API exposes no lab_user database.
  # ENABLE_SCHEMA is an upsert; re-running on a recreated container is safe.
  echo "=== Enabling ORDS for LAB_USER schema ==="
  sqlplus -s / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = FREEPDB1;
BEGIN
  ORDS_METADATA.ORDS_ADMIN.ENABLE_SCHEMA(p_enabled => TRUE, p_schema => 'LAB_USER',
                     p_url_mapping_type => 'BASE_PATH',
                     p_url_mapping_pattern => 'lab', p_auto_rest_auth => FALSE);
  COMMIT;
END;
/
SQL

  echo "=== ORDS configuration complete ==="
fi

# Enable MongoDB API. Runs every boot (not just first run): /etc/ords/config is
# container-local, so a recreated container would otherwise lose these settings
# even though the database volume (and the first-run marker) persist.
# NB: the setting is mongo.tls — mongo.tls.enabled is not recognized by ORDS.
ords --config "$ORDS_CONFIG" config set mongo.enabled true
ords --config "$ORDS_CONFIG" config set mongo.port 27017
ords --config "$ORDS_CONFIG" config set mongo.tls false

# Start ORDS
echo "=== Starting ORDS ==="
ords --config "$ORDS_CONFIG" serve \
  --port 8181 \
  > "$ORDS_LOG" 2>&1 &
ORDS_PID=$!

echo "=== ORDS started (PID: $ORDS_PID) ==="

# Wait for ORDS to be ready
echo "=== Waiting for ORDS health ==="
for i in $(seq 1 90); do
  if curl -sf -o /dev/null -w '%{http_code}' http://localhost:8181/ 2>/dev/null | grep -q '302\|200'; then
    echo "=== ORDS is healthy ==="
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "=== ORDS not responding after 3 minutes. Log tail: ==="
    tail -30 "$ORDS_LOG" 2>/dev/null || true
    echo "=== Continuing without ORDS ==="
  fi
  sleep 2
done

# Monitor both processes — exit if Oracle dies
echo "=== Oracle + ORDS running. Monitoring... ==="
while true; do
  if ! kill -0 "$ORACLE_PID" 2>/dev/null; then
    echo "=== Oracle process died ==="
    kill "$ORDS_PID" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$ORDS_PID" 2>/dev/null; then
    echo "=== ORDS process died, restarting... ==="
    ords --config "$ORDS_CONFIG" serve \
      --port 8181 \
      > "$ORDS_LOG" 2>&1 &
    ORDS_PID=$!
  fi
  sleep 5
done
