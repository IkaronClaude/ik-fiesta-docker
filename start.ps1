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
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    # Already an IP? leave it.
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
            # Full positional parse so we can match on (type, world, zone)
            # and inspect the "id" (5th int, =20 for client-facing rows).
            #   SERVER_INFO "label", type, world, zone, idKind, "ip", port, ...
            if ($line -match '^(\s*SERVER_INFO\s+"[^"]+"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*)"([^"]+)"(.*)$') {
                $prefix      = $Matches[1]
                $rowType     = $Matches[2]
                $rowWorld    = $Matches[3]
                $rowZone     = $Matches[4]
                $rowIdKind   = $Matches[5]
                $existingVal = $Matches[6]
                $suffix      = $Matches[7]
                $newVal      = $existingVal

                $isOwn    = ($myType -and $rowType -eq $myType -and $rowWorld -eq $myWorld -and $rowZone -eq $myZone)
                $isPublic = ($rowIdKind -eq '20')

                if ($isOwn -and $isPublic) {
                    # Our client-facing port: bind 0.0.0.0 (all
                    # interfaces). Universal across deployment styles:
                    #   * docker -p via userland-proxy hits container
                    #     loopback OR eth0 -- 0.0.0.0 covers both
                    #   * Linux native docker / k8s with DNAT (traefik,
                    #     kube-proxy) forwards external_ip:port to
                    #     container_ip:port -- 0.0.0.0 is listening
                    #   * Sibling containers via docker DNS connect to
                    #     container_ip:port -- also caught
                    # Verified on Windows containers (Login/WM/zones +
                    # DB bridges all SERVICE START with 0.0.0.0).
                    $newVal = '0.0.0.0'
                }
                elseif ((-not $isOwn) -and $isPublic) {
                    # Someone else's client-facing port. We're not binding
                    # this -- we ADVERTISE it (Login tells the client "go
                    # to PG_W00_WM at this IP/port"). Use operator's real
                    # public IP so the client can reach it from outside.
                    if ($publicIp) { $newVal = $publicIp }
                }
                else {
                    # LOCALHOST-tagged rows (s2s, OPTOOL). DNS-resolve the
                    # hostname in the IP column to the sibling container's
                    # current docker IP. For own LOCALHOST rows this lands
                    # our own container IP; other services connect to it.
                    $resolved = Resolve-HostnameOrNull $existingVal
                    if ($resolved) { $newVal = $resolved }
                }

                if ($newVal -ne $existingVal) {
                    $lines[$i] = '{0}"{1}"{2}' -f $prefix, $newVal, $suffix
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


Write-Host "Walking config includes from $processDir..."
$includes = @(Get-IncludePaths -cfgDir $processDir)
if ($includes.Count -gt 0) {
    foreach ($inc in $includes) {
        Rewrite-ConfigFile -file $inc
    }
} else {
    Write-Host "  (no #include directives found in $processDir\*.txt)"
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
