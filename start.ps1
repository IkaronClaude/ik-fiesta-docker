# Fiesta Online server runtime -- Windows entrypoint.
#
# Contract (see Dockerfile.windows for env-var docs):
#   FIESTA_PATH       mount point of the user's server folder (default: C:\fiesta)
#   FIESTA_EXE        relative path to the exe, e.g. "Zone01\Zone.exe"
#                     If unset, the first positional arg is used.
#   PUBLIC_IP         if set, replaces the IP in SERVER_INFO rows whose trailing
#                     comment says "PUBLIC_IP" (clients use these rows)
#   SQL_HOST          SQL Server host        (default: 127.0.0.1)
#   SQL_PORT          SQL Server port        (default: 1433)
#   SA_PASSWORD       if set, replaces PWD= in ODBC_INFO rows
#   ODBC_DRIVER       ODBC driver name in DRIVER={...}
#                     (default: "ODBC Driver 17 for SQL Server" -- installed in image)
#   START_GAMIGOZR    auto | 1 | 0           (default: auto -- on for Zone.exe)
#   GAMIGOZR_DIR      subdir under FIESTA_PATH (default: GamigoZR)
#   SERVICE_NAME      override service name (default: _<dirname>)
#   KEEP_ALIVE        1 -> keep container alive after process exits

$ErrorActionPreference = 'Continue'

$fiestaPath    = if ($env:FIESTA_PATH)    { $env:FIESTA_PATH }    else { 'C:\fiesta' }
$fiestaExe     = $env:FIESTA_EXE
$startGamigoZR = if ($env:START_GAMIGOZR) { $env:START_GAMIGOZR } else { 'auto' }
$gamigoZRDir   = if ($env:GAMIGOZR_DIR)   { $env:GAMIGOZR_DIR }   else { 'GamigoZR' }
$keepAlive     = $env:KEEP_ALIVE -eq '1'
$publicIp      = $env:PUBLIC_IP
$sqlHost       = if ($env:SQL_HOST)       { $env:SQL_HOST }       else { '127.0.0.1' }
$sqlPort       = if ($env:SQL_PORT)       { $env:SQL_PORT }       else { '1433' }
$saPassword    = $env:SA_PASSWORD
$odbcDriver    = if ($env:ODBC_DRIVER)    { $env:ODBC_DRIVER }    else { 'SQL Server' }

# --- S2S proxy mode ---
# Co-locates a FiestaProxy.dll (s2s mode) in the same container as the exe.
# All s2s peers become 127.0.0.1 from the exe's POV; the proxy fans out to
# the actual peer pods. Eliminates the boot-time DNS race (proxy resolves
# fresh per connect) and makes Fiesta's strict source-IP whitelist trivial
# (incoming peers always appear as 127.0.0.1, which matches the configured
# value). See fiesta-proxy/README.md for the proxy contract.
$s2sProxyDisabled  = $env:S2S_PROXY_DISABLED -eq '1'
$s2sInternalOffset = if ($env:S2S_INTERNAL_OFFSET) { [int]$env:S2S_INTERNAL_OFFSET } else { 10000 }
$s2sProxyDll       = if ($env:S2S_PROXY_DLL)       { $env:S2S_PROXY_DLL }
                     else                          { 'C:\fiesta-proxy\FiestaProxy.dll' }

# Operator-supplied override for the per-process ServerInfo discovery path.
# Auto-discovery is brittle: different exes bake different config layouts.
# When set, this path is used verbatim instead of walking $processDir.
$serverInfoOverride = $env:FIESTA_SERVERINFO_PATH

# Accumulators populated during Rewrite-ConfigFile and consumed when we
# launch the proxy below.
$script:s2sInbound  = @{}   # key "0.0.0.0:port" -> "0.0.0.0:port:127.0.0.1:internalPort"
$script:s2sOutbound = @{}   # key "127.0.0.1:port:host" -> "127.0.0.1:port:host:port"

# Fiesta hardcodes a type->service-name mapping in its exes. We mirror
# it here so per-service overrides can be declared as env vars keyed
# by that name (with world/zone suffixes when the service is per-world
# or per-zone). Matches the SERVER_INFO row's (type, world, zone)
# triple to a stable identifier the operator can target in compose.
#
# Env var conventions (any not set falls through to the defaults below):
#   INTERNAL_HOST_<name>   docker service name used for s2s (LOCALHOST
#                           rows). Resolved via DNS at startup. If unset,
#                           fall back to the IP column in the source
#                           ServerInfo.txt (current DNS-resolve behavior).
#   EXTERNAL_HOST_<name>   public-facing host for the proxy/operator
#                           routing this service. Used for id=20 rows in
#                           OTHER services' overlays. Falls back to
#                           $PUBLIC_IP if unset.
#   EXTERNAL_PORT_<name>   public-facing port (proxy listen). Falls back
#                           to the source row's port if unset.
function Get-FiestaServiceName {
    param([string]$type, [string]$world, [string]$zone)
    switch ($type) {
        '0' { return 'Account' }
        '1' { return 'AccountLog' }
        '2' { return "Character_$world" }
        '3' { return "GameLog_$world" }
        '4' { return 'Login' }
        '5' { return "WorldManager_$world" }
        '6' { return "Zone_${world}_${zone}" }
        default { return "Type${type}_${world}_${zone}" }
    }
}

