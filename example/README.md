# `example/` — full Fiesta server stack on Docker Compose

Two parallel compose files for the same 11-container stack:

| Path | Engine | Runtime |
|------|--------|---------|
| `windows/docker-compose.yml` | Docker Desktop in **Windows-containers** mode | native (`Server Core ltsc2022`) |
| `linux/docker-compose.yml`   | Docker on Linux (or Docker Desktop Linux mode) | Wine (`Ubuntu 24.04` + `wine64`) |

Both bring up the same logical topology:

```
                          host (publishes 9010, 9013, 9016, 9019, 9022, 9025, 9028)
                                                  |
                                              proxy  <-- rewrites WM/Zone endpoints to PUBLIC_IP
                                                  |
       login - worldmanager - zone00 .. zone04   <-- reached only on the internal docker bridge
         |          |              |
       account  accountlog     character  gamelog  <-- DB bridge processes
         |          |              |          |
                          sqlserver           <-- SQL Server 2022 Express, host bind-mount
```

The runtime image ships **no game files** — you mount your own `ServerSource`
tree, GamigoZR crypt blob, and (optionally) XOR table at runtime.

## Quickstart

### 1. Build the three images

From the repo root (`fiesta-docker/`):

**Windows containers:**

```powershell
docker build -t fiesta-server-runtime:latest -f Dockerfile.windows .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.windows .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile.windows lib/fiesta-proxy
```

**Linux containers:**

```bash
docker build -t fiesta-server-runtime:latest -f Dockerfile.linux .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.linux .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile lib/fiesta-proxy
```

> **Windows-host gotcha:** if Docker Desktop's experimental *Host networking*
> toggle is on, `docker build` can't reach apt mirrors. Toggle it OFF for the
> build, then back ON for `compose up`. (Bridge networking, which the
> example uses, doesn't actually need the toggle — but if you flipped it on
> for an earlier experiment, this is the bite.)

### 2. Bring your own (BYO) bits

Three things you provide; none ship with the image.

**Your ServerSource tree.** Anywhere on the host; an absolute path. Must
look like:

```
ServerSource/
|-- 9Data/
|-- Account/Account.exe
|-- AccountLog/AccountLog.exe
|-- Character/Character.exe
|-- GameLog/GameLog.exe
|-- Login/Login.exe
|-- WorldManager/WorldManager.exe
|-- Zone00/Zone.exe ... Zone04/Zone.exe
|-- GamigoZR/GamigoZR.exe
\-- Databases/                           # .bak files restored on first SQL boot
```

**GamigoZR crypt blob (optional).** Each Zone container runs a tiny HTTP
stub that serves a pre-extracted GamigoZR response. To get the blob:

```powershell
# Run real GamigoZR.exe once on any Windows host; then:
curl http://127.0.0.1:58492/ > response.txt
```

Drop `response.txt` into `windows/gamigozr-blob/` (or `linux/gamigozr-blob/`).
Without it Zones still come up but reject every player handshake.

**XOR table (optional).** The proxy reads the client-to-server cipher table
to decrypt C→S packets for logging. The proxy works without it — the only
cost is that C→S log lines show ciphertext. To use one, drop your table
file into `windows/xor/xor.hex` and set `XOR_TABLE_PATH=C:\xor\xor.hex` in
your `.env`. Or pass the table inline via `XOR_TABLE_HEX=…`.

### 3. Pick your platform and configure

```powershell
# Windows
cd example\windows
copy .env.example .env
notepad .env
```

```bash
# Linux
cd example/linux
cp .env.example .env
$EDITOR .env
```

Fill in the three required values: `FIESTA_SERVER` (path to your
ServerSource), `SA_PASSWORD`, `PUBLIC_IP`.

### 4. Up

```bash
docker compose up -d
docker compose ps
docker compose logs -f login
```

First boot takes a couple of minutes — `sqlserver` restores every `.bak`
in `Databases/`, then the DB bridges connect, then `login` /
`worldmanager` / `zone00..04` register their s2s peers via the
marker-protocol health-gate, then the proxy starts accepting players.

Point a Fiesta client at `PUBLIC_IP:9010` and log in.

### 5. Down

```bash
docker compose down            # stops + removes containers; database is safe
docker compose down -v         # also wipes named volumes (but we don't use any
                               # for DB data — sql-data is a bind mount, so this
                               # is still safe in this example)
rm -rf sql-data                # this is the only way to delete the database
```

## Database persistence

DB files live in `./sql-data/` on the host (bind mount, not a named
volume). This is intentional:

- `docker compose down`            → safe
- `docker compose down -v`         → safe (we don't use named volumes)
- `docker volume rm …`             → safe (nothing to rm)
- `rm -rf ./sql-data`              → **this is the only way to nuke the DB**

The `fiesta-sql-runtime` image's setup script `ATTACH`es existing files on
recycle and only `RESTORE`s on genuine first boot, so `down`/`up` preserves
characters even though SQL Express's own `master` DB doesn't survive
container destruction. To force a fresh restore from your `.bak` files,
delete `sql-data/` and bring the stack back up.

## Using an external SQL Server (BYO-SQL)

The bundled `sqlserver` container is one of three options. The runtime
image's `ServerInfo.txt` rewrite picks between them by env-var presence,
in this priority order:

| Tier | Env to set | Effect |
|------|-----------|--------|
| 1 — full string | `SQL_CONNECTION_STRING` | Replaces the entire `DRIVER={...};SERVER=...;UID=...;PWD=...` field of every `ODBC_INFO` row. Only the per-row init query (`USE <db>; SET LOCK_TIMEOUT ...`) is preserved. Use this when you need driver flags the lower tiers don't expose. |
| 2 — host + password | `SQL_HOST` (+ optional `SQL_PORT`, `SA_PASSWORD`) | Rewrites `SERVER=` and `PWD=` per row; leaves `DRIVER={...}` and everything else from your source `ServerInfo.txt` intact. |
| 3 — bundled (default) | nothing | `SQL_HOST` falls through to the docker DNS name `sqlserver` and the `bundled-sql` compose profile brings up the auto-restore SQL container. |

### Tier 1 — full ODBC string

Use when the lower tiers can't express what your SQL Server needs (e.g.
TLS, alternate driver, AAD auth):

