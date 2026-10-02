#!/bin/bash
set -euo pipefail

DATADIR="${MARIADB_DATA_DIR:-/var/lib/mysql}"
NODE_NAME="${GALERA_NODE_NAME:-$(hostname)}"
SELF_ADDR="$(hostname -i 2>/dev/null | awk '{print $1}')"

if [ -n "${GALERA_HC_USER:-}" ] && [ -n "${GALERA_HC_PASSWORD:-}" ]; then
  umask 077
  cat > /etc/mysql/healthcheck.cnf <<EOF
[mariadb-client]
user=${GALERA_HC_USER}
password=${GALERA_HC_PASSWORD}
EOF
fi

bootstrap=0

if [ ! -d "${DATADIR}/mysql" ]; then
  if [ "${GALERA_BOOTSTRAP_NODE:-0}" = "1" ]; then
    echo "[galera] ${NODE_NAME}: empty datadir on designated bootstrap node -> creating new cluster"
    bootstrap=1
  fi
else
  safe="$(sed -n 's/^safe_to_bootstrap:[[:space:]]*//p' "${DATADIR}/grastate.dat" 2>/dev/null | tr -d '[:space:]')"
  if [ "${safe}" = "1" ]; then
    echo "[galera] ${NODE_NAME}: safe_to_bootstrap=1 -> bootstrapping existing cluster"
    bootstrap=1
  fi
fi

args=( "--wsrep-node-name=${NODE_NAME}" )
if [ -n "${SELF_ADDR}" ]; then
  args+=( "--wsrep-node-address=${SELF_ADDR}" )
fi
if [ -n "${GALERA_SST_USER:-}" ] && [ -n "${GALERA_SST_PASSWORD:-}" ]; then
  args+=( "--wsrep-sst-auth=${GALERA_SST_USER}:${GALERA_SST_PASSWORD}" )
fi
if [ "${bootstrap}" -eq 1 ]; then
  args+=( "--wsrep-new-cluster" )
fi

echo "[galera] ${NODE_NAME}: starting mariadbd (bootstrap=${bootstrap})"
exec /usr/local/bin/docker-entrypoint.sh mariadbd "${args[@]}" "$@"