# IS_ZONE / CRYPT_BLOB_PATH: when set, start.ps1 launches an in-process
# HTTP listener on 127.0.0.1:58492 serving the operator-mounted GamigoZR
# crypt blob. Eliminates the need for a separate gamigozr container --
# each zone serves its own via loopback, which is what Zone.exe expects.
# Without container-level host networking on Windows containers, a
# separate gamigozr container can't be reached at 127.0.0.1 anyway.
$isZoneRaw       = $env:IS_ZONE                                         # explicit override
$cryptBlobPath   = if ($env:CRYPT_BLOB_PATH) { $env:CRYPT_BLOB_PATH }
                   else                      { 'C:\gamigozr\response.txt' }

# Accept FIESTA_EXE from env var OR first positional arg.
if (-not $fiestaExe -and $args.Count -ge 1) {
    $fiestaExe = $args[0]
}
if (-not $fiestaExe) {
    Write-Error "No exe specified."
    Write-Host  "  Pass it as the trailing arg, e.g.:"
    Write-Host  "    docker run fiesta-server-runtime Login\Login.exe"
    Write-Host  "  or as an env var: -e FIESTA_EXE=Login\Login.exe"
    exit 1
}

# Normalise: accept "Zone01/Zone.exe" (POSIX-style) too.
$fiestaExe = $fiestaExe -replace '/', '\'

$processRelDir = Split-Path $fiestaExe -Parent
$processExe    = Split-Path $fiestaExe -Leaf
$processDir    = Join-Path $fiestaPath $processRelDir
$exePath       = Join-Path $processDir $processExe
$dirName       = Split-Path $processRelDir -Leaf

if (-not (Test-Path $fiestaPath -PathType Container)) {
    Write-Error "FIESTA_PATH ($fiestaPath) is not a directory. Mount your server folder, e.g.: -v C:\host\fiesta-server:$fiestaPath"
    exit 1
}

if (-not (Test-Path $exePath -PathType Leaf)) {
    Write-Error "Exe not found: $exePath"
    Write-Host  "  FIESTA_PATH = $fiestaPath"
    Write-Host  "  FIESTA_EXE  = $fiestaExe"
    if (Test-Path $fiestaPath) {
        Write-Host "  Directory listing:"
        Get-ChildItem $fiestaPath -Force | ForEach-Object { Write-Host ("    {0}" -f $_.Name) }
    }
    exit 1
}

# --- Discover SERVICE_NAME ---
# Mirrors start.sh: Fiesta exes embed their expected SCM service name in a
# per-process *ServerInfo.txt `MY_SERVER "_Name", ...` line. Registering
# under any other name triggers a "service upload only" code path that
# self-registers the expected name and exits, forcing a restart cycle.
# Reading the embedded name avoids that whether we're on Linux/Wine or
# native Windows SCM. Operator-supplied SERVICE_NAME (env) wins.
if (-not $env:SERVICE_NAME) {
    $myServerMatch = Get-ChildItem -Path $processDir -Filter '*.txt' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Select-String -Pattern '^\s*MY_SERVER\s+"([^"]+)"' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($myServerMatch -and $myServerMatch.Matches[0].Groups[1].Value) {
        $serviceName = $myServerMatch.Matches[0].Groups[1].Value
        Write-Host "  SERVICE_NAME discovered from MY_SERVER: $serviceName"
    } else {
        $serviceName = "_$dirName"
        Write-Host "  SERVICE_NAME fallback (no MY_SERVER in *.txt): $serviceName"
    }
} else {
    $serviceName = $env:SERVICE_NAME
}

