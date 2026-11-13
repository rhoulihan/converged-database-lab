#!/usr/bin/env bash
# S3 cutover: the move from a collection to a same-named duality view is a
# deployment event. The API tier must be recycled so it re-reads collection
# metadata; otherwise it keeps the stage-0 collection-table shape cached.
# Here the API tier (ORDS) lives in the lab container, so we restart it and
# wait (bounded) until the database is healthy, ORDS answers on 8181 and the
# MongoDB API answers a ping on 27017.
set -u
ENGINE="${CONTAINER_ENGINE:-docker}"
C="${LAB_CONTAINER:-lab-oracle}"
USER_="${LAB_USER:-LAB_USER}"
PWD_="${LAB_PASSWORD:-LabUser2026}"
URI="mongodb://${USER_}:${PWD_}@localhost:27017/${USER_,,}?authMechanism=PLAIN&authSource=\$external&tls=false&loadBalanced=true&retryWrites=false"
TIMEOUT=300

"$ENGINE" restart "$C" >/dev/null || { echo "ASSERT:s3-api-recycled:FAIL"; exit 1; }

start=$(date +%s)
while :; do
  health=$("$ENGINE" inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)
  http=$(curl -so /dev/null -w '%{http_code}' http://localhost:8181/ 2>/dev/null)
  if [ "$health" = "healthy" ] && { [ "$http" = "200" ] || [ "$http" = "302" ]; } &&
     "$ENGINE" exec "$C" mongosh --quiet "$URI" --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -q '^1$'; then
    echo "api ready after $(( $(date +%s) - start ))s"
    echo "ASSERT:s3-api-recycled:PASS"
    exit 0
  fi
  if [ $(( $(date +%s) - start )) -ge $TIMEOUT ]; then
    echo "timeout after ${TIMEOUT}s (health=$health http=$http)"
    echo "ASSERT:s3-api-recycled:FAIL"
    exit 1
  fi
  sleep 5
done
