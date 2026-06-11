#!/bin/bash
# Custom entrypoint: starts Oracle Database and ORDS.
# Oracle is started via the gvenzl base image entrypoint.
# ORDS is started after Oracle is healthy.

set -uo pipefail

ORDS_CONFIG="/etc/ords/config"
ORDS_LOG="/tmp/ords.log"
ORACLE_PDB="FREEPDB1"
FIRST_RUN_MARKER="/opt/oracle/oradata/.ords_installed"

# Start Oracle using the gvenzl base image entrypoint (runs in background)
/opt/oracle/container-entrypoint.sh &
ORACLE_PID=$!

# Wait for Oracle to be ready
echo "=== Waiting for Oracle to be ready ==="
until /opt/oracle/healthcheck.sh > /dev/null 2>&1; do
  sleep 2
done
echo "=== Oracle is ready ==="

# Install ORDS into database on first run
if [ ! -f "$FIRST_RUN_MARKER" ]; then
  echo "=== First run: installing ORDS into database ==="

  ADMIN_PWD="${ORACLE_PASSWORD:-LabAdmin2026}"

  # Install ORDS into the PDB using interactive install
  echo "$ADMIN_PWD" | ords --config "$ORDS_CONFIG" install \
    --db-hostname localhost \
    --db-port 1521 \
    --db-servicename "$ORACLE_PDB" \
    --admin-user SYS \
    --password-stdin \
    --feature-sdw true \
    --feature-db-api true \
    --log-folder /tmp 2>&1 || {
      echo "=== ORDS install exited with code $?. Checking logs... ==="
      ls -la /tmp/*.log 2>/dev/null
      tail -50 /tmp/*.log 2>/dev/null || true
    }

  # Enable MongoDB API
  ords --config "$ORDS_CONFIG" config set mongo.enabled true
  ords --config "$ORDS_CONFIG" config set mongo.port 27017
  ords --config "$ORDS_CONFIG" config set mongo.tls.enabled false

  touch "$FIRST_RUN_MARKER"
  echo "=== ORDS configuration complete ==="
fi

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
