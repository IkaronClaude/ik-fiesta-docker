# Build the Fiesta SQL Server runtime image (Windows variant).
#
# Run from a Windows Docker host with Docker Desktop in *Windows-container* mode.
#
# Usage:
#   .\build-sql.ps1                                              # build local image only
#   .\build-sql.ps1 -Push ghcr.io/you/fiesta-sql-runtime:latest  # build + push

[CmdletBinding()]
param(
    [string]$Push,
    [string]$Image = 'fiesta-sql-runtime:windows'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# BuildKit is incompatible with Windows containers.
$env:DOCKER_BUILDKIT = '0'

if ($Push) {
    $tag = "$Push-windows-amd64"
    Write-Host "Building + pushing $tag ..."
    docker build --file Dockerfile.sql.windows --tag $tag .
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
    docker push $tag
    if ($LASTEXITCODE -ne 0) { throw "docker push failed" }
    Write-Host ""
    Write-Host "Pushed: $tag"
    Write-Host "Next: build the linux/amd64 variant on a Linux host, then run:"
    Write-Host "    ./combine-manifest.sh $Push"
}
else {
    Write-Host "Building local image: $Image ..."
    docker build --file Dockerfile.sql.windows --tag $Image .
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
    Write-Host ""
    Write-Host "Built local image: $Image"
    Write-Host "Try it:"
    Write-Host "    docker run --rm -e SA_PASSWORD=YourStrongPassword1 ``"
    Write-Host "        -p 1433:1433 ``"
    Write-Host "        -v C:\path\to\Server\Databases:C:\backups ``"
    Write-Host "        $Image"
}
