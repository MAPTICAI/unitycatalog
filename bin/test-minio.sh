#!/usr/bin/env bash
# Quick test that UC (Docker Compose) can talk to MinIO via host port-forward.
# Prereqs: MinIO S3 API port-forward to host (9000 = S3 API, 9001 = Console; use 9000 for S3).
#   Bucket "spark-engine" must exist. docker compose up.
# If you see "No credentials returned" or "Temporary credentials are required": rebuild CLI and server:
#   ./build/sbt examples/cli/package
#   docker compose build server && docker compose up -d --force-recreate
# If you see 400 Bad Request: MinIO S3 API is on port 9000 by default; forward that and set UC_S3_ENDPOINT=http://localhost:9000
# Run from repo root: ./bin/test-minio.sh

set -e
ROOT="$(cd "${0%/*}/.." && pwd)"
UC="$ROOT/bin/uc"
BASE="http://localhost:8080"

echo "1. Server health..."
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/api/2.1/unity-catalog/catalogs" || true)
if [ "$code" = "200" ]; then echo "OK"; else echo "FAIL (got $code, is UC running on 8080?)"; exit 1; fi

echo "2. List catalogs..."
"$UC" catalog list

echo "3. Create external table on MinIO (s3://spark-engine)..."
# CLI runs on host. MinIO S3 API is port 9000; 9001 is Console. Forward 9000 and use localhost:9000.
export UC_S3_ENDPOINT="${UC_S3_ENDPOINT:-http://localhost:9000}"
"$UC" table create --full_name unity.default.minio_test --columns "id int" --storage_location s3://spark-engine/uc-tables/minio_test

echo "4. Get table (hits MinIO)..."
"$UC" table get --full_name unity.default.minio_test

# Skip cleanup to keep minio_test for Spark/Kyuubi (e.g. SKIP_CLEANUP=1 ./bin/test-minio.sh)
if [ -z "${SKIP_CLEANUP:-}" ]; then
  echo "5. Cleanup..."
  "$UC" table delete --full_name unity.default.minio_test
else
  echo "5. Cleanup skipped (SKIP_CLEANUP set). Table unity.default.minio_test kept for Spark/Kyuubi."
fi

echo "Done. Check MinIO bucket spark-engine for prefix uc-tables/ or uc-models/ if you used managed storage."
