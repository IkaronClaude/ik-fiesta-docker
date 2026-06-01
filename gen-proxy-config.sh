#!/usr/bin/env bash
# gen-proxy-config.sh -- derive the fiesta-proxy config from a ServerInfo.txt.
#
# Reads one ServerInfo.txt (the full SERVER_INFO block) and emits the proxy
# configuration that example/{linux,windows}/docker-compose.yml and
# example/k8s/60-proxy.yaml otherwise hand-maintain:
#
#   * PROXY_ROUTES  -- one  listen:ServiceName:host:port[:opaque]  entry per
#                      client-facing SERVER_INFO row (FromServerType == 20,
#                      the rows tagged "; PUBLIC_IP"). Zone rows get :opaque,
#                      Login / WorldManager use the default rewrite mode.
#   * ports         -- the host port-publish list (PORT:PORT).
#   * INTERNAL_HOST -- the ServiceName -> docker/k8s hostname map consumed by
#                      the runtime containers (start.sh) for s2s rewriting.
#
# Service names match start.sh's fiesta_service_name() exactly. Host names are
# the lowercased compose service names (world-0 suffix dropped; zones become
# zone<world><zone>). Override the host domain for k8s with --host-suffix.
#
# Usage:
#   ./gen-proxy-config.sh --server-info path/to/ServerInfo.txt [options]
#
# Options:
#   --server-info PATH   ServerInfo.txt to read (required).
#   --public-ip IP       Advertised IP; echoed into the emitted env block.
#   --host-suffix STR    Appended to every host (e.g. .fiesta.svc.cluster.local).
#   --format FMT         compose (default) | env | k8s
#   -h, --help           This help.
set -euo pipefail

SERVER_INFO=""
PUBLIC_IP=""
HOST_SUFFIX=""
FORMAT="compose"

die() { echo "gen-proxy-config: $*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --server-info) SERVER_INFO="${2:-}"; shift 2 ;;
        --public-ip)   PUBLIC_IP="${2:-}";   shift 2 ;;
        --host-suffix) HOST_SUFFIX="${2:-}"; shift 2 ;;
        --format)      FORMAT="${2:-}";      shift 2 ;;
        -h|--help)     usage 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[ -n "${SERVER_INFO}" ] || die "--server-info is required (try --help)"
[ -f "${SERVER_INFO}" ] || die "no such file: ${SERVER_INFO}"
case "${FORMAT}" in compose|env|k8s) ;; *) die "unknown --format: ${FORMAT}" ;; esac

# ServiceName from (type, world, zone) -- mirrors start.sh fiesta_service_name().
service_name() {
    case "$1" in
        0) echo "Account" ;;
        1) echo "AccountLog" ;;
        2) echo "Character_$2" ;;
        3) echo "GameLog_$2" ;;
        4) echo "Login" ;;
        5) echo "WorldManager_$2" ;;
        6) echo "Zone_$2_$3" ;;
        *) echo "Unknown_$1_$2_$3" ;;
    esac
}

# Host (compose service name) from (type, world, zone). World-0 suffix is
# dropped for the singletons; zones become zone<world><zone>.
host_name() {
    local t="$1" w="$2" z="$3" base
    case "$t" in
        0) base="account" ;;
        1) base="accountlog" ;;
        2) base="character$([ "$w" != 0 ] && echo "$w")" ;;
        3) base="gamelog$([ "$w" != 0 ] && echo "$w")" ;;
        4) base="login" ;;
        5) base="worldmanager$([ "$w" != 0 ] && echo "$w")" ;;
        6) base="zone${w}${z}" ;;
        *) base="svc${t}_${w}_${z}" ;;
    esac
    printf '%s%s' "${base}" "${HOST_SUFFIX}"
}

# --- Parse SERVER_INFO rows -------------------------------------------------
routes=()          # listen:ServiceName:host:port[:opaque]
route_comments=()  # ServiceName, for the ports list
ports=()           # client-facing listen ports
ihost_names=()     # parallel arrays = ordered, de-duplicated INTERNAL_HOST map
ihost_hosts=()