# Pull (type, world, zone) out of the MY_SERVER line. Those three
# integers are how Fiesta identifies a service in SERVER_INFO -- each
# SERVER_INFO row in ServerInfo.txt has the same triple in positions
# 2-4 after the label. Config-driven match means no hardcoded label
# tables; if Mimir adds a new world or zone, this still works.
$script:myType = $null
$script:myWorld = $null
$script:myZone = $null
$mstMatch = Get-ChildItem -Path $processDir -Filter '*.txt' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Select-String -Pattern '^\s*MY_SERVER\s+"[^"]+"\s*,\s*"[^"]+"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($mstMatch) {
    $script:myType  = $mstMatch.Matches[0].Groups[1].Value
    $script:myWorld = $mstMatch.Matches[0].Groups[2].Value
    $script:myZone  = $mstMatch.Matches[0].Groups[3].Value
    Write-Host "  MY_SERVER triple: type=$myType world=$myWorld zone=$myZone"
}

# --- Decide whether this container should host an in-process GamigoZR ---
# Zones need a /GR.php-on-127.0.0.1:58492 HTTP response from GamigoZR; on
# Linux host networking a sibling gamigozr container provides it, but
# Windows containers can't share loopback so each Zone hosts its own.
# IS_ZONE env var: "1"/"0"/"auto". `auto` -> Zone.exe (the binary) triggers.
$isZone = $false
switch (($isZoneRaw, 'auto')[[int]([string]::IsNullOrEmpty($isZoneRaw))]) {
    '1'    { $isZone = $true }
    '0'    { $isZone = $false }
    'auto' { $isZone = ($processExe -ieq 'Zone.exe') }
    default {
        Write-Warning "Unknown IS_ZONE='$isZoneRaw', treating as auto"
        $isZone = ($processExe -ieq 'Zone.exe')
    }
}
if ((-not $isZone) -and $env:CRYPT_BLOB_PATH) {
    Write-Warning "CRYPT_BLOB_PATH is set but IS_ZONE is false; GamigoZR stub will not start. The blob mount is only meaningful for Zone containers."
}

# --- Auto-seed per-container ServerInfo overlay ---
# See start.sh for the full rationale; the short version is that each
# container needs a writable per-container copy of 9Data\ServerInfo so
# the rewrite step below can mutate it without racing other containers.
# Previously a one-shot `init` service in compose did this; doing it here
# makes each container self-contained (no init step in k8s either).
#
# Operator mounts the source folder a second time read-only:
#   -v C:\path\to\Server:C:\source:ro
# Default seed source is C:\source\9Data\ServerInfo; override via env
# SERVERINFO_SEED_DIR.
$serverInfoSeedDir = if ($env:SERVERINFO_SEED_DIR) { $env:SERVERINFO_SEED_DIR } else { 'C:\source\9Data\ServerInfo' }
$overlayDir        = Join-Path $fiestaPath '9Data\ServerInfo'
# Re-seed on EVERY start, not just when empty. Why: ServerInfo.txt's
# SERVER_INFO rows have docker hostnames in the IP column (e.g.
# "worldmanager"). start.ps1's rewrite resolves them to container IPs
# and writes the IPs back into the overlay. On a container restart,
# docker can assign a new IP, but the overlay still has the OLD IP
# from the previous run -- the exe then tries to bind an IP that
# isn't its own and Listen_Add fails (WM "*FAILED Listen_Add"). Always
# re-seeding from the source-of-truth hostname template guarantees the
# rewrite step starts from a clean slate.
if ((Test-Path $overlayDir -PathType Container) -and
    (Test-Path $serverInfoSeedDir -PathType Container)) {
    Write-Host "Re-seeding $overlayDir <- $serverInfoSeedDir"
    Get-ChildItem $overlayDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $serverInfoSeedDir '*') -Destination $overlayDir -Recurse -Force
}
elseif (Test-Path $overlayDir -PathType Container) {
    if (-not (Get-ChildItem $overlayDir -Force -ErrorAction SilentlyContinue)) {
        Write-Warning "$overlayDir is empty and $serverInfoSeedDir is not mounted -- per-process config #include will fail."
    }
}

Write-Host "=== Fiesta runtime (Windows) ==="
Write-Host "  Server folder : $fiestaPath"
Write-Host "  Process dir   : $processDir"
Write-Host "  Exe           : $processExe"
Write-Host "  Service name  : $serviceName"

