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

# Clear any stale readiness marker (container-local path, but be defensive).
# The docker HEALTHCHECK stays "unhealthy/starting" until this is re-created
# below, once restores are done -- see healthcheck-sql.ps1.
$readyMarker = 'C:\fiesta-sql-ready'
Remove-Item $readyMarker -Force -ErrorAction SilentlyContinue

Write-Host "Starting SQL Server Express..."
Start-Service 'MSSQL$SQLEXPRESS'
Start-Sleep -Seconds 5

Write-Host "Waiting for SQL Server to accept connections..."
$connectPassword = $saPassword
$ready = $false
# Plain-startup budget in seconds. NOT applied while SQL is in script upgrade
# mode (see below). Override with SQL_STARTUP_TIMEOUT.
$startupTimeout = if ($env:SQL_STARTUP_TIMEOUT) { [int]$env:SQL_STARTUP_TIMEOUT } else { 120 }
$elapsed = 0
while ($true) {
    $probe = (sqlcmd -S $sqlInstance -U sa -P $connectPassword -C -Q "SELECT 1" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }

    # After a couple failures, try the install password so we can ALTER LOGIN.
    if ($elapsed -ge 4 -and $connectPassword -ne $installPassword) {
        $probe2 = (sqlcmd -S $sqlInstance -U sa -P $installPassword -C -Q "SELECT 1" 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Connected with install password -- will ALTER LOGIN to SA_PASSWORD."
            $connectPassword = $installPassword
            $ready = $true
            break
        }
        $probe = $probe + $probe2
    }

    # Script upgrade mode: after a CU/GDR base bump (engine newer than the DBs
    # on the volume), SQL Express runs upgrade scripts on master/msdb/model and
    # the user DBs and rejects every login with error 18401 ("Server is in
    # script upgrade mode...") until done -- can take many minutes. Exiting here
    # restart-loops the container and corrupts the half-upgraded DBs, so when we
    # see that signal we wait with NO timeout: the engine is alive, progressing.
    if ($probe -match 'script upgrade mode|upgrade script|18401') {
        Write-Host "SQL Server is in script upgrade mode (applying upgrade scripts); waiting -- timeout suspended ($elapsed s elapsed)..."
        $elapsed = 0
        Start-Sleep -Seconds 5
        continue
    }

    $elapsed += 2
    if ($elapsed -ge $startupTimeout) {
        Write-Host "ERROR: SQL Server did not become ready after $startupTimeout s (not in upgrade mode)." -ForegroundColor Red
        Write-Host "  Last probe output: $probe"
        exit 1
    }
    Start-Sleep -Seconds 2
}

if ($connectPassword -ne $saPassword) {
    Write-Host "Updating sa password to match SA_PASSWORD..."
    sqlcmd -S $sqlInstance -U sa -P $connectPassword -C -Q "ALTER LOGIN sa WITH PASSWORD = '$saPassword'"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: ALTER LOGIN sa failed." -ForegroundColor Red
        exit 1
    }
}

# Disable Windows password policy on sa so failed healthcheck attempts
# (or test logins) can't lock the account out. SQL Express on Windows
# Server inherits the host's lockout policy by default; a few wrong
# passwords from compose's healthcheck poll is enough to lock sa, after
# which the correct password is rejected until manual UNLOCK. CHECK_POLICY
# also disables expiry and complexity checks -- fine for containerized
# dev/test instances. Production should set this explicitly.
sqlcmd -S $sqlInstance -U sa -P $saPassword -C -Q "ALTER LOGIN sa WITH CHECK_POLICY = OFF" *> $null

Write-Host "Enabling remote access..."
sqlcmd -S $sqlInstance -U sa -P $saPassword -C -Q "EXEC sp_configure 'remote access', 1; RECONFIGURE;" *> $null