in_define=0
row_re='^SERVER_INFO[[:space:]]+"[^"]+"[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*"[^"]+"[[:space:]]*,[[:space:]]*([0-9]+)'

while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[![:space:]]*}"}"   # ltrim
    case "${line}" in
        '#DEFINE'*|'#define'*)    in_define=1; continue ;;
        '#ENDDEFINE'*|'#enddefine'*) in_define=0; continue ;;
    esac
    [ "${in_define}" -eq 0 ] || continue
    [[ "${line}" =~ ^SERVER_INFO ]] || continue
    [[ "${line}" =~ $row_re ]] || continue

    type="${BASH_REMATCH[1]}"
    world="${BASH_REMATCH[2]}"
    zone="${BASH_REMATCH[3]}"
    fromtype="${BASH_REMATCH[4]}"
    port="${BASH_REMATCH[5]}"

    svc="$(service_name "${type}" "${world}" "${zone}")"
    host="$(host_name "${type}" "${world}" "${zone}")"

    # INTERNAL_HOST map: one entry per distinct service (rows repeat per peer).
    seen=0
    for n in "${ihost_names[@]:-}"; do [ "$n" = "${svc}" ] && { seen=1; break; }; done
    if [ "${seen}" -eq 0 ]; then
        ihost_names+=("${svc}"); ihost_hosts+=("${host}")
    fi

    # Client-facing rows (FromServerType == Client(20)) become proxy routes.
    if [ "${fromtype}" = "20" ]; then
        mode=""
        [ "${type}" = "6" ] && mode=":opaque"   # Zone channel: opaque byte pump
        routes+=("${port}:${svc}:${host}:${port}${mode}")
        route_comments+=("${svc}")
        ports+=("${port}")
    fi
done < "${SERVER_INFO}"

[ "${#routes[@]}" -gt 0 ] || die "no client-facing rows (FromServerType==20) found in ${SERVER_INFO}"

# --- Emit -------------------------------------------------------------------
join_semic() { local IFS=";"; echo "$*"; }

emit_env() {
    [ -n "${PUBLIC_IP}" ] && echo "PUBLIC_IP=${PUBLIC_IP}"
    echo "PROXY_ROUTES=$(join_semic "${routes[@]}")"
    for i in "${!ihost_names[@]}"; do
        echo "INTERNAL_HOST_${ihost_names[$i]}=${ihost_hosts[$i]}"
    done
}

emit_yaml() {
    local indent="$1"          # base indent for the env-block keys
    [ -n "${PUBLIC_IP}" ] && printf '%sPUBLIC_IP: "%s"\n' "${indent}" "${PUBLIC_IP}"
    printf '%sPROXY_ROUTES: >-\n' "${indent}"
    local last=$(( ${#routes[@]} - 1 ))
    for i in "${!routes[@]}"; do
        if [ "$i" -lt "${last}" ]; then
            printf '%s  %s;\n' "${indent}" "${routes[$i]}"
        else
            printf '%s  %s\n' "${indent}" "${routes[$i]}"
        fi
    done
    echo
    printf '%s# ports to publish:\n' "${indent}"
    for i in "${!ports[@]}"; do
        printf '%s- "%s:%s"   # %s\n' "${indent}" "${ports[$i]}" "${ports[$i]}" "${route_comments[$i]}"
    done
    echo
    printf '%s# INTERNAL_HOST map (set on the runtime containers):\n' "${indent}"
    for i in "${!ihost_names[@]}"; do
        printf '%sINTERNAL_HOST_%s: "%s"\n' "${indent}" "${ihost_names[$i]}" "${ihost_hosts[$i]}"
    done
}

case "${FORMAT}" in
    env)     emit_env ;;
    compose) emit_yaml "      " ;;
    k8s)     emit_yaml "            " ;;
esac
