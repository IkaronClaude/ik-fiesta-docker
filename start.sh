#!/bin/bash
# Fiesta Online server runtime -- Linux/Wine entrypoint.
#
# Contract (see Dockerfile.linux for env-var docs):
#   FIESTA_PATH       mount point of the user's server folder (default: /fiesta)
#   FIESTA_EXE        relative path to the exe, e.g. "Zone01/Zone.exe"
#                     If unset, the first positional arg is used.
#   PUBLIC_IP         if set, replaces the IP in SERVER_INFO rows whose trailing
#                     comment says "PUBLIC_IP" (clients use these rows)
#   SQL_HOST          SQL Server host        (default: 127.0.0.1, host networking)
#   SQL_PORT          SQL Server port        (default: 1433)
#   SA_PASSWORD       if set, replaces PWD= in ODBC_INFO rows
#   ODBC_DRIVER       ODBC driver name in DRIVER={...} (default: "SQL Server")
#   START_GAMIGOZR    auto | 1 | 0           (default: auto -- on for Zone.exe)
#   GAMIGOZR_DIR      subdir under FIESTA_PATH (default: GamigoZR)
#   SERVICE_NAME      override Wine SCM service name (default: _<dirname>)
#   KEEP_ALIVE        1 -> keep container alive after process exits

set -eo pipefail

: "${FIESTA_PATH:=/fiesta}"
: "${START_GAMIGOZR:=auto}"
: "${GAMIGOZR_DIR:=GamigoZR}"
: "${KEEP_ALIVE:=0}"
: "${SQL_HOST:=127.0.0.1}"
: "${SQL_PORT:=1433}"
: "${ODBC_DRIVER:=SQL Server}"

# Accept FIESTA_EXE from env var OR first positional arg.
if [ -z "${FIESTA_EXE:-}" ] && [ -n "${1:-}" ]; then
    FIESTA_EXE="$1"
fi
if [ -z "${FIESTA_EXE:-}" ]; then
    echo "ERROR: no exe specified."
    echo "  Pass it as the trailing arg, e.g.:"
    echo "    docker run fiesta-server-runtime Login/Login.exe"
    echo "  or as an env var: -e FIESTA_EXE=Login/Login.exe"
    exit 1
fi

# Normalise: accept "Zone01\Zone.exe" (Windows-style) too.
FIESTA_EXE="${FIESTA_EXE//\\//}"

PROCESS_REL_DIR="$(dirname "${FIESTA_EXE}")"
PROCESS_EXE="$(basename "${FIESTA_EXE}")"
SOURCE_DIR="${FIESTA_PATH}/${PROCESS_REL_DIR}"
SOURCE_EXE="${SOURCE_DIR}/${PROCESS_EXE}"
DIRNAME="$(basename "${PROCESS_REL_DIR}")"

# SERVICE_NAME is set after SOURCE_DIR is validated below, so we can read
# the exe's expected name out of its per-process *ServerInfo.txt. See the
# `Discover SERVICE_NAME` block after the validation.

if [ ! -d "${FIESTA_PATH}" ]; then
    echo "ERROR: FIESTA_PATH (${FIESTA_PATH}) is not a directory."
    echo "  Mount your server folder, e.g.: -v /host/fiesta-server:${FIESTA_PATH}"
    exit 1
fi

if [ ! -f "${SOURCE_EXE}" ]; then
    echo "ERROR: exe not found: ${SOURCE_EXE}"
    echo "  FIESTA_PATH = ${FIESTA_PATH}"
    echo "  FIESTA_EXE  = ${FIESTA_EXE}"
    echo "  Directory listing:"
    ls -la "${FIESTA_PATH}" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