if ($restoreDbs -eq '0') {
    Write-Host "RESTORE_DBS=0 -- skipping restore/attach pass."
}
elseif (-not (Test-Path $backupDir)) {
    Write-Host "WARN: backup dir $backupDir does not exist -- nothing to restore."
}
else {
    # Discover *.bak in the mounted backup dir. DB name = filename stem.
    # New .bak files get picked up on next start.
    $baks = Get-ChildItem -Path $backupDir -Filter *.bak -File -ErrorAction SilentlyContinue
    if (-not $baks) {
        Write-Host "No *.bak files in $backupDir -- nothing to do."
    }

    # Why ATTACH-then-RESTORE instead of always-RESTORE:
    #   master DB lives in the container filesystem (NOT the C:\sql-data
    #   volume). On `docker compose down` + `up` the container is recreated,
    #   master gets a fresh copy, and master no longer knows any user DBs
    #   exist. The previous logic responded by issuing `RESTORE … WITH
    #   REPLACE` against the still-present .mdf/.ldf files on the volume —
    #   which CLOBBERED them with the .bak content, wiping every row the
    #   operator had added at runtime (accounts, characters, GM edits).
    #
    #   New logic: if the .mdf/.ldf are already on disk (= we've booted
    #   before), `CREATE DATABASE … FOR ATTACH` re-registers them in master
    #   without touching their contents. Only when the data files are
    #   genuinely missing (first boot, or operator nuked C:\sql-data) do
    #   we fall through to a real RESTORE.
    #
    #   Override: FORCE_RESTORE_DBS=1 ignores existing files and re-restores
    #   from .bak. Use this when the operator updated their .bak and wants
    #   a fresh import; otherwise leave it alone.

    $forceRestore = $env:FORCE_RESTORE_DBS -eq '1'

    foreach ($bak in $baks) {
        $db = [System.IO.Path]::GetFileNameWithoutExtension($bak.Name)
        $bakPath = $bak.FullName

        # Skip if already registered (multi-run idempotency within one boot).
        $dbCount = sqlcmd -S $sqlInstance -U sa -P $saPassword -C -h -1 -W `
            -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$db'" 2>&1 |
            Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1

        if ($dbCount -and $dbCount.Trim() -eq '1') {
            Write-Host "Database '$db' already registered -- skipping."
            continue
        }

        # Look up the logical-name → on-disk-path mapping from the .bak.
        # We use this for both ATTACH (to find existing files) and RESTORE
        # (to build the MOVE clause).
        $fileList = sqlcmd -S $sqlInstance -U sa -P $saPassword -C `
            -Q "RESTORE FILELISTONLY FROM DISK = '$bakPath'" -s "|" -W -h -1 2>&1

        $expectedFiles = @()  # [{logical, type, path}, ...]
        $dataIdx = 0
        $logIdx = 0
        foreach ($line in $fileList) {
            $parts = $line -split '\|'
            if ($parts.Count -lt 3) { continue }
            $logicalName = $parts[0].Trim()
            $type = $parts[2].Trim()
            if ($type -eq 'D') {
                $suffix = if ($dataIdx -eq 0) { '' } else { "_$dataIdx" }
                $expectedFiles += [PSCustomObject]@{
                    Logical = $logicalName
                    Type    = 'D'
                    Path    = "$dataDir\${db}${suffix}.mdf"
                }
                $dataIdx++
            }
            elseif ($type -eq 'L') {
                $suffix = if ($logIdx -eq 0) { '' } else { "_$logIdx" }
                $expectedFiles += [PSCustomObject]@{
                    Logical = $logicalName
                    Type    = 'L'
                    Path    = "$dataDir\${db}${suffix}_log.ldf"
                }
                $logIdx++
            }
        }

        $allFilesPresent = $expectedFiles.Count -gt 0 -and
                           ($expectedFiles | Where-Object { -not (Test-Path $_.Path) } | Measure-Object).Count -eq 0

        if ($allFilesPresent -and -not $forceRestore) {
            # ATTACH path -- preserves all runtime data in the .mdf/.ldf.
            # Syntax: CREATE DATABASE [db] ON (FILENAME = '…'), … FOR ATTACH
            $onClause = ($expectedFiles | ForEach-Object { "(FILENAME = '$($_.Path)')" }) -join ", "
            $sql = "CREATE DATABASE [$db] ON $onClause FOR ATTACH"
            Write-Host "Attaching '$db' from existing data files..."
            $attachOut = sqlcmd -S $sqlInstance -U sa -P $saPassword -C -Q $sql 2>&1
            $attachStr = $attachOut | Out-String
            if ($attachStr -match 'Msg \d+, Level 1[6-9]') {
                Write-Host "ERROR attaching '$db':" -ForegroundColor Red
                Write-Host $attachStr
                Write-Host "  Falling back to RESTORE WITH REPLACE (will clobber data files)." -ForegroundColor Yellow
                # Fall through to restore below.
            } else {
                Write-Host "Database '$db' attached."
                continue
            }
        }

        # RESTORE path -- first boot, missing files, or FORCE_RESTORE_DBS=1.
        Write-Host "Restoring '$db' from $bakPath..."
        $moveClause = ($expectedFiles | ForEach-Object { "MOVE '$($_.Logical)' TO '$($_.Path)'" }) -join ", "
        $sql = if ($moveClause -eq "") {
            "RESTORE DATABASE [$db] FROM DISK = '$bakPath' WITH REPLACE"
        } else {
            "RESTORE DATABASE [$db] FROM DISK = '$bakPath' WITH REPLACE, $moveClause"
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

# Signal readiness to the docker HEALTHCHECK: restores/attaches are done and
# the server is fully serving. Until this exists the healthcheck fails, so
# `depends_on: condition: service_healthy` holds the DB-bridge containers.
New-Item -ItemType File -Path $readyMarker -Force | Out-Null

# Keep the container alive by tailing the ERRORLOG. SQL 2022 = MSSQL16,
# 2025 = MSSQL17 -- discover whichever exists.
$logFile = Get-ChildItem 'C:\Program Files\Microsoft SQL Server\MSSQL*.SQLEXPRESS\MSSQL\Log\ERRORLOG' `
    -ErrorAction SilentlyContinue | Select-Object -First 1

if ($logFile -and (Test-Path $logFile.FullName)) {
    Get-Content -Path $logFile.FullName -Wait
} else {
    while ($true) { Start-Sleep -Seconds 60 }
}
