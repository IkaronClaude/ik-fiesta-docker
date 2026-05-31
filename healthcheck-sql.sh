#!/bin/bash
# Docker HEALTHCHECK for fiesta-sql-runtime (Linux).
#
# Healthy = setup-sql.sh has finished its restore/attach pass (the ready
# marker exists) AND SQL answers a trivial query. The marker gates out the
# window between "SQL accepts connections" and "user DBs are actually
# restored": a bare SELECT 1 reports healthy too early, letting the DB-bridge
# containers (Account, Character, ...) boot into a half-restored server and
# DB_Init-fail. The marker is on a container-local path so it resets every
# boot -- a restore must complete again before the container is healthy.
set -u

[ -f /tmp/fiesta-sql-ready ] || exit 1

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[ -x "${SQLCMD}" ] || SQLCMD=/opt/mssql-tools/bin/sqlcmd

exec "${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -b -Q "SELECT 1"