# --- Auto-rewrite included config files ---
# The default ServerSource ServerInfo.txt hardcodes 127.0.0.1, .\SQLEXPRESS,
# and a known default SQL password. Walk the #include graph from the per-process
# config dir and rewrite the targets in place:
#   * SERVER_INFO rows whose trailing comment is "PUBLIC_IP" get their IP
#     replaced with $PUBLIC_IP (only if set). LOCALHOST rows stay 127.0.0.1.
#     Labels and ports are never touched.
#   * ODBC_INFO rows get .\SQLEXPRESS rewritten to ${SQL_HOST},${SQL_PORT},
#     PWD= rewritten to ${SA_PASSWORD} if set, and DRIVER={SQL Server} swapped
#     to DRIVER={${ODBC_DRIVER}} (Windows containers don't ship the legacy
#     {SQL Server} driver -- ODBC Driver 17 is the modern equivalent).
#
# Operators who don't want any rewriting: leave PUBLIC_IP and SA_PASSWORD unset
# and have your ODBC strings already point at a working server -- this script
# becomes a no-op for the config files.
#
# The included files must be writable. The standard pattern is to overlay-mount
# 9Data\ServerInfo\ as a per-container directory so the rewrite doesn't race
# with other containers reading/writing the same file -- see README.

function Get-IncludePaths {
    param([string]$cfgDir)
    $result = @{}
    if (-not (Test-Path $cfgDir)) { return @() }
    # Recurse 3 levels: Zone processes nest their config under
    # ZoneServerInfo/ZoneServerInfo.txt; flat services have it at the top.
    Get-ChildItem -Path $cfgDir -Filter '*.txt' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object {
        $txt = [System.IO.File]::ReadAllText($_.FullName)
        $matches = [regex]::Matches($txt, '(?m)^\s*#include\s+"([^"]+)"')
        foreach ($m in $matches) {
            $rel = $m.Groups[1].Value -replace '/', '\'
            $abs = if ([System.IO.Path]::IsPathRooted($rel)) {
                $rel
            } else {
                [System.IO.Path]::GetFullPath((Join-Path (Split-Path $_.FullName -Parent) $rel))
            }
            $result[$abs] = $true
        }
    }
    return $result.Keys
}

# DNS-resolve whatever sits in the "IP" column of SERVER_INFO rows. If the
# operator's source ServerInfo.txt has docker service names in the IP
# column (e.g. "login", "worldmanager", "sqlserver", "zone01") instead of
# 127.0.0.1, we resolve them to the actual container IP at startup. On
# Linux host networking those names won't resolve and we leave the field
# alone -- so the same source template works for both engines.
function Resolve-HostnameOrNull {
    param([string]$name)
    # Single-shot DNS resolution. No retry loop — under s2s-proxy mode the
    # proxy resolves peer DNS fresh per outbound connect, so any startup
    # race in docker DNS is invisible to the exe. The old retry-loop fix
    # for "WM rejects by literal IP" is obsolete: under s2s-proxy mode every
    # peer appears to the exe as 127.0.0.1 anyway.
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $ipOut = [ref] $null
    if ([System.Net.IPAddress]::TryParse($name, $ipOut)) { return $null }
    try {
        $ip = [System.Net.Dns]::GetHostAddresses($name) |
              Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
              Select-Object -First 1
        if ($ip) { return $ip.IPAddressToString }
    } catch { }
    return $null
}

