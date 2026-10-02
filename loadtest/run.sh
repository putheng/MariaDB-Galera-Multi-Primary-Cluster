#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DRIVER_URL="https://repo1.maven.org/maven2/org/mariadb/jdbc/mariadb-java-client/3.5.10/mariadb-java-client-3.5.10.jar"
DRIVER="$(ls lib/mariadb-java-client-*.jar 2>/dev/null | head -1 || true)"

if [ -z "$DRIVER" ]; then
  echo "MariaDB JDBC driver not found in lib/, downloading..."
  mkdir -p lib
  curl -sSL -o lib/mariadb-java-client-3.5.10.jar "$DRIVER_URL"
  DRIVER="$(ls lib/mariadb-java-client-*.jar | head -1)"
fi

PROPS="${1:-load-test.properties}"
if [ "$#" -gt 0 ]; then shift; fi

JMX="${JMX:-mariadb-galera-load.jmx}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="results/$TS"
mkdir -p "$OUT"

export HEAP="${HEAP:--Xms1g -Xmx2g}"

echo "plan       : $JMX"
echo "properties : $PROPS"
echo "driver     : $SCRIPT_DIR/$DRIVER"
echo "results    : $OUT"
echo

jmeter -n \
  -t "$JMX" \
  -q "$PROPS" \
  -Juser.classpath="$SCRIPT_DIR/$DRIVER" \
  "$@" \
  -l "$OUT/result.jtl" \
  -j "$OUT/jmeter.log" \
  -e -o "$OUT/html"

echo
echo "HTML report: $OUT/html/index.html"
echo "Raw results: $OUT/result.jtl"
