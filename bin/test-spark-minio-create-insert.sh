#!/usr/bin/env bash
# Create a Delta table on MinIO via Spark SQL, insert data, and query it.
#
# Prereqs: same as test-spark-minio.sh
#   - Spark 4.0.x GA (SPARK_HOME or spark-sql on PATH). Use a released 4.0.x, not 4.0.0-preview (Delta 4.0 needs ClassicConversions).
#     Spark 4.1.x causes NoSuchMethodError (LogKey). This repo's connector is built for Spark 4.0; use Spark 4.0.x GA for full compatibility.
#   - UC server running, MinIO S3 API port-forward to host (default 9000)
#   - Bucket spark-engine exists in MinIO
#
# Run from repo root: ./bin/test-spark-minio-create-insert.sh
#
# Note: This script does not set renewCredential.enabled (default true). Both this script and
# Kyuubi/FluxEngine use AwsVendedTokenProvider for table S3 access. If the UC server returns
# null session_token for MinIO, the connector must use AwsBasicCredentials (see
# AwsVendedTokenProvider.resolveCredentials). Local runs may work if the server sends ""
# instead of null; Kyuubi can NPE with "sessionToken must not be null" unless the connector
# handles null/blank—fix is in this repo (connector), not in FluxEngine config.

set -e
ROOT="$(cd "${0%/*}/.." && pwd)"
cd "$ROOT"

# Default to common Spark 4.0.0 GA install path if SPARK_HOME not set
if [ -z "${SPARK_HOME:-}" ] && [ -d "${HOME:-/tmp}/spark-4.0.0-bin-hadoop3/bin" ]; then
  export SPARK_HOME="${HOME:-/tmp}/spark-4.0.0-bin-hadoop3"
fi

SPARK_SQL="${SPARK_HOME:+$SPARK_HOME/bin/}spark-sql"
if ! command -v "$SPARK_SQL" &>/dev/null; then
  echo "spark-sql not found. Set SPARK_HOME or add Spark bin to PATH."
  echo "Example: export SPARK_HOME=\$HOME/spark-4.0.0-bin-hadoop3  (after: curl -sL https://archive.apache.org/dist/spark/spark-4.0.0/spark-4.0.0-bin-hadoop3.tgz | tar -xzf - -C \$HOME)"
  exit 1
fi

# Delta Lake 4.0.x is built for Spark 4.0.x; Spark 4.1.x changed internal APIs (LogKey) and causes NoSuchMethodError.
# Prefer SPARK_HOME so we don't need to run Spark (which can fail in restricted envs).
SPARK_VERSION=""
if [ -n "${SPARK_HOME:-}" ]; then
  SPARK_VERSION="$(echo "$SPARK_HOME" | sed -n 's/.*[\/-]\([0-9]*\)\.\([0-9]*\)[\.-].*/\1.\2/p' | head -1)"
fi
if [ -z "$SPARK_VERSION" ]; then
  SPARK_VERSION="$("$SPARK_SQL" --version 2>&1 | sed -n 's/.*version[^0-9]*\([0-9]*\.[0-9]*\).*/\1/p' | head -1)" || true
fi
# Reject Spark 4.0 preview: Delta 4.0.0 expects Spark 4.0.0 GA (preview lacks org.apache.spark.sql.classic.ClassicConversions).
if [ -n "${SPARK_HOME:-}" ] && echo "$SPARK_HOME" | grep -q preview; then
  echo "ERROR: Spark 4.0 preview build detected (SPARK_HOME contains 'preview')."
  echo "Delta Lake 4.0.0 requires Spark 4.0.0 GA (released), not preview. Preview causes: NoClassDefFoundError (ClassicConversions)."
  echo "Use a released Spark 4.0.x (e.g. sdkman install spark 4.0.0, or download from spark.apache.org)."
  exit 1
fi

if [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in
    3.*)
      echo "ERROR: Spark 3.x detected. This script requires Spark 4.0.x."
      echo "Spark 3.x with Delta causes: NoClassDefFoundError (SupportsNonDeterministicExpression)."
      echo "Set SPARK_HOME to a Spark 4.0.x installation, e.g.:"
      echo "  export SPARK_HOME=\$HOME/spark-4.0.0-bin-hadoop3"
      echo "  (or: sdkman install spark 4.0.0 && sdkman use spark 4.0.0)"
      echo "  (or: curl -sL https://archive.apache.org/dist/spark/spark-4.0.0/spark-4.0.0-bin-hadoop3.tgz | tar -xzf - -C \$HOME)"
      exit 1
      ;;
    4.1*)
      echo "ERROR: Spark 4.1.x detected. Delta Lake 4.0.x supports Spark 4.0.x only."
      echo "Spark 4.1 causes: NoSuchMethodError (org.apache.spark.internal.LogKey)."
      echo "Use Spark 4.0.x (e.g. brew install apache-spark@4.0)."
      exit 1
      ;;
  esac
