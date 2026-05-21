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
: "${IS_ZONE:=auto}"
: "${CRYPT_BLOB_PATH:=/etc/gamigozr/response.txt}"
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

# Also pull (type, world, zone) -- the 3 integers after the two service-
# name strings on the MY_SERVER line. Each SERVER_INFO row in
# ServerInfo.txt has the same triple in positions 2-4 after its label;
# we use that to match "own" rows vs "others'" rows for the PUBLIC_IP
# rewrite below. Config-driven, no hardcoded service->label table.
MY_TYPE=""; MY_WORLD=""; MY_ZONE=""
MY_TRIPLE=$(find "${SOURCE_DIR}" -maxdepth 3 -type f -name '*.txt' \
    -exec grep -hE '^[[:space:]]*MY_SERVER[[:space:]]+"' {} + 2>/dev/null \
    | head -1 \
    | sed -nE 's/^[[:space:]]*MY_SERVER[[:space:]]+"[^"]+"[[:space:]]*,[[:space:]]*"[^"]+"[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+).*/\1 \2 \3/p') || true
if [ -n "${MY_TRIPLE}" ]; then
    read -r MY_TYPE MY_WORLD MY_ZONE <<< "${MY_TRIPLE}"
    echo "  MY_SERVER triple: type=${MY_TYPE} world=${MY_WORLD} zone=${MY_ZONE}"
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
# Re-seed on EVERY start (not just when empty). ServerInfo.txt's
# SERVER_INFO rows have docker hostnames in the IP column ("login",
# "worldmanager", "sqlserver", ...); start.sh's rewrite below resolves
# them to container IPs and writes the IPs back. On a container
# restart docker can assign a new IP, but the overlay still has the
# OLD IP from the previous run -- the exe then tries to bind an IP
# that isn't its own and Listen_Add fails. Always re-seeding from the
# hostname template guarantees a clean slate for the rewrite step.
if [ -d "${OVERLAY_DIR}" ] && [ -d "${SERVERINFO_SEED_DIR}" ]; then
    echo "Re-seeding ${OVERLAY_DIR} <- ${SERVERINFO_SEED_DIR}"
    rm -rf "${OVERLAY_DIR:?}"/* 2>/dev/null || true
    cp -r "${SERVERINFO_SEED_DIR}/." "${OVERLAY_DIR}/"
elif [ -d "${OVERLAY_DIR}" ] && [ -z "$(ls -A "${OVERLAY_DIR}" 2>/dev/null)" ]; then
    echo "WARN: ${OVERLAY_DIR} is empty and ${SERVERINFO_SEED_DIR} is not"
    echo "      mounted -- the per-process config #include will fail at"
    echo "      exe startup. Either pre-populate the overlay or mount the"
    echo "      source ServerInfo at ${SERVERINFO_SEED_DIR}."
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

# Fiesta hardcodes a type->service-name mapping in its exes. We mirror it
# so per-service overrides can be declared as env vars keyed by name
# (with world/zone suffixes when relevant). Env var conventions:
#   INTERNAL_HOST_<name>   docker service name for s2s (LOCALHOST rows).
#                           If unset, fall back to the source row's IP
#                           column (still DNS-resolved).
#   EXTERNAL_HOST_<name>   public-facing host for the proxy/operator.
#                           Used in id=20 rows of OTHER services'
#                           overlays. Falls back to $PUBLIC_IP.
#   EXTERNAL_PORT_<name>   public-facing port (proxy listen). Falls back
#                           to the source row's port.
fiesta_service_name() {
    local t="$1" w="$2" z="$3"
    case "$t" in
        0) echo "Account" ;;
        1) echo "AccountLog" ;;
        2) echo "Character_${w}" ;;
        3) echo "GameLog_${w}" ;;
        4) echo "Login" ;;
        5) echo "WorldManager_${w}" ;;
        6) echo "Zone_${w}_${z}" ;;
        *) echo "Type${t}_${w}_${z}" ;;
    esac
}

resolve_hostname_or_empty() {
    # Echo a resolved IPv4 if the arg is a hostname that resolves to one,
    # else echo empty. If the arg is already an IPv4, also echo empty
    # (caller can detect "no rewrite needed").
    #
    # Retries with a short timeout. Reason: WM and Zone each rewrite their
    # ServerInfo at startup with sibling hostnames -> IPs, and WM string-
    # compares the configured "IP" against the incoming peer's source address.
    # If the rewrite runs while a peer is still scheduling (docker DNS not yet
    # registered for it), the fallback to literal hostname leaves WM rejecting
    # the peer's later connection. Docker DNS usually settles in <2s so this
    # loop converges fast. TODO: replace with fixed container IPs on a static
    # network OR an s2s-aware proxy that lets binaries dial logical names.
    local name="$1"
    local timeout_seconds="${2:-30}"
    [ -z "$name" ] && return 0
    if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    fi
    local deadline=$(( $(date +%s) + timeout_seconds ))
    local attempt=0
    local ip=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        attempt=$((attempt + 1))
        ip=$(getent hosts "$name" 2>/dev/null | awk '{print $1; exit}')
        if [ -n "$ip" ]; then
            [ "$attempt" -gt 1 ] && echo "  resolved $name -> $ip after $attempt attempts" >&2
            echo "$ip"
            return 0
        fi
        sleep 0.5
    done
    echo "  WARN: $name did not resolve within ${timeout_seconds}s; falling back to literal" >&2
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

    local line row_type row_world row_zone row_id row_port ip_field port_sep prefix suffix
    local new_ip new_port resolved svc_name var_name ext_host ext_port int_host host_to_resolve
    while IFS= read -r line || [ -n "${line}" ]; do
        if [[ "${line}" =~ ^[[:space:]]*SERVER_INFO[[:space:]] ]]; then
            # Capture prefix / type / world / zone / idKind / IP / port-sep / port / suffix.
            #   SERVER_INFO "label", type, world, zone, idKind, "ip", port, ...
            if [[ "${line}" =~ ^([[:space:]]*SERVER_INFO[[:space:]]+\"[^\"]+\"[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*)\"([^\"]+)\"([[:space:]]*,[[:space:]]*)([0-9]+)(.*)$ ]]; then
                prefix="${BASH_REMATCH[1]}"
                row_type="${BASH_REMATCH[2]}"
                row_world="${BASH_REMATCH[3]}"
                row_zone="${BASH_REMATCH[4]}"
                row_id="${BASH_REMATCH[5]}"
                ip_field="${BASH_REMATCH[6]}"
                port_sep="${BASH_REMATCH[7]}"
                row_port="${BASH_REMATCH[8]}"
                suffix="${BASH_REMATCH[9]}"
                new_ip="${ip_field}"
                new_port="${row_port}"

                local is_own=0 is_public=0
                if [ -n "${MY_TYPE}" ] \
                   && [ "${row_type}" = "${MY_TYPE}" ] \
                   && [ "${row_world}" = "${MY_WORLD}" ] \
                   && [ "${row_zone}" = "${MY_ZONE}" ]; then is_own=1; fi
                if [ "${row_id}" = "20" ]; then is_public=1; fi

                svc_name="$(fiesta_service_name "${row_type}" "${row_world}" "${row_zone}")"

                if [ "${is_own}" -eq 1 ] && [ "${is_public}" -eq 1 ]; then
                    # Own client-facing row: bind 0.0.0.0; port unchanged.
                    new_ip="0.0.0.0"
                elif [ "${is_own}" -ne 1 ] && [ "${is_public}" -eq 1 ]; then
                    # Other service's client-facing row: ADVERTISE the
                    # operator's external endpoint. Per-service env var
                    # if set; else PUBLIC_IP for host, source port for
                    # port (proxy listens on the same port internally).
                    var_name="EXTERNAL_HOST_${svc_name}"
                    ext_host="${!var_name:-}"
                    if [ -n "${ext_host}" ]; then new_ip="${ext_host}"
                    else new_ip="${PUBLIC_IP}"
                    fi
                    var_name="EXTERNAL_PORT_${svc_name}"
                    ext_port="${!var_name:-}"
                    if [ -n "${ext_port}" ]; then new_port="${ext_port}"; fi
                else
                    # LOCALHOST-tagged (s2s/OPTOOL). Prefer per-service
                    # INTERNAL_HOST env (docker service name); fall back
                    # to the source row's hostname. Resolve via DNS.
                    var_name="INTERNAL_HOST_${svc_name}"
                    int_host="${!var_name:-}"
                    host_to_resolve="${int_host:-${ip_field}}"
                    resolved="$(resolve_hostname_or_empty "${host_to_resolve}")"
                    if [ -n "${resolved}" ]; then new_ip="${resolved}"
                    elif [ -n "${int_host}" ]; then new_ip="${int_host}"
                    fi
                fi

                if [ "${new_ip}" != "${ip_field}" ] || [ "${new_port}" != "${row_port}" ]; then
                    line="${prefix}\"${new_ip}\"${port_sep}${new_port}${suffix}"
                    changed=1
                fi
            fi
        elif [[ "${line}" == *ODBC_INFO* ]]; then
            if [[ "${line}" == *"SERVER=.\\SQLEXPRESS"* ]]; then
                line="${line//SERVER=.\\SQLEXPRESS/SERVER=${SQL_HOST},${SQL_PORT}}"
                changed=1
            fi
            # Also rewrite SERVER=127.0.0.1,<port> (literal-IP form) when
            # the operator set SQL_HOST to a different host (sibling
            # container under docker DNS, etc.). Idempotent: if SQL_HOST
            # defaults to 127.0.0.1, the substitution is a no-op.
            if [[ "${line}" =~ SERVER=127\.0\.0\.1,[0-9]+ ]]; then
                line=$(echo "${line}" | sed -E "s|SERVER=127\.0\.0\.1,[0-9]+|SERVER=${SQL_HOST},${SQL_PORT}|")
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

# PUBLIC_IP must be set to the operator's WAN IP (the address external
# clients reach the server via -- a proxy/port-forward then delivers to
# the right container). It is purely an ADVERTISE value: written into
# other services' client-facing SERVER_INFO rows so Login can tell the
# client "now connect to WM/Zone at THIS IP". Containers don't bind to
# PUBLIC_IP. Auto-detecting from a bridge-networked container would
# pick the docker subnet IP, useless for external clients -- so we fail
# loudly if it's missing.
if [ -z "${PUBLIC_IP:-}" ]; then
    echo "ERROR: PUBLIC_IP env is required. Set it to your server's WAN/public IP" >&2
    echo "       (e.g. PUBLIC_IP=12.34.56.78). It's advertised to clients via" >&2
    echo "       SERVER_INFO rows; containers don't connect to it themselves." >&2
    exit 1
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

# --- In-container GamigoZR HTTP stub (zones, no separate container) ---
# IS_ZONE = 1 | 0 | auto. `auto` triggers on Zone.exe. When on AND
# ${CRYPT_BLOB_PATH} exists, launch nginx serving the operator-mounted
# crypt blob on 127.0.0.1:58492. Mirrors start.ps1's HttpListener stub
# so the same compose works on both engines without a sibling gamigozr
# container (which wouldn't be reachable at 127.0.0.1 from another
# container anyway).
is_zone_active() {
    case "${IS_ZONE}" in
        1)    return 0 ;;
        0)    return 1 ;;
        auto) [ "${PROCESS_EXE}" = "Zone.exe" ] && return 0 || return 1 ;;
        *)    [ "${PROCESS_EXE}" = "Zone.exe" ] && return 0 || return 1 ;;
    esac
}

STUB_STARTED=0
if is_zone_active; then
    if [ -f "${CRYPT_BLOB_PATH}" ]; then
        mkdir -p /etc/gamigozr
        # Symlink the operator blob into the nginx-served location. The
        # baked /etc/nginx/conf.d/gamigozr-stub.conf serves
        # /etc/gamigozr/response.txt for every URL.
        if [ "$(readlink -f "${CRYPT_BLOB_PATH}" 2>/dev/null)" != "$(readlink -f /etc/gamigozr/response.txt 2>/dev/null)" ]; then
            ln -sf "${CRYPT_BLOB_PATH}" /etc/gamigozr/response.txt
        fi
        echo "Starting GamigoZR stub on 127.0.0.1:58492 (blob: ${CRYPT_BLOB_PATH})..."
        nginx -g 'daemon off;' &
        echo "  GamigoZR stub nginx pid: $!"
        STUB_STARTED=1
    else
        echo "WARN: IS_ZONE=true but CRYPT_BLOB_PATH (${CRYPT_BLOB_PATH}) not found;"
        echo "      will try the legacy Wine-hosted GamigoZR.exe path instead."
    fi
elif [ -n "${CRYPT_BLOB_PATH:-}" ] && [ -f "${CRYPT_BLOB_PATH}" ]; then
    echo "NOTE: CRYPT_BLOB_PATH is set but IS_ZONE is false; stub not started."
    echo "      That mount only matters for Zone containers."
fi

# Skip the legacy Wine-hosted GamigoZR.exe path if the in-container
# nginx stub is already serving 58492 -- they would race on the same
# port and one would silently fail.
if [ "${STUB_STARTED}" -ne 1 ] && should_start_gamigozr; then
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