# --- Discover SERVICE_NAME ---
# Every Fiesta exe embeds its expected SCM service name in a per-process
# *ServerInfo.txt with a line like:
#     MY_SERVER "_Zone1",   "_Zone1",  6, 0, 1
# The first quoted string is the service name the exe will look up in
# HKLM\System\CurrentControlSet\Services to decide whether it's running
# under SCM. If sc.exe registered it under any other name (e.g. _Zone01
# instead of _Zone1) the exe falls into a "service upload only" path:
# self-registers the expected name in the wine registry, exits, and only
# the next container start finds the registration and proceeds as a game
# server. Reading the embedded name and matching it skips that cycle.
#
# Layout varies: Zones nest it under ZoneServerInfo/ZoneServerInfo.txt,
# Login/WorldManager/Account-family put it next to the exe. -maxdepth 3
# covers both without descending into log trees. Operator-supplied
# SERVICE_NAME (env) always wins; _<dirname> is the fallback for exes
# that don't ship a MY_SERVER line (e.g. GamigoZR).
if [ -z "${SERVICE_NAME:-}" ]; then
    # `|| true` at the end is load-bearing: when no *.txt has a MY_SERVER
    # line (e.g. GamigoZR -- it's a .NET HTTP service, not a Fiesta game-
    # server exe), grep exits 1, `find -exec ... +` propagates that, and
    # under `set -eo pipefail` the parent shell aborts before printing a
    # single line. The `|| true` swallows the empty-match case so we fall
    # through to the `_<dirname>` default.
    DISCOVERED_NAME=$(find "${SOURCE_DIR}" -maxdepth 3 -type f -name '*.txt' \
        -exec grep -hE '^[[:space:]]*MY_SERVER[[:space:]]+"' {} + 2>/dev/null \
        | head -1 \
        | sed -nE 's/^[[:space:]]*MY_SERVER[[:space:]]+"([^"]+)".*/\1/p') || true
    if [ -n "${DISCOVERED_NAME}" ]; then
        SERVICE_NAME="${DISCOVERED_NAME}"
        echo "  SERVICE_NAME discovered from MY_SERVER: ${SERVICE_NAME}"
    else
        SERVICE_NAME="_${DIRNAME}"
        echo "  SERVICE_NAME fallback (no MY_SERVER in *.txt): ${SERVICE_NAME}"
    fi
fi

# --- Auto-seed per-container ServerInfo overlay ---
# Each container expects ${FIESTA_PATH}/9Data/ServerInfo to be a
# WRITABLE per-container copy so the config-rewrite step below can
# substitute PUBLIC_IP / SA_PASSWORD / ODBC strings per process without
# races between containers sharing the same source mount.
#
# In docker-compose this used to be done by a one-shot `init` service
# (alpine + cp). We do it here so each container is self-contained --
# no orchestration init step required. Kubernetes friendly: a single
# pod with two volumes (read-only source + emptyDir for the overlay)
# bootstraps itself with no initContainer.
#
# Convention: if ${SERVERINFO_SEED_DIR} (default /source/9Data/ServerInfo)
# is a directory and the overlay is empty, copy its contents in.
# Operator-side: add a second read-only mount of the source folder, e.g.
#   -v ${FIESTA_SERVER}:/source:ro
# If neither overlay nor seed dir is set up, we skip silently -- legacy
# init-container workflow keeps working.
: "${SERVERINFO_SEED_DIR:=/source/9Data/ServerInfo}"
OVERLAY_DIR="${FIESTA_PATH}/9Data/ServerInfo"
if [ -d "${OVERLAY_DIR}" ] && [ -z "$(ls -A "${OVERLAY_DIR}" 2>/dev/null)" ]; then
    if [ -d "${SERVERINFO_SEED_DIR}" ]; then
        echo "Seeding ${OVERLAY_DIR} <- ${SERVERINFO_SEED_DIR}"
        cp -r "${SERVERINFO_SEED_DIR}/." "${OVERLAY_DIR}/"
    else
        echo "WARN: ${OVERLAY_DIR} is empty and ${SERVERINFO_SEED_DIR} is not"
        echo "      mounted -- the per-process config #include will fail at"
        echo "      exe startup. Either pre-populate the overlay or mount the"
        echo "      source ServerInfo at ${SERVERINFO_SEED_DIR}."
    fi