```ini
COMPOSE_PROFILES=
SQL_CONNECTION_STRING=DRIVER={ODBC Driver 17 for SQL Server};SERVER=mydb.database.windows.net,1433;UID=sa;PWD=YourPassword;Encrypt=yes;TrustServerCertificate=yes
```

The driver name has to match what's installed inside the runtime image:

- **Linux/Wine runtime** ships only `{SQL Server}` (the legacy in-box
  driver bridged via FreeTDS). Driver 17 isn't there.
- **Windows containers runtime** ships only `{SQL Server}` too — the
  32-bit Fiesta exes can't load the x64-only Driver 17 MSI. If you need
  Driver 17, rebuild the runtime image with `Dockerfile.windows`
  extended to install the 32-bit MSI variant.

### Tier 2 — host + password

The lighter override. The runtime keeps your source ServerInfo's driver
clause and only patches `SERVER=` and `PWD=`:

```ini
COMPOSE_PROFILES=
SQL_HOST=your.sql.server.host
SQL_PORT=1433
SA_PASSWORD=YourSqlServerPassword
```

### Tier 3 — bundled container (default)

```ini
COMPOSE_PROFILES=bundled-sql
SA_PASSWORD=YourBundledSqlPassword
# SQL_HOST / SQL_PORT / SQL_CONNECTION_STRING all unset
```

### One-time setup on an external SQL Server (tier 1 or 2)

Before `docker compose up -d` with a non-bundled tier:

1. **Restore every `.bak` in `Databases/`** as a database with the
   matching name. Stock ServerSource ships:

    | .bak file              | Restored database name |
    |------------------------|------------------------|
    | `Account.bak`          | `Account`              |
    | `AccountLog.bak`       | `AccountLog`           |
    | `World00_Character.bak`| `World00_Character`    |
    | `World00_GameLog.bak`  | `World00_GameLog`      |
    | `StatisticsData.bak`   | `StatisticsData`       |
    | `OperatorTool.bak`     | `OperatorTool`         |

    The exact set comes from your `ODBC_INFO` rows in `ServerInfo.txt`.
    Restore via `sqlcmd`, SSMS, or Azure Data Studio.

2. **Make sure the connecting account has read+write on all six DBs.**
   The example assumes `sa`; if you use a non-sysadmin login, grant it
   `db_owner` (or finer-grained writes) on each fiesta database.

3. **Network reachability.** From inside a runtime container, `SQL_HOST`
   has to resolve and `SQL_PORT` has to be open. For Azure SQL that
   means firewall-allowing the docker host's outbound IP; for an on-prem
   box it usually Just Works because docker bridge networking NATs
   through the host.

`down -v` and `down` don't touch your external DB — that's its own
lifecycle. The "Database persistence" rules above only apply to the
bundled container.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `sqlserver` healthcheck never goes green | Wrong `SA_PASSWORD` (doesn't meet SQL Server's complexity policy) | 8+ chars, mixed classes; `docker compose logs sqlserver` shows the policy error |
| `account`/`character` restart loop | DB bridges booted before SQL ready-marker | Should not happen with image-baked healthcheck; check `docker compose logs sqlserver` for restore errors |
| `account` restart-loop on external SQL | DB not restored / wrong creds / firewall | Run `docker compose run --rm account sqlcmd -S $SQL_HOST -U sa -P $SA_PASSWORD -Q "SELECT name FROM sys.databases"` to verify the bridge can reach + authenticate; ensure all six DBs (Account, AccountLog, World00_Character, World00_GameLog, StatisticsData, OperatorTool) are present |
| Login screen shows world but join hangs | Proxy isn't rewriting WM endpoint, or `PUBLIC_IP` wrong | `docker compose logs proxy` should show the `WORLDSELECT_ACK [rewritten]` line; set `PROXY_PACKET_LOG=1` for per-packet trace |
| Client connects but Zone screen black | Missing/incorrect crypt blob | Drop `response.txt` into `gamigozr-blob/`; check `docker compose logs zone01` for HttpListener startup |
| Want to see every packet | | `PROXY_PACKET_LOG=1` in `.env`, `docker compose restart proxy`, `docker compose logs -f proxy` |

## Customising

- **Different zone count.** Trim or extend the `zoneNN` services + the
  matching `PROXY_ROUTES` entry. Each new zone needs an
  `INTERNAL_HOST_Zone_0_N` line in `*fiesta-env` and, for any zone slot
  you removed, an `INTERNAL_HOST_Zone_0_N=127.0.0.1` stub so start.ps1's
  DNS-rewrite skips that row instead of waiting 30s per missing peer.
  Stock `ServerInfo.txt` defines 5 zones; the example provisions all of them.
- **Different SQL port.** Set `SQL_PORT=…` in `.env`; both the runtime's
  ODBC rewrite and the bridge processes pick it up.
- **Remap external ports.** Change the `ports:` lines on the `proxy`
  service and set `EXTERNAL_PORT_<ServiceName>=<remapped>` for each one
  you moved; the proxy rewrites announcement packets accordingly.
- **Disable per-zone GamigoZR stub.** Set `START_GAMIGOZR=1` and remove the
  `CRYPT_BLOB` mount — start.ps1 then launches the real `GamigoZR.exe`
  service inside each Zone container.