function Rewrite-ConfigFile {
    param([string]$file)

    if (-not (Test-Path $file -PathType Leaf)) {
        Write-Host "  WARN: included file not found: $file"
        return
    }

    $rawText = [System.IO.File]::ReadAllText($file)
    $eol = if ($rawText -match "`r`n") { "`r`n" } else { "`n" }
    # Splits on either CRLF or LF; final element is "" if file ends with newline.
    $lines = $rawText -split "`r?`n"

    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^\s*SERVER_INFO\s') {
            # Capture: prefix, type, world, zone, idKind, IP, port-sep, port, suffix
            #   SERVER_INFO "label", type, world, zone, idKind, "ip", port, ...
            if ($line -match '^(\s*SERVER_INFO\s+"[^"]+"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*)"([^"]+)"(\s*,\s*)(\d+)(.*)$') {
                $prefix       = $Matches[1]
                $rowType      = $Matches[2]
                $rowWorld     = $Matches[3]
                $rowZone      = $Matches[4]
                $rowIdKind    = $Matches[5]
                $existingIp   = $Matches[6]
                $portSep      = $Matches[7]
                $existingPort = $Matches[8]
                $suffix       = $Matches[9]
                $newIp        = $existingIp
                $newPort      = $existingPort

                $isOwn      = ($myType -and $rowType -eq $myType -and $rowWorld -eq $myWorld -and $rowZone -eq $myZone)
                $isPublic   = ($rowIdKind -eq '20')
                $svcName    = Get-FiestaServiceName $rowType $rowWorld $rowZone

                if ($isOwn -and $isPublic) {
                    # Our client-facing row: bind 0.0.0.0; port unchanged.
                    $newIp = '0.0.0.0'
                }
                elseif ((-not $isOwn) -and $isPublic) {
                    # Other service's client-facing row: ADVERTISE the
                    # operator's external endpoint. Per-service env override
                    # if set; otherwise PUBLIC_IP for host, source port.
                    $extHost = [Environment]::GetEnvironmentVariable("EXTERNAL_HOST_${svcName}")
                    if ($extHost)        { $newIp = $extHost }
                    elseif ($publicIp)   { $newIp = $publicIp }
                    $extPort = [Environment]::GetEnvironmentVariable("EXTERNAL_PORT_${svcName}")
                    if ($extPort)        { $newPort = $extPort }
                }
                elseif ($isOwn -and -not $isPublic) {
                    # Own s2s row: bind 0.0.0.0 on the ORIGINAL port. The exe
                    # listens here; the s2s proxy publishes a *shifted* port
                    # externally (port + offset) and forwards into 127.0.0.1
                    # on the original port. We deliberately do NOT shift the
                    # exe's bind: Fiesta WM refuses to bind 127.0.0.1 for
                    # SERVER_ID_ZONE (idKind=6) even though it accepts
                    # 127.0.0.1 for SERVER_ID_OPTOOL (idKind=8); apparently
                    # the zone-listener path has a "loopback isn't a real
                    # interface" check baked in. Binding 0.0.0.0 sidesteps
                    # the check, and the proxy-on-shifted-port keeps the
                    # exe's port internal to the pod (we don't publish it).
                    if (-not $s2sProxyDisabled) {
                        $externalPort = [int]$existingPort + $s2sInternalOffset
                        $newIp = '0.0.0.0'
                        $key   = "0.0.0.0:$externalPort"
                        $script:s2sInbound[$key] = "0.0.0.0:${externalPort}:127.0.0.1:${existingPort}"
                    }
                    else {
                        $newIp = '0.0.0.0'
                    }
                }
                else {
                    # Peer s2s row (other service, LOCALHOST tag). Under
                    # s2s-proxy mode, point at 127.0.0.1 so the exe dials
                    # our local proxy; the proxy tunnels to the peer pod's
                    # *shifted* external port (peer-dns:port+offset), where
                    # that pod's own s2s proxy is listening. The peer pod's
                    # proxy then forwards into the peer exe's loopback.
                    if (-not $s2sProxyDisabled) {
                        $newIp = '127.0.0.1'
                        $intHost = [Environment]::GetEnvironmentVariable("INTERNAL_HOST_${svcName}")
                        $upstreamHost = if ($intHost) { $intHost } else { $existingIp }
                        # Skip outbound routes that target loopback. Operators
                        # use INTERNAL_HOST_<svc>=127.0.0.1 to stub absent
                        # peers; tunneling the proxy to itself either self-
                        # loops or wastes capacity. The exe still has the
                        # row pointed at 127.0.0.1 so its connect will fail
                        # fast (connection refused on a port nothing listens
                        # on) — matches "peer not deployed" semantics.
                        if ($upstreamHost -notmatch '^(127\.|::1$|0\.0\.0\.0$)') {
                            $upstreamPort = [int]$existingPort + $s2sInternalOffset
                            $key = "127.0.0.1:${existingPort}:${upstreamHost}"
                            $script:s2sOutbound[$key] = "127.0.0.1:${existingPort}:${upstreamHost}:${upstreamPort}"
                        }
                    }
                    else {
                        # Legacy path: resolve docker service hostname to a
                        # sibling container's current IP at boot.
                        $intHost = [Environment]::GetEnvironmentVariable("INTERNAL_HOST_${svcName}")
                        $hostToResolve = if ($intHost) { $intHost } else { $existingIp }
                        $resolved = Resolve-HostnameOrNull $hostToResolve
                        if ($resolved)  { $newIp = $resolved }
                        elseif ($intHost) { $newIp = $intHost }
                    }
                }

                if ($newIp -ne $existingIp -or $newPort -ne $existingPort) {
                    $lines[$i] = '{0}"{1}"{2}{3}{4}' -f $prefix, $newIp, $portSep, $newPort, $suffix
                    $changed = $true
                }
            }
        }
        elseif ($line -match 'ODBC_INFO') {
            $newLine = $line
            if ($newLine.Contains('SERVER=.\SQLEXPRESS')) {
                $newLine = $newLine.Replace('SERVER=.\SQLEXPRESS', "SERVER=${sqlHost},${sqlPort}")
            }
            # Also rewrite the literal SERVER=127.0.0.1,<port> pattern that
            # ServerSource ships with -- when SQL_HOST is set to a sibling
            # container's hostname (e.g. "sqlserver") this redirects ODBC at
            # the SQL container instead of the loopback. ODBC Driver 17 does
            # the hostname resolution natively, no IP substitution needed.
            $newLine = [regex]::Replace($newLine, 'SERVER=127\.0\.0\.1,\d+', "SERVER=${sqlHost},${sqlPort}")
            if ($odbcDriver -ne 'SQL Server' -and $newLine.Contains('{SQL Server}')) {
                $newLine = $newLine.Replace('{SQL Server}', "{$odbcDriver}")
            }
            if ($saPassword -and $newLine -match '(PWD=)([^;"\s]+)') {
                $existing = $Matches[2]
                if ($existing -ne $saPassword) {
                    # Literal replace on the matched substring -- avoids regex
                    # injection from special chars in $saPassword.
                    $matchedFull = $Matches[0]
                    $newLine = $newLine.Replace($matchedFull, "PWD=$saPassword")
                }
            }
            if ($newLine -ne $line) {
                $lines[$i] = $newLine
                $changed = $true
            }
        }
    }

    if ($changed) {
        try {
            [System.IO.File]::WriteAllText($file, ($lines -join $eol))
            Write-Host "  rewrote: $file"
        } catch {
            Write-Warning "  $file is not writable: $_"
            Write-Host   "         Mount its parent dir as a per-container writable overlay, e.g.:"
            Write-Host   "           -v <host-dir>:$(Split-Path $file -Parent)"
        }
    }
}