fi

# Auto-pick Delta version and Scala by Spark: 3.5.x -> Delta 3.3.x + Scala 2.12, 4.0.x -> Delta 4.0.x + Scala 2.13 (override with DELTA_VERSION / SCALA_BINARY).
# Note: This repo's Spark connector is built for Spark 4.0; with Spark 3.5 you may see Guava/API errors. Use Spark 4.0.x for full compatibility.
if [ -z "${DELTA_VERSION:-}" ] && [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in
    3.5*) DELTA_VERSION=3.3.0 ;;
    4.0*) DELTA_VERSION=4.0.0 ;;
  esac
fi

UC_SPARK_S3_ENDPOINT="${UC_SPARK_S3_ENDPOINT:-http://localhost:9000}"
CATALOG_NAME="${UC_CATALOG_NAME:-unity}"
UC_URI="${UC_URI:-http://localhost:8080}"
TABLE_NAME="${UC_SPARK_TEST_TABLE:-minio_spark_test}"
# Must match server's s3.bucketPath (e.g. s3://spark-engine)
S3_LOCATION="s3://spark-engine/uc-tables/${TABLE_NAME}"

HADOOP_AWS_VERSION="${HADOOP_AWS_VERSION:-3.4.0}"
DELTA_VERSION="${DELTA_VERSION:-4.0.0}"
# Spark 3.5 distros are usually Scala 2.12; Delta must match or you get ClassNotFoundException (e.g. IterableOnce). Spark 4.x is 2.13.
if [ -z "${SCALA_BINARY:-}" ] && [ -n "$SPARK_VERSION" ]; then
  case "$SPARK_VERSION" in
    3.5*) SCALA_BINARY=2.12 ;;
    4.0*) SCALA_BINARY=2.13 ;;
    *)    SCALA_BINARY=2.13 ;;
  esac
fi
SCALA_BINARY="${SCALA_BINARY:-2.13}"

CLIENT_JAR_PATH="$(ls -1 "$ROOT"/clients/java/target/unitycatalog-client-*.jar 2>/dev/null | head -1)"
# Prefer connector JAR for same Scala as Delta; fallback to 2.13 (project default) if 2.12 not built
SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-${SCALA_BINARY}"/unitycatalog-spark_${SCALA_BINARY}-*.jar 2>/dev/null | head -1)"
[ -z "$SPARK_JAR_PATH" ] && [ "$SCALA_BINARY" = "2.12" ] && SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-2.13"/unitycatalog-spark_2.13-*.jar 2>/dev/null | head -1)"
PACKAGES="org.apache.hadoop:hadoop-aws:${HADOOP_AWS_VERSION},io.delta:delta-spark_${SCALA_BINARY}:${DELTA_VERSION}"

if [ -n "${SPARK_UC_JARS:-}" ]; then
  JARS="$SPARK_UC_JARS"
elif [ -n "$CLIENT_JAR_PATH" ] && [ -n "$SPARK_JAR_PATH" ]; then
  JARS="$CLIENT_JAR_PATH,$SPARK_JAR_PATH"
else
  echo "Building connector JARs..."
  ./build/sbt -batch client/package spark/package
  CLIENT_JAR_PATH="$(ls -1 "$ROOT"/clients/java/target/unitycatalog-client-*.jar 2>/dev/null | head -1)"
  SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-${SCALA_BINARY}"/unitycatalog-spark_${SCALA_BINARY}-*.jar 2>/dev/null | head -1)"
  [ -z "$SPARK_JAR_PATH" ] && [ "$SCALA_BINARY" = "2.12" ] && SPARK_JAR_PATH="$(ls -1 "$ROOT/connectors/spark/target/scala-2.13"/unitycatalog-spark_2.13-*.jar 2>/dev/null | head -1)"
  JARS="$CLIENT_JAR_PATH,$SPARK_JAR_PATH"
fi

echo "UC=$UC_URI MinIO=$UC_SPARK_S3_ENDPOINT catalog=$CATALOG_NAME table=default.$TABLE_NAME"
echo "Location: $S3_LOCATION"
echo ""

# Use a temp Derby metastore so we don't clash with an existing metastore_db from another Spark version
METASTORE_TMP="${METASTORE_TMP:-$(mktemp -d 2>/dev/null || echo /tmp/uc-spark-metastore-$$)}"

"$SPARK_SQL" --name "uc-minio-create-insert" \
  --master "local[*]" \
  --jars "$JARS" \
  --packages "$PACKAGES" \
  --conf "spark.driver.extraJavaOptions=-Dderby.system.home=$METASTORE_TMP" \
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
DROP TABLE IF EXISTS default.${TABLE_NAME};
CREATE TABLE default.${TABLE_NAME} (id INT, name STRING) USING delta LOCATION '${S3_LOCATION}';
"

echo "Done. Table default.$TABLE_NAME created and data inserted at $S3_LOCATION"
