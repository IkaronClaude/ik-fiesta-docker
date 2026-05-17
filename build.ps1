# Build the Fiesta runtime image (Windows variant).
#
# Run from a Windows Docker host with Docker Desktop in *Windows-container* mode.
#
# Usage:
#   .\build.ps1                                              # build local image only
#   .\build.ps1 -Push ghcr.io/you/fiesta-runtime:latest      # build + push windows variant
#
# To produce a true multi-platform image, combine with the linux variant:
#   1. On Linux:    ./build.sh    -Push  ghcr.io/you/fiesta-runtime:latest
#   2. On Windows:  .\build.ps1   -Push  ghcr.io/you/fiesta-runtime:latest
#   3. On either:   ./combine-manifest.sh ghcr.io/you/fiesta-runtime:latest

[CmdletBinding()]
param(
    [string]$Push,
    [string]$Image = 'fiesta-server-runtime:windows'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# BuildKit is incompatible with Windows containers, disable for this session.
$env:DOCKER_BUILDKIT = '0'

if ($Push) {
    $tag = "$Push-windows-amd64"
    Write-Host "Building + pushing $tag ..."
    docker build --file Dockerfile.windows --tag $tag .
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
    docker build --file Dockerfile.windows --tag $Image .
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
    Write-Host ""
    Write-Host "Built local image: $Image"
    Write-Host "Try it:"
    Write-Host "    docker run --rm -v C:\path\to\fiesta-server:C:\fiesta ``"
    Write-Host "        -e FIESTA_EXE=Login\Login.exe $Image"
}
