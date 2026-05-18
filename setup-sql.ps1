# Fiesta SQL Server runtime -- Windows entrypoint.
#
# Starts the SQL Express service, walks C:\backups for *.bak, RESTOREs each
# one whose DB isn't already registered, then keeps the container alive by
# tailing the SQL ERRORLOG.
#
# Contract (see Dockerfile.sql.windows for full docs):
#   SA_PASSWORD   REQUIRED. sa password.
#   RESTORE_DBS   auto | 0  -- "0" disables the restore pass entirely.

$saPassword = $env:SA_PASSWORD
if (-not $saPassword) {
    Write-Host "ERROR: SA_PASSWORD is not set." -ForegroundColor Red
    Write-Host "  Pass it with: -e SA_PASSWORD=YourStrongPassword1" -ForegroundColor Yellow
    exit 1
}
$restoreDbs = if ($env:RESTORE_DBS) { $env:RESTORE_DBS } else { 'auto' }

# Install-time password (matches Dockerfile.sql.windows /SAPWD=).
$installPassword = 'BootstrapPwd!1'

$sqlInstance = '.\SQLEXPRESS'
$backupDir = 'C:\backups'
$dataDir = 'C:\sql-data'

if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

Write-Host "Starting SQL Server Express..."
Start-Service 'MSSQL$SQLEXPRESS'
Start-Sleep -Seconds 5

Write-Host "Waiting for SQL Server to accept connections..."
$connectPassword = $saPassword
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    sqlcmd -S $sqlInstance -U sa -P $connectPassword -C -Q "SELECT 1" *> $null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }

    # After a couple failures, try the install password so we can ALTER LOGIN.
    if ($i -eq 2 -and $connectPassword -ne $installPassword) {
        sqlcmd -S $sqlInstance -U sa -P $installPassword -C -Q "SELECT 1" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Connected with install password -- will ALTER LOGIN to SA_PASSWORD."
            $connectPassword = $installPassword
            $ready = $true
            break
        }
    }
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Write-Host "ERROR: SQL Server did not become ready after 30 retries." -ForegroundColor Red
    exit 1
}

if ($connectPassword -ne $saPassword) {
    Write-Host "Updating sa password to match SA_PASSWORD..."
    sqlcmd -S $sqlInstance -U sa -P $connectPassword -C -Q "ALTER LOGIN sa WITH PASSWORD = '$saPassword'"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: ALTER LOGIN sa failed." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Enabling remote access..."
sqlcmd -S $sqlInstance -U sa -P $saPassword -C -Q "EXEC sp_configure 'remote access', 1; RECONFIGURE;" *> $null

if ($restoreDbs -eq '0') {
    Write-Host "RESTORE_DBS=0 -- skipping restore pass."
}
elseif (-not (Test-Path $backupDir)) {
    Write-Host "WARN: backup dir $backupDir does not exist -- nothing to restore."
}
else {
    # Discover *.bak in the mounted backup dir. DB name = filename stem.
    # No hardcoded list -- new .bak files get picked up on next start.
    $baks = Get-ChildItem -Path $backupDir -Filter *.bak -File -ErrorAction SilentlyContinue
    if (-not $baks) {
        Write-Host "No *.bak files in $backupDir -- nothing to restore."
    }

    foreach ($bak in $baks) {
        $db = [System.IO.Path]::GetFileNameWithoutExtension($bak.Name)
        $bakPath = $bak.FullName

        # Skip if already registered.
        $dbCount = sqlcmd -S $sqlInstance -U sa -P $saPassword -C -h -1 -W `
            -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$db'" 2>&1 |
            Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1

        if ($dbCount -and $dbCount.Trim() -eq '1') {
            Write-Host "Database '$db' already exists -- skipping restore."
            continue
        }

        Write-Host "Restoring '$db' from $bakPath..."

        # Build MOVE clause from FILELISTONLY.
        $fileList = sqlcmd -S $sqlInstance -U sa -P $saPassword -C `
            -Q "RESTORE FILELISTONLY FROM DISK = '$bakPath'" -s "|" -W -h -1 2>&1

        $moveClause = ""
        $dataIdx = 0
        $logIdx = 0
        foreach ($line in $fileList) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 3) { continue }
            $logicalName = $parts[0].Trim()
            $type = $parts[2].Trim()
            if ($type -eq 'D') {
                $suffix = if ($dataIdx -eq 0) { '' } else { "_$dataIdx" }
                $moveClause += "MOVE '$logicalName' TO '$dataDir\${db}${suffix}.mdf', "
                $dataIdx++
            }
            elseif ($type -eq 'L') {
                $suffix = if ($logIdx -eq 0) { '' } else { "_$logIdx" }
                $moveClause += "MOVE '$logicalName' TO '$dataDir\${db}${suffix}_log.ldf', "
                $logIdx++
            }
        }

        $sql = if ($moveClause -eq "") {
            "RESTORE DATABASE [$db] FROM DISK = '$bakPath'"
        } else {
            $moveClause = $moveClause.TrimEnd(", ")
            "RESTORE DATABASE [$db] FROM DISK = '$bakPath' WITH $moveClause"
        }

        $restoreOut = sqlcmd -S $sqlInstance -U sa -P $saPassword -C -Q $sql 2>&1
        $restoreStr = $restoreOut | Out-String
        if ($restoreStr -match 'Msg \d+, Level 1[6-9]') {
            Write-Host "ERROR restoring '$db':" -ForegroundColor Red
            Write-Host $restoreStr
        } else {
            Write-Host "Database '$db' restored."
        }
    }
}

Write-Host "SQL Server setup complete."

# Keep the container alive by tailing the ERRORLOG. SQL 2022 = MSSQL16,
# 2025 = MSSQL17 -- discover whichever exists.
$logFile = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\MSSQL*.SQLEXPRESS\MSSQL\Log\ERRORLOG' `
    -ErrorAction SilentlyContinue | Select-Object -First 1

if ($logFile -and (Test-Path $logFile.FullName)) {
    Get-Content -Path $logFile.FullName -Wait
} else {
    while ($true) { Start-Sleep -Seconds 60 }
}
