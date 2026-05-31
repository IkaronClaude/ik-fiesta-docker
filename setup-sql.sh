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

# Clear any stale readiness marker (container-local path, but be defensive).
# The docker HEALTHCHECK stays "unhealthy/starting" until this is re-created
# below, once restores are done -- see healthcheck-sql.sh.
READY_MARKER="/tmp/fiesta-sql-ready"
rm -f "${READY_MARKER}" 2>/dev/null || true

echo "Starting SQL Server..."
/opt/mssql/bin/sqlservr &
SQL_PID=$!

echo "Waiting for SQL Server to accept connections..."
# Plain-startup budget. NOT applied while SQL is in script upgrade mode --
# see below. Override with SQL_STARTUP_TIMEOUT (seconds).
STARTUP_TIMEOUT="${SQL_STARTUP_TIMEOUT:-120}"
SQL_READY=0
elapsed=0
while :; do
    # If sqlservr itself died, stop waiting -- there's nothing to wait for and
    # a fast exit lets `restart: on-failure` recycle the container.
    if ! kill -0 "${SQL_PID}" 2>/dev/null; then
        echo "ERROR: sqlservr exited during startup (pid ${SQL_PID} gone)."
        exit 1
    fi

    # Probe; capture output so a failure can be classified.
    if probe="$("${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -Q "SELECT 1" 2>&1)"; then
        echo "SQL Server is ready (${elapsed}s)."
        SQL_READY=1
        break
    fi

    # Script upgrade mode: after a CU/GDR base-image bump (or any time the
    # engine build is newer than the databases on the volume), SQL Server runs
    # upgrade scripts against master/msdb/model and the user DBs on startup.
    # While that runs it rejects EVERY login with error 18401 ("Server is in
    # script upgrade mode. Only administrator can connect at this time.") and
    # it can take many minutes. Killing it here corrupts the half-upgraded DBs
    # and restart-loops forever. So when we see that signal we keep waiting
    # with NO timeout -- the engine is alive and making progress.
    if printf '%s' "${probe}" | grep -qiE "script upgrade mode|upgrade script|error.*18401|18401"; then
        echo "SQL Server is in script upgrade mode (applying upgrade scripts); waiting -- timeout suspended (${elapsed}s elapsed)..."
        elapsed=0
        sleep 5
        continue
    fi

    elapsed=$((elapsed + 1))
    if [ "${elapsed}" -ge "${STARTUP_TIMEOUT}" ]; then
        echo "ERROR: SQL Server did not become ready after ${STARTUP_TIMEOUT}s (not in upgrade mode)."
        echo "  Last probe output: ${probe}"
        kill "${SQL_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

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

        # Why ATTACH-then-RESTORE instead of always-RESTORE: on a container
        # recycle the data files on the volume survive but master may not
        # (depends on whether the volume covers master's location). The old
        # logic issued RESTORE WITH REPLACE against the surviving .mdf/.ldf,
        # which CLOBBERED them with the .bak content and wiped every row the
        # operator added at runtime. New logic re-ATTACHes existing files
        # untouched; RESTORE only on genuine first boot. FORCE_RESTORE_DBS=1
        # overrides (re-imports from .bak even if files exist).
        FORCE_RESTORE="${FORCE_RESTORE_DBS:-0}"

        for BAK in "${BAKS[@]}"; do
            DB="$(basename "${BAK}")"
            DB="${DB%.*}"   # strip .bak / .BAK

            # Skip if already registered (multi-run idempotency within a boot).
            DB_COUNT=$("${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -h -1 -W \
                -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'${DB}'" \
                2>/dev/null | tr -d '[:space:]')

            if [ "${DB_COUNT}" = "1" ]; then
                echo "Database '${DB}' already registered -- skipping."
                continue
            fi

            # Map logical names -> on-disk paths from the .bak's file list.
            # Used for both ATTACH (locate existing files) and RESTORE (MOVE).
            EXPECTED_PATHS=()   # on-disk path per logical file, in order
            MOVE_CLAUSE=""
            DATA_IDX=0
            LOG_IDX=0
            while IFS='|' read -r logical_name _physical_name type _rest; do
                logical_name="${logical_name// /}"
                type="${type// /}"
                case "${type}" in
                    D)
                        SUFFIX=$( [ "${DATA_IDX}" -eq 0 ] && echo "" || echo "_${DATA_IDX}" )
                        P="${DATA_DIR}/${DB}${SUFFIX}.mdf"
                        EXPECTED_PATHS+=( "${P}" )
                        MOVE_CLAUSE+="MOVE '${logical_name}' TO '${P}', "
                        DATA_IDX=$((DATA_IDX + 1))
                        ;;
                    L)
                        SUFFIX=$( [ "${LOG_IDX}" -eq 0 ] && echo "" || echo "_${LOG_IDX}" )
                        P="${DATA_DIR}/${DB}${SUFFIX}_log.ldf"
                        EXPECTED_PATHS+=( "${P}" )
                        MOVE_CLAUSE+="MOVE '${logical_name}' TO '${P}', "
                        LOG_IDX=$((LOG_IDX + 1))
                        ;;
                esac
            done < <("${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C -s "|" -h -1 -W \
                -Q "RESTORE FILELISTONLY FROM DISK = '${BAK}'" 2>/dev/null)

            MOVE_CLAUSE="${MOVE_CLAUSE%, }"

            # All data files already present?
            ALL_PRESENT=1
            [ "${#EXPECTED_PATHS[@]}" -eq 0 ] && ALL_PRESENT=0
            for P in "${EXPECTED_PATHS[@]}"; do
                [ -f "${P}" ] || ALL_PRESENT=0
            done

            if [ "${ALL_PRESENT}" -eq 1 ] && [ "${FORCE_RESTORE}" != "1" ]; then
                ON_CLAUSE=""
                for P in "${EXPECTED_PATHS[@]}"; do
                    ON_CLAUSE+="(FILENAME = '${P}'), "
                done
                ON_CLAUSE="${ON_CLAUSE%, }"
                echo "Attaching '${DB}' from existing data files..."
                if "${SQLCMD}" -S localhost -U sa -P "${SA_PASSWORD}" -C \
                    -Q "CREATE DATABASE [${DB}] ON ${ON_CLAUSE} FOR ATTACH"; then
                    echo "Database '${DB}' attached."
                    continue
                fi
                echo "WARN: attach failed for '${DB}' -- falling back to RESTORE (clobbers data files)."
            fi

            echo "Restoring '${DB}' from ${BAK}..."
            if [ -n "${MOVE_CLAUSE}" ]; then
                RESTORE_SQL="RESTORE DATABASE [${DB}] FROM DISK = '${BAK}' WITH REPLACE, ${MOVE_CLAUSE}"
            else
                RESTORE_SQL="RESTORE DATABASE [${DB}] FROM DISK = '${BAK}' WITH REPLACE"
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

# Signal readiness to the docker HEALTHCHECK: restores/attaches are done and
# the server is fully serving. Until this exists the healthcheck fails, so
# `depends_on: condition: service_healthy` holds the DB-bridge containers.
touch "${READY_MARKER}"

# Hand off to the foreground sqlservr.
wait "${SQL_PID}"
