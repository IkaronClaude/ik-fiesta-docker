#!/bin/bash
# Fiesta SQL Server runtime -- Linux entrypoint.
#
# Starts sqlservr, walks /var/opt/mssql/backup for *.bak, RESTOREs each one
# whose DB isn't already registered, then hands off to sqlservr in foreground.
#
# Contract (see Dockerfile.sql.linux for full docs):
#   SA_PASSWORD   REQUIRED. sa password.
#   RESTORE_DBS   auto | 0  -- "0" disables the restore pass entirely.
#
# The backup dir is mounted, NOT copied: this image ships no DB content.

set -eo pipefail

: "${SA_PASSWORD:?SA_PASSWORD not set. Pass it with: -e SA_PASSWORD=YourStrongPassword1}"
: "${RESTORE_DBS:=auto}"

BACKUP_DIR="/var/opt/mssql/backup"
DATA_DIR="/var/opt/mssql/data"
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
[ -x "${SQLCMD}" ] || SQLCMD="/opt/mssql-tools/bin/sqlcmd"

# Make sure mssql user can read the bind-mounted backup files (host UIDs vary).
chmod -R a+r "${BACKUP_DIR}" 2>/dev/null || true

echo "Starting SQL Server..."
/opt/mssql/bin/sqlservr &
SQL_PID=$!

echo "Waiting for SQL Server to accept connections..."
SQL_READY=0
for i in $(seq 1 60); do
    if "${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -Q "SELECT 1" > /dev/null 2>&1; then
        echo "SQL Server is ready (${i}s)."
        SQL_READY=1
        break
    fi
    sleep 1
done

if [ "${SQL_READY}" -ne 1 ]; then
    echo "ERROR: SQL Server did not become ready after 60s."
    kill "${SQL_PID}" 2>/dev/null || true
    exit 1
fi

# Enable remote TCP (sqlservr listens on 0.0.0.0:1433 by default; this just
# flips the legacy sp_configure flag some Fiesta exes still check).
"${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C \
    -Q "EXEC sp_configure 'remote access', 1; RECONFIGURE;" > /dev/null 2>&1 || true

if [ "${RESTORE_DBS}" = "0" ]; then
    echo "RESTORE_DBS=0 -- skipping restore pass."
else
    if [ ! -d "${BACKUP_DIR}" ]; then
        echo "WARN: backup dir ${BACKUP_DIR} does not exist -- nothing to restore."
    else
        # Discover *.bak in the mounted backup dir. DB name = filename stem.
        # No hardcoded list -- if you drop more .bak files in, they restore on
        # next container start (assuming the DB isn't already on the volume).
        shopt -s nullglob
        BAKS=( "${BACKUP_DIR}"/*.bak "${BACKUP_DIR}"/*.BAK )
        shopt -u nullglob

        if [ "${#BAKS[@]}" -eq 0 ]; then
            echo "No *.bak files in ${BACKUP_DIR} -- nothing to restore."
        fi

        for BAK in "${BAKS[@]}"; do
            DB="$(basename "${BAK}")"
            DB="${DB%.*}"   # strip .bak / .BAK

            # Skip if already registered (volume persisted from a previous run).
            DB_COUNT=$("${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -h -1 -W \
                -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'${DB}'" \
                2>/dev/null | tr -d '[:space:]')

            if [ "${DB_COUNT}" = "1" ]; then
                echo "Database '${DB}' already exists -- skipping restore."
                continue
            fi

            echo "Restoring '${DB}' from ${BAK}..."

            # Build MOVE clause from FILELISTONLY so the logical names land in
            # ${DATA_DIR}/<DB>.mdf (+ <DB>_log.ldf, plus suffixed extras).
            MOVE_CLAUSE=""
            DATA_IDX=0
            LOG_IDX=0
            while IFS='|' read -r logical_name _physical_name type _rest; do
                logical_name="${logical_name// /}"
                type="${type// /}"
                case "${type}" in
                    D)
                        SUFFIX=$( [ "${DATA_IDX}" -eq 0 ] && echo "" || echo "_${DATA_IDX}" )
                        MOVE_CLAUSE+="MOVE '${logical_name}' TO '${DATA_DIR}/${DB}${SUFFIX}.mdf', "
                        DATA_IDX=$((DATA_IDX + 1))
                        ;;
                    L)
                        SUFFIX=$( [ "${LOG_IDX}" -eq 0 ] && echo "" || echo "_${LOG_IDX}" )
                        MOVE_CLAUSE+="MOVE '${logical_name}' TO '${DATA_DIR}/${DB}${SUFFIX}_log.ldf', "
                        LOG_IDX=$((LOG_IDX + 1))
                        ;;
                esac
            done < <("${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -s "|" -h -1 -W \
                -Q "RESTORE FILELISTONLY FROM DISK = '${BAK}'" 2>/dev/null)

            MOVE_CLAUSE="${MOVE_CLAUSE%, }"

            if [ -n "${MOVE_CLAUSE}" ]; then
                RESTORE_SQL="RESTORE DATABASE [${DB}] FROM DISK = '${BAK}' WITH ${MOVE_CLAUSE}"
            else
                RESTORE_SQL="RESTORE DATABASE [${DB}] FROM DISK = '${BAK}'"
            fi

            if "${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -Q "${RESTORE_SQL}"; then
                echo "Database '${DB}' restored."
            else
                echo "WARN: restore failed for '${DB}'."
            fi
        done
    fi
fi

echo "SQL Server setup complete."

# Hand off to the foreground sqlservr.
wait "${SQL_PID}"
