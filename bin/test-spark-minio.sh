#!/usr/bin/env bash
# Run Spark SQL against Unity Catalog with MinIO storage.
#
# Prereqs:
#   - Apache Spark 3.5+ or 4.x with bin/spark-sql on PATH or SPARK_HOME set
#   - UC server running (e.g. docker compose up), MinIO S3 API port-forward to host (default 9000)
#   - For MinIO-backed table: run SKIP_CLEANUP=1 ./bin/test-minio.sh first so minio_test is kept
#
# Connector: uses locally built JARs (client + spark) if present; otherwise requires
#   ./build/sbt spark/publishM2 and Spark will resolve from local M2 (see SPARK_UC_USE_PACKAGES).
#
# Run from repo root: ./bin/test-spark-minio.sh

set -e
ROOT="$(cd "${0%/*}/.." && pwd)"
cd "$ROOT"

# Default to common Spark 4.0.0 GA install path if SPARK_HOME not set
if [ -z "${SPARK_HOME:-}" ] && [ -d "${HOME:-/tmp}/spark-4.0.0-bin-hadoop3/bin" ]; then
  export SPARK_HOME="${HOME:-/tmp}/spark-4.0.0-bin-hadoop3"
fi

# Spark: use SPARK_HOME or assume spark-sql is on PATH
SPARK_SQL="${SPARK_HOME:+$SPARK_HOME/bin/}spark-sql"
if ! command -v "$SPARK_SQL" &>/dev/null; then
  echo "spark-sql not found. Set SPARK_HOME or add Spark bin to PATH."
  echo "Example: export SPARK_HOME=\$HOME/spark-4.0.0-bin-hadoop3  (after downloading Spark 4.0.0 GA)"
  exit 1
fi

# Delta 4.0.x supports Spark 4.0.x GA only; 4.0.0-preview lacks ClassicConversions; 4.1.x causes NoSuchMethodError (LogKey).
if [ -n "${SPARK_HOME:-}" ] && echo "$SPARK_HOME" | grep -q preview; then
  echo "ERROR: Spark 4.0 preview detected (SPARK_HOME contains 'preview'). Delta 4.0.0 requires Spark 4.0.0 GA (released). Use sdkman install spark 4.0.0 or download from spark.apache.org."
  exit 1
fi
SPARK_VERSION=""
[ -n "${SPARK_HOME:-}" ] && SPARK_VERSION="$(echo "$SPARK_HOME" | sed -n 's/.*[\/-]\([0-9]*\)\.\([0-9]*\)[\.-].*/\1.\2/p' | head -1)"
[ -z "$SPARK_VERSION" ] && SPARK_VERSION="$("$SPARK_SQL" --version 2>&1 | sed -n 's/.*version[^0-9]*\([0-9]*\.[0-9]*\).*/\1/p' | head -1)" || true
if [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in 4.1*) echo "ERROR: Spark 4.1.x detected. Delta 4.0.x supports Spark 4.0.x only. Use Spark 4.0.x or Spark 3.5.x + DELTA_VERSION=3.3.0."; exit 1 ;; esac
fi

# Auto-pick Delta by Spark: 3.5.x -> 3.3.0, 4.0.x -> 4.0.0 (override with DELTA_VERSION). Connector is built for Spark 4.0.
if [ -z "${DELTA_VERSION:-}" ] && [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in
    3.5*) DELTA_VERSION=3.3.0 ;;
    4.0*) DELTA_VERSION=4.0.0 ;;
  esac
fi

# MinIO S3 API endpoint (port 9000 = S3 API; 9001 = Console)
UC_SPARK_S3_ENDPOINT="${UC_SPARK_S3_ENDPOINT:-http://localhost:9000}"
CATALOG_NAME="${UC_CATALOG_NAME:-unity}"
UC_URI="${UC_URI:-http://localhost:8080}"