fi

# Wine can't mmap a PE file with PROT_EXEC over a Windows-host bind mount
# (Docker Desktop on Windows uses 9P/Plan-9 to back the mount, which doesn't
# honour exec). Symptom: every server exe page-faults at the first instruction.
# Workaround: copy the per-process directory into a container-local writable
# location (/server/...) and run from there. The included 9Data/ServerInfo
# overlay stays on the bind mount so per-container config rewrites still land
# where the operator can see them.
PROCESS_DIR="/server/${PROCESS_REL_DIR}"
EXE_PATH="${PROCESS_DIR}/${PROCESS_EXE}"
mkdir -p "$(dirname "${PROCESS_DIR}")"
echo "Copying ${SOURCE_DIR}/ -> ${PROCESS_DIR}/ (bind-mount exec workaround)..."
rm -rf "${PROCESS_DIR}"
cp -a "${SOURCE_DIR}" "${PROCESS_DIR}"

# The exe resolves 9Data via relative paths like "../../9Data/...". With the
# process dir now under /server, link /server/9Data back to the bind mount so
# those paths still hit the operator's data (and the per-container ServerInfo
# overlay).
if [ -d "${FIESTA_PATH}/9Data" ] && [ ! -e /server/9Data ]; then
    ln -s "${FIESTA_PATH}/9Data" /server/9Data
fi

echo "=== Fiesta runtime (Linux/Wine) ==="
echo "  Server folder : ${FIESTA_PATH}"
echo "  Process dir   : ${PROCESS_DIR}  (local copy of ${SOURCE_DIR})"
echo "  Exe           : ${PROCESS_EXE}"
echo "  Service name  : ${SERVICE_NAME}"

# --- Auto-rewrite included config files ---
# The default ServerSource ServerInfo.txt hardcodes 127.0.0.1, .\SQLEXPRESS,
# and a known default SQL password. Walk the #include graph from the per-process
# config dir and rewrite the targets in place:
#   * SERVER_INFO rows whose trailing comment is "PUBLIC_IP" get their IP
#     replaced with $PUBLIC_IP (only if set). LOCALHOST rows stay 127.0.0.1.
#     Labels and ports are never touched.
#   * ODBC_INFO rows get .\SQLEXPRESS rewritten to ${SQL_HOST},${SQL_PORT},
#     PWD= rewritten to ${SA_PASSWORD} if set, and DRIVER={SQL Server} swapped
#     to DRIVER={${ODBC_DRIVER}} if a non-default driver name was given.
#
# Operators who don't want any rewriting: leave PUBLIC_IP and SA_PASSWORD unset
# and don't have .\SQLEXPRESS in their ODBC strings -- this script becomes a
# no-op for the config files.
#
# The included files must be writable. The standard pattern is to overlay-mount
# 9Data/ServerInfo/ as a per-container directory so the rewrite doesn't race
# with other containers reading/writing the same file -- see README.

