#!/bin/sh
# Fiesta Online server runtime -- native x64 Linux entrypoint (the fiesta-decomp linux-2026 build; no Wine, no proxy).
#
# Bring-your-own: the image holds no game files and no server binaries. Mount the server tree read-only at
# $FIESTA_PATH (default /fiesta: 9Data/, Zone00/, WorldManager/, ...) with the native Linux binary next to each
# Windows exe (Zone00/Zone beside Zone00/Zone.exe, Login/Login, Account/Account, ...) and, for zones,
# 9Data/Shine/LuaScript/ZoneBoot.lua (fiesta-decomp tools/zoneboot_extract.py).
#
#   FIESTA_EXE      the server, as the Windows exe path: "Zone00/Zone.exe", "WorldManager/WorldManager.exe", ...
#   FIESTA_PATH     the read-only server tree (default /fiesta)
#   FIESTA_WORK     the writable work tree (default /run/fiesta): the exe folder is copied here (logs land in it),
#                   9Data is linked entry by entry, ServerInfo is a rewritten copy
#   INTERNAL_HOST_<svc>  host name of each server for the server-to-server (LOCALHOST) rows, svc = Login,
#                   WorldManager_<w>, Zone_<w>_<z>, Account, AccountLog, Character_<w>, GameLog_<w>; the servers resolve
#                   the names themselves (no proxy)
#   PUBLIC_IP       if set, the address in the client-facing (PUBLIC_IP) rows
#   SQL_HOST / SQL_PORT / SA_PASSWORD   the ODBC connection (Microsoft ODBC Driver 18)
set -eu
: "${FIESTA_PATH:=/fiesta}"
: "${FIESTA_WORK:=/run/fiesta}"
: "${FIESTA_EXE:=${1:-}}"
[ -n "$FIESTA_EXE" ] || { echo "start-native: FIESTA_EXE is not set" >&2; exit 2; }
dir=${FIESTA_EXE%%/*}
exe=${FIESTA_EXE##*/}
exe=${exe%.exe}
[ -x "$FIESTA_PATH/$dir/$exe" ] || { echo "start-native: no Linux binary $FIESTA_PATH/$dir/$exe (BYO)" >&2; exit 2; }

