#!/usr/bin/env bash
# S3 at scale (B) cutover: m08b3_orders just became a duality view of the same
# name, so the API tier must re-read the collection details. This reuses the
# S3 cutover script (restart the lab container, wait until the database, ORDS
# and the MongoDB API answer) and renames its check.
set -o pipefail
bash "$(dirname "$0")/02b-cutover-recycle-api.sh" | sed 's/ASSERT:s3-api-recycled:/ASSERT:s3b-api-recycled:/'