# PUBLIC_IP must be set to the operator's WAN IP (the address external
# clients reach the server via). Purely an ADVERTISE value: written
# into other services' client-facing rows so Login can tell the client
# "go to WM/Zone at THIS IP". Containers never bind PUBLIC_IP. Auto-
# detecting from a bridged-network container would pick the docker
# subnet IP, useless to external clients -- so we fail loudly.
if (-not $publicIp) {
    Write-Error "PUBLIC_IP env is required. Set it to your server's WAN/public IP (e.g. 12.34.56.78). It's advertised to clients via SERVER_INFO; containers don't connect to it themselves."
    exit 1
}


if ($serverInfoOverride) {
    Write-Host "Using FIESTA_SERVERINFO_PATH override: $serverInfoOverride"
    if (Test-Path $serverInfoOverride -PathType Leaf) {
        Rewrite-ConfigFile -file $serverInfoOverride
    }
    else {
        Write-Warning "FIESTA_SERVERINFO_PATH not found: $serverInfoOverride"
    }
}
else {
    Write-Host "Walking config includes from $processDir..."
    $includes = @(Get-IncludePaths -cfgDir $processDir)
    if ($includes.Count -gt 0) {
        foreach ($inc in $includes) {
            Rewrite-ConfigFile -file $inc
        }
    } else {
        Write-Host "  (no #include directives found in $processDir\*.txt)"
    }
}

# --- Step 2.5: launch co-located s2s proxy ---
# The exe was rewritten to bind 127.0.0.1:<port+offset> for each own s2s row
# and to dial 127.0.0.1:<original-port> for each peer s2s row. The proxy
# materialises those:
#   inbound:  bind 0.0.0.0:<original> -> 127.0.0.1:<port+offset>   (peer -> us)
#   outbound: bind 127.0.0.1:<port>   -> <peer-dns>:<port>          (us -> peer)
# DNS resolves fresh per outbound connect inside FiestaProxy, so peer-pod
# IP churn doesn't require a restart.
if (-not $s2sProxyDisabled) {
    $allRoutes = @($script:s2sInbound.Values) + @($script:s2sOutbound.Values)
    if ($allRoutes.Count -gt 0) {
        if (-not (Test-Path $s2sProxyDll -PathType Leaf)) {
            Write-Error "S2S proxy DLL not found at $s2sProxyDll. Set S2S_PROXY_DLL to its location, or set S2S_PROXY_DISABLED=1 to opt out (peer auth will fail in that case)."
            exit 1
        }
        $env:S2S_ROUTES = $allRoutes -join ';'
        Write-Host "Launching s2s proxy: $s2sProxyDll"
        Write-Host "  S2S_ROUTES = $($env:S2S_ROUTES)"
        $s2sProxyProc = Start-Process -FilePath 'dotnet' -ArgumentList @($s2sProxyDll) -PassThru -NoNewWindow
        Write-Host "  s2s proxy pid: $($s2sProxyProc.Id)"
    }
    else {
        Write-Host "No s2s rows in ServerInfo -- no proxy needed for this service."
    }
}