# the work tree: ../9Data from the exe folder must resolve, ServerInfo must be our rewritten copy
mkdir -p "$FIESTA_WORK/9Data"
for e in "$FIESTA_PATH/9Data/"*; do
  n=${e##*/}
  [ "$n" = ServerInfo ] && continue
  ln -sfn "$e" "$FIESTA_WORK/9Data/$n"
done
rm -rf "$FIESTA_WORK/9Data/ServerInfo"
cp -r "$FIESTA_PATH/9Data/ServerInfo" "$FIESTA_WORK/9Data/ServerInfo"
rm -rf "${FIESTA_WORK:?}/$dir"
mkdir -p "$FIESTA_WORK/$dir"
# the exe folder's config and data (not old logs: they are rewritten anyway)
cp -r "$FIESTA_PATH/$dir/." "$FIESTA_WORK/$dir/"
# old logs that came with the folder: the container log follows this run's files only
( cd "$FIESTA_WORK/$dir" && rm -rf DebugMessage && rm -f Assert*.txt ExitLog*.txt Message.txt MapLoad.txt Size.txt \
    Dbg.txt *Log20*.txt *DumpStack*.txt *CallStack.txt KQLog*.txt )
mkdir -p "$FIESTA_WORK/$dir/DebugMessage"

# ServerInfo.txt: the LOCALHOST rows name the service, the PUBLIC_IP rows carry PUBLIC_IP
rewrite_serverinfo() {
  awk '
    function svc(row,   m) {
      if (row == "PG_Login") return "Login"
      if (row == "PG_AccDB") return "Account"
      if (row == "PG_ALDB") return "AccountLog"
      if (match(row, /^PG_W[0-9][0-9]_WM$/)) return "WorldManager_" (substr(row, 5, 2) + 0)
      if (match(row, /^PG_W[0-9][0-9]_CDB$/)) return "Character_" (substr(row, 5, 2) + 0)
      if (match(row, /^PG_W[0-9][0-9]_GLDB$/)) return "GameLog_" (substr(row, 5, 2) + 0)
      if (match(row, /^PG_W[0-9][0-9]_Z[0-9][0-9]$/)) return "Zone_" (substr(row, 5, 2) + 0) "_" (substr(row, 9, 2) + 0)
      return ""
    }
    /^SERVER_INFO/ {
      n = split($0, q, "\"")
      # q[2] = the row name, q[4] = the address
      host = ""
      if ($0 ~ /LOCALHOST/) { s = svc(q[2]); if (s != "") host = ENVIRON["INTERNAL_HOST_" s] }
      else if ($0 ~ /PUBLIC_IP/) host = ENVIRON["PUBLIC_IP"]
      if (host != "" && n >= 5) {
        out = q[1]
        for (i = 2; i <= n; i++) out = out "\"" ((i == 4) ? host : q[i])
        print out
        next
      }
    }
    { print }
  ' "$1" > "$1.new" && mv "$1.new" "$1"
}
rewrite_odbc() {
  sed -i -e 's/DRIVER={SQL Server};/DRIVER={ODBC Driver 18 for SQL Server};TrustServerCertificate=yes;/' "$1"
  if [ -n "${SQL_HOST:-}" ]; then
    sed -i -e "s/SERVER=[^;]*;/SERVER=${SQL_HOST},${SQL_PORT:-1433};/" "$1"
  fi
  if [ -n "${SA_PASSWORD:-}" ]; then
    pw=$(printf '%s' "$SA_PASSWORD" | sed -e 's/[\/&|]/\\&/g')
    sed -i -e "s|PWD=[^;\"]*|PWD=$pw|" "$1"
  fi
}
si="$FIESTA_WORK/9Data/ServerInfo/ServerInfo.txt"
rewrite_serverinfo "$si"
rewrite_odbc "$si"
for f in "$FIESTA_WORK/$dir/"*.txt; do
  [ -f "$f" ] && grep -q "DRIVER=" "$f" && rewrite_odbc "$f"
done

export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
cp "$FIESTA_PATH/$dir/$exe" "/tmp/$exe"
chmod +x "/tmp/$exe"
cd "$FIESTA_WORK/$dir"
echo "start-native: $FIESTA_EXE -> /tmp/$exe in $FIESTA_WORK/$dir"

# The servers log to files, not stdout: follow them into the container log (kubectl logs / Freelens), each line
# prefixed with its file. FIESTA_LOG_TAIL=0 turns it off. New files (the daily DebugMessage/Msg_<date>.txt, an
# Assert*.txt) are picked up as they appear.
log_files() {
  for f in DebugMessage/Msg_*.txt Message.txt Assert*.txt ExitLog*.txt; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}
follow_logs() {
  seen=" "
  while :; do
    for f in $(log_files); do
      case "$seen" in *" $f "*) continue ;; esac
      seen="$seen$f "
      tail -n +1 -F "$f" 2>/dev/null | sed -u "s|^|[$f] |" &
    done
    sleep 5
  done
}

"/tmp/$exe" &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
if [ "${FIESTA_LOG_TAIL:-1}" != 0 ]; then
  follow_logs &
  follower=$!
fi
rc=0
wait "$pid" || rc=$?
# a TERM wakes wait early: wait again for the server itself
while kill -0 "$pid" 2>/dev/null; do wait "$pid" || rc=$?; done
sleep 2
[ -n "${follower:-}" ] && kill "$follower" 2>/dev/null
# whatever the server wrote at its very end (an Assert / ExitLog just before exiting) reaches the log
for f in Assert*.txt ExitLog*.txt; do
  [ -f "$f" ] && sed "s|^|[$f at exit] |" "$f"
done
echo "start-native: $FIESTA_EXE exited ($rc)"
exit "$rc"
