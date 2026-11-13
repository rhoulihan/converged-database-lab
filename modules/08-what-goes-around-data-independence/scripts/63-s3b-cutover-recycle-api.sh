#!/usr/bin/env bash
# S3 at scale (B) cutover: m08b3_orders just became a duality view of the same
# name, so the API tier must re-read the collection details. This reuses the
# S3 cutover script (restart the lab container, wait until the database, ORDS
# and the MongoDB API answer) and renames its check.
#
# It also checks that the four measuring scripts (61, 64, 66, 68) are still
# byte-identical: mongosh reads them from stdin inside the container, where
# load() cannot reach the module folder, so they are copies.
set -o pipefail
DIR="$(dirname "$0")"
n=$(md5sum "$DIR"/6[1468]-s3b-measure.js | awk '{print $1}' | sort -u | wc -l)
c=$(ls "$DIR"/6[1468]-s3b-measure.js | wc -l)
if [ "$n" = "1" ] && [ "$c" = "4" ]; then
  echo "ASSERT:s3b-measure-copies-identical:PASS"
else
  echo "ASSERT:s3b-measure-copies-identical:FAIL"
fi
bash "$DIR/02b-cutover-recycle-api.sh" | sed 's/ASSERT:s3-api-recycled:/ASSERT:s3b-api-recycled:/'
