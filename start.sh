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
PROCESS_DIR="${FIESTA_PATH}/${PROCESS_REL_DIR}"
EXE_PATH="${PROCESS_DIR}/${PROCESS_EXE}"
DIRNAME="$(basename "${PROCESS_REL_DIR}")"

: "${SERVICE_NAME:=_${DIRNAME}}"

if [ ! -d "${FIESTA_PATH}" ]; then
    echo "ERROR: FIESTA_PATH (${FIESTA_PATH}) is not a directory."
    echo "  Mount your server folder, e.g.: -v /host/fiesta-server:${FIESTA_PATH}"
    exit 1
fi

if [ ! -f "${EXE_PATH}" ]; then
    echo "ERROR: exe not found: ${EXE_PATH}"
    echo "  FIESTA_PATH = ${FIESTA_PATH}"
    echo "  FIESTA_EXE  = ${FIESTA_EXE}"
    echo "  Directory listing:"
    ls -la "${FIESTA_PATH}" 2>/dev/null | sed 's/^/    /'
    exit 1
fi

echo "=== Fiesta runtime (Linux/Wine) ==="
echo "  Server folder : ${FIESTA_PATH}"
echo "  Process dir   : ${PROCESS_DIR}"
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

# Collect set of absolute paths #include'd by *.txt files in a directory.
collect_includes() {
    local cfg_dir="$1"
    local f rel d
    {
        while IFS= read -r -d '' f; do
            d="$(dirname "$f")"
            grep -hE '^[[:space:]]*#include[[:space:]]+"[^"]+"' "$f" 2>/dev/null \
                | sed -E 's/^[[:space:]]*#include[[:space:]]+"([^"]+)".*/\1/' \
                | while IFS= read -r rel; do
                    rel="${rel//\\//}"
                    case "${rel}" in
                        /*) echo "${rel}" ;;
                        *)  ( cd "${d}" 2>/dev/null && readlink -f "${rel}" 2>/dev/null ) ;;
                    esac
                done
        done < <(find "${cfg_dir}" -maxdepth 1 -type f -name '*.txt' -print0)
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

# --- Step 2: Registry keys required by Fiesta exes ---
# Fantasy/GBO keys are baked into the exes' license/anti-tamper checks.
echo "Setting up registry keys..."
WINEDEBUG=-all wine reg add 'HKCU\Software\Wine\DllOverrides' /v odbc32 /t REG_SZ /d builtin /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\Fantasy' /ve /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\Fantasy\Fighter' /v Bird   /d Eagle      /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\Fantasy\Fighter' /v Insect /d Honet      /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Desert   /d 138127     /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Mountain /d 30324      /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Natural  /d 126810443  /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Ocean    /d 7241589632 /f 2>/dev/null
WINEDEBUG=-all wine reg add 'HKLM\Software\Wow6432Node\GBO' /v Sabana   /d 2554545953 /f 2>/dev/null

# Warm up Wine's SCM -- first invocation is slow and can race with sc.exe create.
WINEDEBUG=-all wine sc.exe query type= service state= all 2>/dev/null || true

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
    GAMIGOZR_EXE="${FIESTA_PATH}/${GAMIGOZR_DIR}/GamigoZR.exe"
    if [ -f "${GAMIGOZR_EXE}" ]; then
        WIN_GAMIGOZR="Z:${GAMIGOZR_EXE//\//\\}"
        echo "Registering GamigoZR service..."
        WINEDEBUG=-all wine sc.exe delete GamigoZR 2>/dev/null || true
        WINEDEBUG=-all wine sc.exe create GamigoZR binPath= "${WIN_GAMIGOZR}" start= demand 2>/dev/null || true
        WINEDEBUG=-all wine sc.exe start  GamigoZR 2>/dev/null || true
        echo "  GamigoZR -> ${WIN_GAMIGOZR}"
    else
        echo "WARN: GamigoZR.exe not found at ${GAMIGOZR_EXE}"
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
BIN_PATH="cmd /c ${WIN_EXE} > ${WIN_STDOUT} 2>&1"

echo "Registering service: ${SERVICE_NAME} -> ${WIN_EXE}"
WINEDEBUG=-all wine sc.exe delete "${SERVICE_NAME}" 2>/dev/null || true
WINEDEBUG=-all wine sc.exe create "${SERVICE_NAME}" \
    binPath= "${BIN_PATH}" start= demand 2>/dev/null || true

echo "Starting service: ${SERVICE_NAME}"
WINEDEBUG=-all wine sc.exe start "${SERVICE_NAME}" 2>/dev/null || true

# Wine's SCM lies about service state -- poll for the actual process instead.
echo "Waiting for ${PROCESS_EXE} to appear..."
STARTED=0
for i in $(seq 1 30); do
    if pgrep -f "${PROCESS_EXE}" > /dev/null 2>&1; then
        echo "${PROCESS_EXE} is running (PID: $(pgrep -f "${PROCESS_EXE}" | head -1))."
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
    while pgrep -f "${PROCESS_EXE}" > /dev/null 2>&1; do
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
while pgrep -f "${PROCESS_EXE}" > /dev/null 2>&1; do
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