# --- Step 1: Registry keys required by Fiesta exes ---
# Fantasy/GBO keys are baked into the exes' license/anti-tamper checks.
Write-Host "Setting up registry keys..."
reg add 'HKLM\SOFTWARE\Wow6432Node\Fantasy\Fighter' /v Bird   /d Eagle      /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\Fantasy\Fighter' /v Insect /d Honet      /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\GBO' /v Desert   /d 138127     /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\GBO' /v Mountain /d 30324      /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\GBO' /v Natural  /d 126810443  /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\GBO' /v Ocean    /d 7241589632 /f | Out-Null
reg add 'HKLM\SOFTWARE\Wow6432Node\GBO' /v Sabana   /d 2554545953 /f | Out-Null

# --- Step 2: In-container GamigoZR HTTP stub (zones only) ---
# Real GamigoZR.exe is a 15 KB .NET service that listens on
# 127.0.0.1:58492 and returns a static crypt blob for every request.
# On Windows containers (no shared loopback) every Zone has to host
# its own copy locally. PowerShell's HttpListener is the lightest way
# to do that without baking extra packages into the image.
#
# Operator mounts the BYO crypt blob at $env:CRYPT_BLOB_PATH (default
# C:\gamigozr\response.txt). The blob is extracted one-shot from real
# GamigoZR via `curl http://127.0.0.1:58492/ > response.txt`.
#
# IS_ZONE=auto picks Zone.exe automatically. START_GAMIGOZR was the
# previous Wine-on-Linux real-GamigoZR launcher knob and is unrelated
# to this stub -- it's intentionally NOT consulted here.
if ($isZone) {
    if (Test-Path $cryptBlobPath -PathType Leaf) {
        Write-Host "Starting GamigoZR stub on 127.0.0.1:58492 (blob: $cryptBlobPath)..."
        $gamigozrJob = Start-Job -Name 'gamigozr-stub' -ScriptBlock {
            param($blobPath)
            $blob = [System.IO.File]::ReadAllBytes($blobPath)
            $listener = [System.Net.HttpListener]::new()
            $listener.Prefixes.Add('http://127.0.0.1:58492/')
            $listener.Start()
            try {
                while ($listener.IsListening) {
                    $ctx = $listener.GetContext()
                    try {
                        $ctx.Response.StatusCode    = 200
                        $ctx.Response.ContentLength64 = $blob.Length
                        $ctx.Response.OutputStream.Write($blob, 0, $blob.Length)
                    } finally {
                        $ctx.Response.Close()
                    }
                }
            } finally {
                $listener.Stop()
            }
        } -ArgumentList $cryptBlobPath
        Write-Host "  GamigoZR stub job: $($gamigozrJob.Id)"
    }
    else {
        Write-Warning "IS_ZONE=true but CRYPT_BLOB_PATH ($cryptBlobPath) not found."
        Write-Host   "  Mount your operator-extracted blob there (curl http://127.0.0.1:58492/ from a"
        Write-Host   "  real GamigoZR.exe run, save the body). Without this, Zone will crash at HTML/Pass."
    }
}

# --- Step 3: Clean stale logs that might trick the tailer ---
$logDir = Join-Path $processDir 'DebugMessage'
$logPatterns = @('Assert*.txt','ExitLog*.txt','Msg_*.txt','Dbg.txt',
                 'MapLoad*.txt','Message*.txt','Size*.txt','*CallStack.txt','5ZoneServer*.txt')

if (Test-Path $logDir) {
    Get-ChildItem "$logDir\*.txt" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}
foreach ($pat in $logPatterns) {
    Get-ChildItem $processDir -Filter $pat -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

# --- Step 4: Register and start the Windows service ---
# Running the exe directly would block on StartServiceCtrlDispatcher() -- register
# with sc.exe and let SCM start it. cd to the process dir so any relative paths
# the exe uses resolve correctly.
Set-Location $processDir

Write-Host "Registering service: $serviceName -> $exePath"
sc.exe delete $serviceName 2>$null | Out-Null
sc.exe create $serviceName binPath= $exePath start= demand | Out-Null

$maxWait = 15
$service = $null
for ($i = 0; $i -lt $maxWait; $i++) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) { break }
    Start-Sleep -Seconds 1
}

if (-not $service) {
    Write-Error "Service '$serviceName' not registered after ${maxWait}s."
    if ($keepAlive) {
        Write-Host "KEEP_ALIVE=1: container staying alive." -ForegroundColor Cyan
        while ($true) { Start-Sleep -Seconds 60 }
    }
    exit 1
}

Write-Host "Starting service: $serviceName"
try {
    Start-Service -Name $serviceName -ErrorAction Stop
    Write-Host "$serviceName started."
}
catch {
    Write-Warning "Failed to start ${serviceName}: $_"
}