# Collect set of absolute paths #include'd by *.txt files under cfg_dir.
# Recurses 3 levels deep: Zone processes keep their entry-point config in
# ZoneServerInfo/ZoneServerInfo.txt (one subdir down), which is what chains
# the include to 9Data/ServerInfo/ServerInfo.txt. maxdepth=3 covers that
# and any sibling cases without walking arbitrarily-deep log trees.
collect_includes() {
    local cfg_dir="$1"
    local f rel d
    {
        while IFS= read -r -d '' f; do
            d="$(dirname "$f")"
            # grep exits 1 when a file has no #include lines; pipefail would
            # then abort the script, so swallow it with `|| true`.
            { grep -hE '^[[:space:]]*#include[[:space:]]+"[^"]+"' "$f" 2>/dev/null || true; } \
                | sed -E 's/^[[:space:]]*#include[[:space:]]+"([^"]+)".*/\1/' \
                | while IFS= read -r rel; do
                    rel="${rel//\\//}"
                    case "${rel}" in
                        /*) echo "${rel}" ;;
                        *)  ( cd "${d}" 2>/dev/null && readlink -f "${rel}" 2>/dev/null ) ;;
                    esac
                done
        done < <(find "${cfg_dir}" -maxdepth 3 -type f -name '*.txt' -print0)
    } | sort -u
}

rewrite_config_file() {
    local file="$1"
    local tmp="${file}.tmp.$$"
    local changed=0

    if [ ! -w "${file}" ]; then
        echo "  ERROR: ${file} is not writable."
        echo "         Mount its parent dir as a per-container writable overlay, e.g.:"
        echo "           -v <host-dir>:$(dirname "${file}")"
        return 1
    fi

    local line is_public
    while IFS= read -r line || [ -n "${line}" ]; do
        if [[ "${line}" =~ ^[[:space:]]*SERVER_INFO[[:space:]] ]] && [ -n "${PUBLIC_IP:-}" ]; then
            # Trailing comment marker: "; PUBLIC_IP" (or LOCALHOST). Only rewrite
            # the IP field if the operator tagged this row as the client-facing one.
            is_public=0
            if [[ "${line}" == *";"*PUBLIC_IP* ]]; then is_public=1; fi
            if [ "${is_public}" -eq 1 ]; then
                # Replace the 2nd quoted string on the line (the IP field).
                if [[ "${line}" =~ ^([[:space:]]*SERVER_INFO[[:space:]]+\"[^\"]+\"[^\"]*)\"([^\"]+)\"(.*)$ ]]; then
                    if [ "${BASH_REMATCH[2]}" != "${PUBLIC_IP}" ]; then
                        line="${BASH_REMATCH[1]}\"${PUBLIC_IP}\"${BASH_REMATCH[3]}"
                        changed=1
                    fi
                fi
            fi
        elif [[ "${line}" == *ODBC_INFO* ]]; then
            if [[ "${line}" == *"SERVER=.\\SQLEXPRESS"* ]]; then
                line="${line//SERVER=.\\SQLEXPRESS/SERVER=${SQL_HOST},${SQL_PORT}}"
                changed=1
            fi
            if [ "${ODBC_DRIVER}" != "SQL Server" ] && [[ "${line}" == *"DRIVER={SQL Server}"* ]]; then
                line="${line//DRIVER=\{SQL Server\}/DRIVER=\{${ODBC_DRIVER}\}}"
                changed=1
            fi
            if [ -n "${SA_PASSWORD:-}" ]; then
                # Match PWD= followed by chars up to ; " whitespace.
                if [[ "${line}" =~ ^(.*PWD=)([^\;\"$' \t']+)(.*)$ ]]; then
                    if [ "${BASH_REMATCH[2]}" != "${SA_PASSWORD}" ]; then
                        line="${BASH_REMATCH[1]}${SA_PASSWORD}${BASH_REMATCH[3]}"
                        changed=1
                    fi
                fi
            fi
        fi
        printf '%s\n' "${line}"
    done < "${file}" > "${tmp}"

    if [ "${changed}" -eq 1 ]; then
        # Preserve CRLF line endings if the original had them.
        if head -c 4096 "${file}" | grep -q $'\r'; then
            sed -i 's/$/\r/' "${tmp}" 2>/dev/null || true
        fi
        mv "${tmp}" "${file}"
        echo "  rewrote: ${file}"
    else
        rm -f "${tmp}"
    fi
}

# Auto-detect PUBLIC_IP if unset. Fiesta servers bind() the IP they advertise
# in ServerInfo.txt, so whatever we write there has to be an IP that actually
# exists on a local interface inside this container -- otherwise bind fails
# with EADDRNOTAVAIL and the service never comes up. On a native Linux Docker
# host (or k8s), the default-route source IP is the host LAN IP, which is
# both bindable and what off-host clients use to reach us. Perfect.
#
# Docker Desktop on Mac/Windows is the awkward case: even with the "Host
# networking" toggle on, the container sees only Docker Desktop's internal
# Linux VM (eth0 = 192.168.65.0/24), NOT the Windows/Mac NIC. The only IP
# both bindable here and reachable from the host is 127.0.0.1 -- the toggle
# forwards localhost binds back to the host. Off-host LAN clients CAN'T
# reach the server in that setup; for a publicly-accessible deployment use
# a native Linux Docker / k8s host.
if [ -z "${PUBLIC_IP:-}" ]; then
    DETECTED_IP=""
    if command -v ip >/dev/null 2>&1; then
        DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    fi
    if [ -z "${DETECTED_IP}" ] && command -v hostname >/dev/null 2>&1; then
        DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [[ "${DETECTED_IP}" == 192.168.65.* ]]; then
        echo "  PUBLIC_IP auto-detect: container is on Docker Desktop's internal VM"
        echo "    subnet (${DETECTED_IP}). Off-host clients can't reach that IP; using"
        echo "    127.0.0.1 instead, which Docker Desktop's host-networking toggle"
        echo "    forwards back to the Mac/Windows host. For LAN-accessible servers,"
        echo "    deploy on native Linux Docker / k8s."
        DETECTED_IP="127.0.0.1"
    fi
    if [ -n "${DETECTED_IP}" ]; then
        PUBLIC_IP="${DETECTED_IP}"
        export PUBLIC_IP
        echo "  PUBLIC_IP auto-detected: ${PUBLIC_IP}"
    else
        echo "  PUBLIC_IP not set and auto-detect failed -- SERVER_INFO rows unchanged."
    fi
fi

echo "Walking config includes from ${PROCESS_DIR}..."
INCLUDES="$(collect_includes "${PROCESS_DIR}")"
if [ -n "${INCLUDES}" ]; then
    while IFS= read -r inc; do
        [ -z "${inc}" ] && continue
        if [ ! -f "${inc}" ]; then
            echo "  WARN: included file not found: ${inc}"
            continue
        fi
        rewrite_config_file "${inc}" || true
    done <<< "${INCLUDES}"
else
    echo "  (no #include directives found in ${PROCESS_DIR}/*.txt)"
fi

# Wine maps Z:\ to / -- translate the exe path to its Windows-style form.
WIN_EXE="Z:${EXE_PATH//\//\\}"

# --- Step 1: Xvfb (Wine needs an X display even for headless services) ---
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99 2>/dev/null || true
Xvfb :99 -screen 0 800x600x24 -nolisten tcp &
export DISPLAY=:99
sleep 1

# Kill any stale wineserver left over from a previous container start.
wineserver -k 2>/dev/null || true

# Honor caller-supplied WINEDEBUG (e.g. WINEDEBUG=+thread,+process for
# diagnostics), otherwise silence Wine. Exporting it once means wineserver
# and services.exe (spawned by the first `wine` call below) inherit it, and
# Zone.exe / Login.exe launched later via SCM inherit it too -- there's no
# other reliable way to attach debug channels to a service-hosted exe.
# Note: Wine 9.0 ignores WINEDEBUGLOG, and services.exe rewires service
# stdio to /dev/null, so WINEDEBUG output from service-hosted exes is
# effectively lost. Useful only for the initial `wine` / `wineserver`
# warmup calls above.
export WINEDEBUG="${WINEDEBUG:--all}"

# --- Step 2: Registry keys required by Fiesta exes ---
# Fantasy/GBO keys are baked into the exes' license/anti-tamper checks.
echo "Setting up registry keys..."
wine reg add 'HKCU\Software\Wine\DllOverrides' /v odbc32 /t REG_SZ /d builtin /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\Fantasy' /ve /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\Fantasy\Fighter' /v Bird   /d Eagle      /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\Fantasy\Fighter' /v Insect /d Honet      /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Desert   /d 138127     /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Mountain /d 30324      /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Natural  /d 126810443  /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Ocean    /d 7241589632 /f 2>/dev/null
wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Sabana   /d 2554545953 /f 2>/dev/null

# Warm up Wine's SCM -- first invocation spawns services.exe and is slow.
wine sc.exe query type= service state= all 2>/dev/null || true

# --- Step 3: Optionally start GamigoZR (anti-cheat) for Zone processes ---
should_start_gamigozr() {
    case "${START_GAMIGOZR}" in
        1)    return 0 ;;
        0)    return 1 ;;
        auto) [ "${PROCESS_EXE}" = "Zone.exe" ] && return 0 || return 1 ;;
        *)    echo "WARN: unknown START_GAMIGOZR='${START_GAMIGOZR}', treating as auto" >&2
              [ "${PROCESS_EXE}" = "Zone.exe" ] && return 0 || return 1 ;;
    esac
}

if should_start_gamigozr; then
    GAMIGOZR_SRC="${FIESTA_PATH}/${GAMIGOZR_DIR}/GamigoZR.exe"
    if [ -f "${GAMIGOZR_SRC}" ]; then
        # Same bind-mount-exec workaround: copy GamigoZR into /server/ before launch.
        GAMIGOZR_LOCAL_DIR="/server/${GAMIGOZR_DIR}"
        if [ ! -f "${GAMIGOZR_LOCAL_DIR}/GamigoZR.exe" ]; then
            mkdir -p "$(dirname "${GAMIGOZR_LOCAL_DIR}")"
            cp -a "${FIESTA_PATH}/${GAMIGOZR_DIR}" "${GAMIGOZR_LOCAL_DIR}"
        fi
        GAMIGOZR_EXE="${GAMIGOZR_LOCAL_DIR}/GamigoZR.exe"
        WIN_GAMIGOZR="Z:${GAMIGOZR_EXE//\//\\}"
        echo "Registering GamigoZR service..."
        wine sc.exe delete GamigoZR 2>/dev/null || true
        wine sc.exe create GamigoZR binPath= "${WIN_GAMIGOZR}" start= demand 2>/dev/null || true
        wine sc.exe start  GamigoZR 2>/dev/null || true
        echo "  GamigoZR -> ${WIN_GAMIGOZR}"
    else
        echo "WARN: GamigoZR.exe not found at ${GAMIGOZR_SRC}"
        echo "  Set START_GAMIGOZR=0 to skip, or GAMIGOZR_DIR=<your-dir> to override."
    fi
fi

# --- Step 4: Register and start the main service ---
# cmd /c wrapper: Wine's SCM will kill the service process if it takes too long
# to call StartServiceCtrlDispatcher(). Wrapping in cmd /c lets the exe run as
# a child of cmd, which satisfies SCM while the heavier init runs.
cd "${PROCESS_DIR}"
STDOUT_LOG="${PROCESS_DIR}/stdout.txt"
WIN_STDOUT="Z:${STDOUT_LOG//\//\\}"
# Unquoted form -- matches Mimir's working setup. Quoting the cmd /c
# argument was tried in earlier debug sessions and didn't help; sticking
# to the known-good form.
BIN_PATH="cmd /c ${WIN_EXE} > ${WIN_STDOUT} 2>&1"

echo "Registering service: ${SERVICE_NAME} -> ${WIN_EXE}"
wine sc.exe delete "${SERVICE_NAME}" 2>/dev/null || true
wine sc.exe create "${SERVICE_NAME}" \
    binPath= "${BIN_PATH}" start= demand 2>/dev/null || true

echo "Starting service: ${SERVICE_NAME}"
wine sc.exe start "${SERVICE_NAME}" 2>/dev/null || true

# Wine's SCM lies about service state -- poll for the actual cmd-wrapped
# process instead. Match against the full Wine path (Z:\server\...) so we
# don't false-positive on start.sh's own argv (which contains the exe name).
# pgrep -f uses ERE, so the literal backslashes need to be doubled.
PROC_MATCH="${WIN_EXE//\\/\\\\}"

# Find non-zombie PIDs whose cmdline matches PROC_MATCH. Zombies (state Z)
# linger after Wine kills a service process and would otherwise keep the
# container "alive" forever; strip them. Returns the live PIDs on stdout,
# exit 0 if any live, exit 1 if none.
live_service_pids() {
    local pid state out=""
    for pid in $(pgrep -f -- "${PROC_MATCH}" 2>/dev/null); do
        # /proc/<pid>/stat field 3 is the single-letter state.
        state=$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null)
        [ "${state}" = "Z" ] && continue   # zombie -- treat as dead
        [ -z "${state}" ] && continue      # disappeared between pgrep and stat
        out="${out} ${pid}"
    done
    [ -n "${out}" ] && echo "${out# }" && return 0
    return 1
}

echo "Waiting for ${PROCESS_EXE} to appear..."
STARTED=0
for i in $(seq 1 30); do
    if PIDS=$(live_service_pids); then
        echo "${PROCESS_EXE} is running (PID: ${PIDS%% *})."
        STARTED=1
        break
    fi
    sleep 1
done

if [ "${STARTED}" -ne 1 ]; then
    echo "ERROR: ${PROCESS_EXE} did not start within 30s."
    [ -f "${STDOUT_LOG}" ] && { echo "--- stdout.txt ---"; cat "${STDOUT_LOG}"; }
    if [ "${KEEP_ALIVE}" = "1" ]; then
        echo "KEEP_ALIVE=1: container staying alive for investigation."
        exec sleep infinity
    fi
    exit 1
fi

# --- Step 5: Tail any log files the exe writes ---
LOG_DIR="${PROCESS_DIR}/DebugMessage"
mkdir -p "${LOG_DIR}"
echo "Tailing logs in ${PROCESS_DIR} and ${LOG_DIR}..."

(
    declare -A SEEN
    while live_service_pids > /dev/null; do
        for f in \
            "${STDOUT_LOG}" \
            "${PROCESS_DIR}"/Assert*.txt \
            "${PROCESS_DIR}"/ExitLog*.txt \
            "${PROCESS_DIR}"/Msg_*.txt \
            "${PROCESS_DIR}"/Dbg.txt \
            "${PROCESS_DIR}"/MapLoad*.txt \
            "${PROCESS_DIR}"/Message*.txt \
            "${PROCESS_DIR}"/Size*.txt \
            "${PROCESS_DIR}"/*CallStack*.txt \
            "${PROCESS_DIR}"/5ZoneServer*.txt \
            "${LOG_DIR}"/*.txt
        do
            [ -f "$f" ] || continue
            if [ -z "${SEEN[$f]:-}" ]; then
                SEEN[$f]=1
                echo "  [+] tailing: $(basename "$f")"
                tail -F -n +1 "$f" 2>/dev/null | sed -u "s|^|[$(basename "$f" .txt)] |" &
            fi
        done
        sleep 5
    done
) &
TAIL_PID=$!

# --- Step 6: Wait for the process to die ---
# Use live_service_pids (matches the full Wine path Z:\server\...\X.exe and
# strips zombies), NOT a loose pgrep -f "${PROCESS_EXE}" -- the latter would
# also match start.sh's own argv (the exe name is $1) and never return false,
# leaving the container running forever after the service has already died.
while live_service_pids > /dev/null; do
    sleep 5
done

echo "=== ${PROCESS_EXE} exited ==="
sleep 2
kill "${TAIL_PID}" 2>/dev/null || true

if [ "${KEEP_ALIVE}" = "1" ]; then
    echo "KEEP_ALIVE=1: container staying alive."
    exec sleep infinity
fi
exit 1