# Package versions (match build.sbt / docs)
HADOOP_AWS_VERSION="${HADOOP_AWS_VERSION:-3.4.0}"
DELTA_VERSION="${DELTA_VERSION:-4.0.0}"
# Spark 3.5 is usually Scala 2.12; Delta must match (IterableOnce etc.). Spark 4.x is 2.13.
if [ -z "${SCALA_BINARY:-}" ] && [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in
    3.5*) SCALA_BINARY=2.12 ;;
    4.0*) SCALA_BINARY=2.13 ;;
    *)    SCALA_BINARY=2.13 ;;
  esac
fi
SCALA_BINARY="${SCALA_BINARY:-2.13}"

# Prefer local JARs so no publishM2 is needed
CLIENT_JAR_PATH="$(ls -1 "$ROOT"/clients/java/target/unitycatalog-client-*.jar 2>/dev/null | head -1)"
SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-${SCALA_BINARY}"/unitycatalog-spark_${SCALA_BINARY}-*.jar 2>/dev/null | head -1)"
[ -z "$SPARK_JAR_PATH" ] && [ "$SCALA_BINARY" = "2.12" ] && SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-2.13"/unitycatalog-spark_2.13-*.jar 2>/dev/null | head -1)"
PACKAGES="org.apache.hadoop:hadoop-aws:${HADOOP_AWS_VERSION},io.delta:delta-spark_${SCALA_BINARY}:${DELTA_VERSION}"

if [ -n "${SPARK_UC_JARS:-}" ]; then
  JARS="$SPARK_UC_JARS"
elif [ -n "$CLIENT_JAR_PATH" ] && [ -n "$SPARK_JAR_PATH" ]; then
  JARS="$CLIENT_JAR_PATH,$SPARK_JAR_PATH"
  echo "Using local JARs: $JARS"
else
  echo "Local connector JARs not found. Building with: ./build/sbt client/package spark/package"
  ./build/sbt -batch client/package spark/package
  CLIENT_JAR_PATH="$(ls -1 "$ROOT"/clients/java/target/unitycatalog-client-*.jar 2>/dev/null | head -1)"
  SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-${SCALA_BINARY}"/unitycatalog-spark_${SCALA_BINARY}-*.jar 2>/dev/null | head -1)"
  [ -z "$SPARK_JAR_PATH" ] && [ "$SCALA_BINARY" = "2.12" ] && SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-2.13"/unitycatalog-spark_2.13-*.jar 2>/dev/null | head -1)"
  JARS="$CLIENT_JAR_PATH,$SPARK_JAR_PATH"
  echo "Using built JARs: $JARS"
fi

echo "Using UC at $UC_URI, MinIO at $UC_SPARK_S3_ENDPOINT, catalog=$CATALOG_NAME"
echo "Packages: $PACKAGES"
echo ""

# Run Spark SQL. To keep minio_test for this script, create it without cleanup first:
#   SKIP_CLEANUP=1 ./bin/test-minio.sh
# Then run: SELECT * FROM default.minio_test LIMIT 5; in the Spark shell or add it below.
"$SPARK_SQL" --name "uc-minio-test" \
  --master "local[*]" \
  --jars "$JARS" \
  --packages "$PACKAGES" \
  --conf "spark.sql.extensions=io.delta.sql.DeltaSparkSessionExtension" \
  --conf "spark.sql.catalog.spark_catalog=org.apache.spark.sql.delta.catalog.DeltaCatalog" \
  --conf "spark.hadoop.fs.s3.impl=org.apache.hadoop.fs.s3a.S3AFileSystem" \
  --conf "spark.hadoop.fs.s3a.endpoint=$UC_SPARK_S3_ENDPOINT" \
  --conf "spark.hadoop.fs.s3a.path.style.access=true" \
  --conf "spark.hadoop.fs.s3a.endpoint.region=us-east-1" \
  --conf "spark.sql.catalog.$CATALOG_NAME=io.unitycatalog.spark.UCSingleCatalog" \
  --conf "spark.sql.catalog.$CATALOG_NAME.uri=$UC_URI" \
  --conf "spark.sql.catalog.$CATALOG_NAME.token=" \
  --conf "spark.sql.defaultCatalog=$CATALOG_NAME" \
  -e "
  SHOW SCHEMAS;
  SHOW TABLES IN default;
  "

echo "Done."