# --- Step 5: Wait for log files to appear, then tail them ---
function Get-LogFiles {
    param($processDir, $logDir)
    $files = @()
    if (Test-Path $logDir) {
        $files += @(Get-ChildItem "$logDir\*.txt" -ErrorAction SilentlyContinue)
    }
    foreach ($pat in @('Assert*.txt','ExitLog*.txt','Msg_*.txt','Dbg.txt',
                       'MapLoad*.txt','Message*.txt','Size*.txt','*CallStack.txt','5ZoneServer*.txt')) {
        $files += @(Get-ChildItem $processDir -Filter $pat -ErrorAction SilentlyContinue)
    }
    return $files
}

Write-Host "Waiting for log files..."
$timeout  = 60
$logFiles = @()
for ($i = 0; $i -lt $timeout; $i++) {
    $logFiles = Get-LogFiles $processDir $logDir
    if ($logFiles.Count -gt 0) { break }
    Start-Sleep -Seconds 1
}

if ($logFiles.Count -eq 0) {
    Write-Host "No log files after ${timeout}s -- process may have crashed during init."
    if ($keepAlive) {
        Write-Host "KEEP_ALIVE=1: container staying alive." -ForegroundColor Cyan
        while ($true) { Start-Sleep -Seconds 60 }
    }
    exit 1
}

Write-Host ("Tailing {0} log file(s): {1}" -f $logFiles.Count, ($logFiles.Name -join ', '))

$jobs = @()
foreach ($lf in $logFiles) {
    $jobs += Start-Job -ScriptBlock {
        param($path, $tag)
        Get-Content -Path $path -Wait | ForEach-Object { '[{0}] {1}' -f $tag, $_ }
    } -ArgumentList $lf.FullName, $lf.BaseName
}

$watcherJob = Start-Job -ScriptBlock {
    param($processDir, $logDir)
    $known = @{}
    while ($true) {
        $files = @()
        if (Test-Path $logDir) { $files += @(Get-ChildItem "$logDir\*.txt" -ErrorAction SilentlyContinue) }
        foreach ($pat in @('Assert*.txt','ExitLog*.txt','Msg_*.txt','Dbg.txt',
                           'MapLoad*.txt','Message*.txt','Size*.txt','*CallStack.txt','5ZoneServer*.txt')) {
            $files += @(Get-ChildItem $processDir -Filter $pat -ErrorAction SilentlyContinue)
        }
        foreach ($f in $files) {
            if (-not $known.ContainsKey($f.FullName)) {
                $known[$f.FullName] = $true
                Write-Output ('NEW_LOG:{0}:{1}' -f $f.FullName, $f.BaseName)
            }
        }
        Start-Sleep -Seconds 5
    }
} -ArgumentList $processDir, $logDir

# --- Step 6: Monitor service + forward log output ---
$svcSeenRunning      = $false
$svcCheckTick        = 0
$svcStartTime        = Get-Date
$svcNeverRanTimeout  = 30

while ($true) {
    Receive-Job -Job $watcherJob -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match '^NEW_LOG:(.+):(.+)$') {
            Write-Host ("New log file: {0}" -f $Matches[2])
            $jobs += Start-Job -ScriptBlock {
                param($path, $tag)
                Get-Content -Path $path -Wait | ForEach-Object { '[{0}] {1}' -f $tag, $_ }
            } -ArgumentList $Matches[1], $Matches[2]
        }
    }

    foreach ($job in $jobs) {
        Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    }

    $svcCheckTick++
    if ($svcCheckTick -ge 5) {
        $svcCheckTick = 0
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { $svcSeenRunning = $true }

        $elapsed = ((Get-Date) - $svcStartTime).TotalSeconds
        $neverStarted = (-not $svcSeenRunning) -and ($elapsed -gt $svcNeverRanTimeout) -and ($svc -and $svc.Status -eq 'Stopped')

        if ($svcSeenRunning -and $svc -and $svc.Status -ne 'Running') {
            Write-Host ("=== $serviceName stopped (exit code: {0}) ===" -f $svc.ExitCode) -ForegroundColor Yellow
        }
        elseif ($neverStarted) {
            Write-Host ("=== $serviceName never reached Running ({0:N0}s elapsed) ===" -f $elapsed) -ForegroundColor Red
        }
        else {
            continue
        }

        for ($d = 0; $d -lt 10; $d++) {
            Start-Sleep -Milliseconds 500
            foreach ($job in $jobs) {
                Receive-Job -Job $job -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
            }
        }
        if ($keepAlive) {
            Write-Host "KEEP_ALIVE=1: container staying alive." -ForegroundColor Cyan
            while ($true) { Start-Sleep -Seconds 60 }
        }
        exit 1
    }

    Start-Sleep -Milliseconds 500
}
