# Docker HEALTHCHECK for fiesta-sql-runtime (Windows).
#
# Healthy = setup-sql.ps1 has finished its restore/attach pass (the ready
# marker exists) AND SQL answers a trivial query. The marker gates out the
# window between "SQL accepts connections" and "user DBs are actually
# restored": a bare SELECT 1 reports healthy too early, letting the DB-bridge
# containers (Account, Character, ...) boot into a half-restored server and
# DB_Init-fail. The marker is on a container-local path so it resets every
# boot -- a restore must complete again before the container is healthy.
#
# sqlcmd flags:
#   -E      Windows auth (ContainerAdministrator is BUILTIN\Administrators,
#           the SQL Express SQLSYSADMINACCOUNTS) -- avoids sa password /
#           lockout edge cases in the healthcheck path.
#   -C      trust the server cert (SQL Express ships a self-signed one).
#   -N o    encryption optional -- ODBC Driver 18's sqlcmd defaults to
#           mandatory encryption, which a fresh container has no cert for.
if (-not (Test-Path 'C:\fiesta-sql-ready')) { exit 1 }

'SELECT 1' | sqlcmd -S 127.0.0.1 -E -C -N o
exit $LASTEXITCODE
