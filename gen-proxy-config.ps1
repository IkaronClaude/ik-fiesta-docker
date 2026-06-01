<#
.SYNOPSIS
  Derive the fiesta-proxy config from a ServerInfo.txt (PowerShell parity of
  gen-proxy-config.sh).

.DESCRIPTION
  Reads one ServerInfo.txt (the full SERVER_INFO block) and emits the proxy
  configuration that example/{linux,windows}/docker-compose.yml and
  example/k8s/60-proxy.yaml otherwise hand-maintain:

    * PROXY_ROUTES  -- one  listen:ServiceName:host:port[:opaque]  entry per
                       client-facing SERVER_INFO row (FromServerType == 20,
                       the rows tagged "; PUBLIC_IP"). Zone rows get :opaque;
                       Login / WorldManager use the default rewrite mode.
    * ports         -- the host port-publish list (PORT:PORT).
    * INTERNAL_HOST -- the ServiceName -> docker/k8s hostname map consumed by
                       the runtime containers (start.ps1) for s2s rewriting.

  Service names match start.ps1's service-name scheme exactly. Host names are
  the lowercased compose service names (world-0 suffix dropped; zones become
  zone<world><zone>). Override the host domain for k8s with -HostSuffix.

.EXAMPLE
  .\gen-proxy-config.ps1 -ServerInfo .\example\windows\serverinfo\login\ServerInfo.txt -PublicIp 203.0.113.7

.EXAMPLE
  .\gen-proxy-config.ps1 -ServerInfo .\ServerInfo.txt -Format k8s -HostSuffix .fiesta.svc.cluster.local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ServerInfo,
    [string] $PublicIp = "",
    [string] $HostSuffix = "",
    [ValidateSet("compose", "env", "k8s")] [string] $Format = "compose"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ServerInfo)) {
    Write-Error "no such file: $ServerInfo"; exit 1
}

# ServiceName from (type, world, zone) -- mirrors start.ps1's service-name map.
function Get-ServiceName([int]$t, [int]$w, [int]$z) {
    switch ($t) {
        0 { "Account" }
        1 { "AccountLog" }
        2 { "Character_$w" }
        3 { "GameLog_$w" }
        4 { "Login" }
        5 { "WorldManager_$w" }
        6 { "Zone_${w}_$z" }
        default { "Unknown_${t}_${w}_$z" }
    }
}

# Host (compose service name) from (type, world, zone). World-0 suffix is
# dropped for the singletons; zones become zone<world><zone>.
function Get-HostName([int]$t, [int]$w, [int]$z) {
    $wsfx = if ($w -ne 0) { "$w" } else { "" }
    $base = switch ($t) {
        0 { "account" }
        1 { "accountlog" }
        2 { "character$wsfx" }
        3 { "gamelog$wsfx" }
        4 { "login" }
        5 { "worldmanager$wsfx" }
        6 { "zone${w}${z}" }
        default { "svc${t}_${w}_$z" }
    }
    "$base$HostSuffix"
}

# --- Parse SERVER_INFO rows -------------------------------------------------
$routes        = New-Object System.Collections.Generic.List[string]
$routeComments = New-Object System.Collections.Generic.List[string]
$ports         = New-Object System.Collections.Generic.List[string]
$ihostNames    = New-Object System.Collections.Generic.List[string]
$ihostHosts    = New-Object System.Collections.Generic.List[string]

$inDefine = $false
$rowRe = '^SERVER_INFO\s+"[^"]+"\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"[^"]+"\s*,\s*(\d+)'

foreach ($raw in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $ServerInfo))) {
    $line = $raw.TrimStart()
    if ($line -match '^#DEFINE')    { $inDefine = $true;  continue }
    if ($line -match '^#ENDDEFINE') { $inDefine = $false; continue }
    if ($inDefine) { continue }
    if ($line -notmatch '^SERVER_INFO') { continue }

    $m = [regex]::Match($line, $rowRe)
    if (-not $m.Success) { continue }

    $type     = [int]$m.Groups[1].Value
    $world    = [int]$m.Groups[2].Value
    $zone     = [int]$m.Groups[3].Value
    $fromType = [int]$m.Groups[4].Value
    $port     = $m.Groups[5].Value

    $svc     = Get-ServiceName $type $world $zone
    $svcHost = Get-HostName    $type $world $zone

    # INTERNAL_HOST map: one entry per distinct service (rows repeat per peer).
    if (-not $ihostNames.Contains($svc)) {
        $ihostNames.Add($svc); $ihostHosts.Add($svcHost)
    }

    # Client-facing rows (FromServerType == Client(20)) become proxy routes.
    if ($fromType -eq 20) {
        $mode = if ($type -eq 6) { ":opaque" } else { "" }   # Zone: opaque pump
        $routes.Add("${port}:${svc}:${svcHost}:${port}$mode")
        $routeComments.Add($svc)
        $ports.Add($port)
    }
}

if ($routes.Count -eq 0) {
    Write-Error "no client-facing rows (FromServerType==20) found in $ServerInfo"; exit 1
}

# --- Emit -------------------------------------------------------------------
function Emit-Env {
    if ($PublicIp) { "PUBLIC_IP=$PublicIp" }
    "PROXY_ROUTES=$($routes -join ';')"
    for ($i = 0; $i -lt $ihostNames.Count; $i++) {
        "INTERNAL_HOST_$($ihostNames[$i])=$($ihostHosts[$i])"
    }
}

function Emit-Yaml([string]$indent) {
    if ($PublicIp) { "${indent}PUBLIC_IP: `"$PublicIp`"" }
    "${indent}PROXY_ROUTES: >-"
    $last = $routes.Count - 1
    for ($i = 0; $i -lt $routes.Count; $i++) {
        if ($i -lt $last) { "${indent}  $($routes[$i]);" } else { "${indent}  $($routes[$i])" }
    }
    ""
    "${indent}# ports to publish:"
    for ($i = 0; $i -lt $ports.Count; $i++) {
        "${indent}- `"$($ports[$i]):$($ports[$i])`"   # $($routeComments[$i])"
    }
    ""
    "${indent}# INTERNAL_HOST map (set on the runtime containers):"
    for ($i = 0; $i -lt $ihostNames.Count; $i++) {
        "${indent}INTERNAL_HOST_$($ihostNames[$i]): `"$($ihostHosts[$i])`""
    }
}

switch ($Format) {
    "env"     { Emit-Env }
    "compose" { Emit-Yaml "      " }
    "k8s"     { Emit-Yaml "            " }
}
