# ik-fiesta-docker — BYO runtime container for Fiesta Online servers

A generic container image for running a Fiesta Online server process
(`Login.exe`, `Zone.exe`, `Account.exe`, ...). The image ships **no game
files** — you mount your `ServerSource`-shaped tree at runtime and tell
it which exe to run. Two flavours, one contract:

- **Linux** (Ubuntu 24.04 + Wine, 32-bit WoW64, unixODBC + FreeTDS)
- **Windows** (Server Core ltsc2022 + VC++ x86 redistributable + ODBC)

Three images make up a full deployment:

| Image | Purpose |
|-------|---------|
| `fiesta-server-runtime` | runs one game exe (Login, WM, Zone, DB bridge). S2S proxy baked in. |
| `fiesta-sql-runtime`    | SQL Server with `.bak` auto-restore (operator-mounted `Databases/`). |
| `fiesta-proxy`          | client-facing rewriting proxy. The only public-facing container in a deployment. |

The full 11-container stack (SQL + DB bridges + Login + WM + five Zones +
proxy) lives in [`example/`](example/) — parallel compose files for
Windows and Linux containers.

---

## Using it

The same images work two ways: pull from a registry, or build locally.
Pick whichever fits — both feed into the same compose files in `example/`.

### Option A: Pull from a registry (recommended)

Three multi-arch image refs to point your deployment at:

```bash
docker pull ghcr.io/your-owner/fiesta-server-runtime:latest
docker pull ghcr.io/your-owner/fiesta-sql-runtime:latest
docker pull ghcr.io/your-owner/fiesta-proxy:latest
```

The example compose forwards three env vars to the matching services, so
the operator just sets them in `.env`:

```ini
RUNTIME_IMAGE=ghcr.io/your-owner/fiesta-server-runtime:latest
SQL_IMAGE=ghcr.io/your-owner/fiesta-sql-runtime:latest
PROXY_IMAGE=ghcr.io/your-owner/fiesta-proxy:latest
```

Then follow the operator quickstart in [`example/README.md`](example/README.md):
clone, drop in your BYO bits (`ServerSource/`, optional GamigoZR crypt
blob, optional XOR table), `cp .env.example .env`, edit, `docker compose
up -d`.

### Option B: Build the images yourself

Skip the `RUNTIME_IMAGE` / `SQL_IMAGE` / `PROXY_IMAGE` env vars (the
compose files default to local-built tags `fiesta-server-runtime:latest`
etc.) and run the three build commands from [Building your own base
images](#building-your-own-base-images). Useful when:

- you want to modify the proxy / startup scripts and test locally,
- you're on an air-gapped network,
- you want a specific Wine / .NET / SQL Server version pinned by your
  own Dockerfile edits.

The example compose then picks up your local `:latest` tags
automatically — nothing else changes.

### Single-process quickstart (no compose)

Mostly useful for smoke-testing the runtime image itself:

```bash
# Linux
docker run --rm --network host \
    -v /path/to/Server:/fiesta \
    -v /path/to/Server/9Data/ServerInfo:/fiesta/9Data/ServerInfo \
    -e SA_PASSWORD=YourStrongPassword1 \
    ghcr.io/your-owner/fiesta-server-runtime:latest \
    Login/Login.exe
```

```powershell
# Windows
docker run --rm `
    -v C:\Server:C:\fiesta `
    -v C:\Server\9Data\ServerInfo:C:\fiesta\9Data\ServerInfo `
    -e SA_PASSWORD=YourStrongPassword1 `
    ghcr.io/your-owner/fiesta-server-runtime:latest `
    Login\Login.exe
```

The image doesn't care about zone numbering — `Zone00/Zone.exe`,
`Wasteland/Zone.exe`, anything works as long as the directory contains
`Zone.exe`.

### Full stack (compose)

For the production deployment topology — bridge networking, baked-in
proxy, five zones, ODBC rewrites, GamigoZR stub per Zone — see
[`example/README.md`](example/README.md). The compose files there cover
both pulling from a registry (Option A) and building locally (Option B);
the operator picks via .env.

---

## Runtime interface

The exe to launch is the trailing `CMD` arg (or `FIESTA_EXE` env).
Everything else is env-var-driven:

| Env var          | Default                              | Description |
|------------------|--------------------------------------|-------------|
| `FIESTA_PATH`    | `/fiesta` (Linux), `C:\fiesta` (Windows) | Mount point inside the container where your server folder lives. |
| `FIESTA_EXE`     | (use trailing `CMD` arg)             | Relative path under `FIESTA_PATH`. Example: `Zone01/Zone.exe`. Either slash works. |
| `PUBLIC_IP`      | _(unset)_                            | If set, the IP in every `; PUBLIC_IP`-tagged `SERVER_INFO` row is rewritten to this value. `; LOCALHOST` rows untouched. |
| `SQL_HOST`       | `127.0.0.1`                          | SQL Server hostname for the ODBC rewrite. |
| `SQL_PORT`       | `1433`                               | SQL Server port. |
| `SA_PASSWORD`    | _(unset)_                            | If set, replaces `PWD=` values in `ODBC_INFO` rows. |
| `SQL_CONNECTION_STRING` | _(unset)_                     | If set, replaces the **entire** `DRIVER={...};SERVER=...;UID=...;PWD=...` field of every `ODBC_INFO` row verbatim. Wins over `SQL_HOST` / `SA_PASSWORD` / `ODBC_DRIVER`. The init query (`USE <db>; ...`) is preserved per row. |
| `ODBC_DRIVER`    | `SQL Server` (both platforms)        | ODBC driver name in `DRIVER={...}`. The 32-bit Fiesta exes can't load the x64-only Driver 17, so the legacy in-box driver is the default. |
| `START_GAMIGOZR` | `auto`                               | `auto` = start GamigoZR iff target exe is `Zone.exe`. `1` = always, `0` = never. |
| `GAMIGOZR_DIR`   | `GamigoZR`                           | Subfolder under `FIESTA_PATH` containing `GamigoZR.exe`. |
| `SERVICE_NAME`   | `_<dirname>`                         | Override the Wine SCM / Windows SCM service name. |
| `KEEP_ALIVE`     | `0`                                  | `1` keeps the container alive after the game exe exits, for `docker exec`. |
| `INTERNAL_HOST_<svc>` | _(unset)_                       | Per-service docker hostname for the s2s proxy rewrite. See `example/`. |
| `S2S_PROXY_DISABLED` | `0`                              | `1` skips the baked-in s2s proxy and rewrites every s2s row to the resolved peer IP at boot (the old behaviour). |

## Mount layout the entrypoint expects

```
<FIESTA_PATH>/
|-- 9Data/                        # game data + configs (ServerInfo/, Shine/, ...)
|-- GamigoZR/GamigoZR.exe         # anti-cheat (only needed for Zone.exe)
|-- Login/Login.exe
|-- Account/Account.exe
|-- AccountLog/AccountLog.exe
|-- Character/Character.exe
|-- GameLog/GameLog.exe
|-- WorldManager/WorldManager.exe
\-- Zone00/Zone.exe ... Zone04/Zone.exe   # any zone name works
```

Same shape as the standard `ServerSource` tree, mountable unmodified.

## What the entrypoint actually rewrites

The default-shape `ServerInfo.txt` from ServerSource has two things that
need fixing before the server boots:

- `DRIVER={SQL Server};SERVER=.\SQLEXPRESS;UID=sa;PWD=<hardcoded>` in
  every `ODBC_INFO` row (the named-instance reference doesn't work via
  FreeTDS / modern ODBC).
- Hardcoded `127.0.0.1` in every client-facing `SERVER_INFO` row.

The runtime walks `#include` directives from the per-process config dir
(`Login/LoginServerInfo.txt`, `Zone01/ZoneServerInfo/ZoneServerInfo.txt`,
...) and rewrites the included files in place:

- **SQL access** is picked by env-var presence, in this order:
  1. `SQL_CONNECTION_STRING` set → the entire connection-string field of
     every `ODBC_INFO` row is replaced verbatim. The init query
     (`"USE <db>; SET LOCK_TIMEOUT ..."`) is preserved per row.
  2. `SQL_HOST` set explicitly → `SERVER=` and `PWD=` are patched per row,
     the source's `DRIVER={...}` clause is preserved.
  3. neither → the default `SQL_HOST=127.0.0.1` is used (for the bundled
     SQL container at the compose DNS name `sqlserver`).
- The IP on `SERVER_INFO` rows tagged `; PUBLIC_IP` → `${PUBLIC_IP}`
  (only when `PUBLIC_IP` is set). Labels and ports never modified.
- The IP on `SERVER_INFO` rows tagged `; LOCALHOST` → the docker hostname
  read from `INTERNAL_HOST_<service-name>`, when set. Used by the
  bridge-networked example so s2s traffic crosses docker DNS instead of
  literal `127.0.0.1`.

The rewrite is idempotent — running the container twice produces the
same output. The included files must be writable: either mount the
whole server folder read-write, or per-container overlay-mount
`9Data/ServerInfo/`.

If you don't want any of these rewrites, simply don't set the env vars
and keep your existing `ODBC_INFO` strings free of `.\SQLEXPRESS` — the
entrypoint becomes a no-op.

## Per-container writable directories

Fiesta exes write to a couple of files at runtime. With multiple
containers sharing the same `FIESTA_PATH` mount, the recommended pattern
is to overlay-mount the dirs that need per-container writes:

- **`9Data/ServerInfo/`** — `_ServerGroup.txt` (per service) and
  `ServerInfo.txt` (rewritten per container). Overlay per service.
- **`9Data/SubAbStateClass.txt`** — written by `Zone.exe` on startup.

Windows containers **only support directory-level bind mounts** (not
single files), which is why `ServerInfo.txt` and `_ServerGroup.txt`
share their parent dir as the isolation unit.

The example compose files demonstrate this: each runtime container
self-seeds its own `9Data/ServerInfo/` overlay on boot from a read-only
second mount of the same ServerSource tree.

---

## Building your own base images

You'd build locally if you need to modify the runtime / proxy / SQL
image (custom drivers, patched startup scripts, air-gapped deploy),
otherwise pulling from a registry is the easier path. The example
compose files work either way without edits — they default to the
local-built `:latest` tags, and pulling from a registry only changes
which tags those refs resolve to via `RUNTIME_IMAGE` / `SQL_IMAGE` /
`PROXY_IMAGE` env vars.

### Local Linux build

```bash
docker build -t fiesta-server-runtime:latest -f Dockerfile.linux .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.linux .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile lib/fiesta-proxy
```

A convenience wrapper exists at `./build.sh` (runtime image only;
optional `--push` for registry upload).

### Local Windows build

Docker Desktop in **Windows-containers** mode, then:

```powershell
docker build -t fiesta-server-runtime:latest -f Dockerfile.windows .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.windows .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile.windows lib/fiesta-proxy
```

`.\build.ps1` wraps the runtime build (sets `DOCKER_BUILDKIT=0` because
BuildKit doesn't support Windows containers).

> **Heads-up:** if Docker Desktop's experimental *Host networking* toggle
> is on, `docker build` can't reach apt mirrors and hangs forever.
> Toggle it OFF for the build, then back ON if you actually need it.

### Multi-arch manifest (registry push)

Windows and Linux images must be built on their respective platforms, so
the multi-arch manifest is stitched in three steps:

```bash
# 1. On a Linux host
./build.sh --push ghcr.io/you/fiesta-server-runtime:latest

# 2. On a Windows host (Docker Desktop in Windows-containers mode)
.\build.ps1 -Push ghcr.io/you/fiesta-server-runtime:latest

# 3. On either host
./combine-manifest.sh ghcr.io/you/fiesta-server-runtime:latest

# Verify
docker buildx imagetools inspect ghcr.io/you/fiesta-server-runtime:latest
```

After this, `docker pull ghcr.io/you/fiesta-server-runtime:latest`
fetches the linux or windows variant automatically per the host OS.

Equivalent recipe for the SQL and proxy images — same three steps,
different Dockerfile and tag.

### Where the Dockerfiles live

| File | Builds |
|------|--------|
| `Dockerfile.linux` | `fiesta-server-runtime` (Linux/Wine variant) |
| `Dockerfile.windows` | `fiesta-server-runtime` (Windows native) |
| `Dockerfile.sql.linux` | `fiesta-sql-runtime` (Linux) |
| `Dockerfile.sql.windows` | `fiesta-sql-runtime` (Windows) |
| `lib/fiesta-proxy/Dockerfile` | `fiesta-proxy` (Linux) |
| `lib/fiesta-proxy/Dockerfile.windows` | `fiesta-proxy` (Windows) |

---

## How startup works

1. Parse trailing `CMD` arg / `FIESTA_EXE` into directory + exe name.
2. Verify the mount and exe exist; print the folder listing on failure.
3. Walk `#include` directives in `${FIESTA_PATH}/<process-dir>/*.txt`
   and rewrite the targets per the rules above.
4. Set the `Fantasy\Fighter` and `GBO\*` registry keys the exes check.
5. Start the baked-in s2s proxy (`FiestaProxy.dll`) — unless
   `S2S_PROXY_DISABLED=1`.
6. (Zones only, or `START_GAMIGOZR=1`) Register and start `GamigoZR` via
   the SCM.
7. Register the game exe as a service (`_<dirname>` by default) via
   `sc.exe` (Wine SCM on Linux, native SCM on Windows). Direct exec
   would block on `StartServiceCtrlDispatcher()`.
8. Tail any `.txt` log files the exe writes (`Msg_*`, `Dbg.txt`,
   `*CallStack*.txt`, `DebugMessage/*`, plus a `stdout.txt` capture on
   Linux).
9. Watch the service / process; the container exits when the process
   dies (unless `KEEP_ALIVE=1`).

## Notes and gotchas

- **Bridge networking + baked-in `fiesta-proxy`** is the model the
  example uses. Only the proxy container publishes ports to the host;
  every runtime container reaches its peers by docker DNS on the
  internal bridge. The proxy rewrites WM/Zone endpoints in
  `WORLDSELECT_ACK` / `CHAR_LOGIN_ACK` to point back at `PUBLIC_IP`, so
  external clients only ever see one address. Works identically on
  Docker Desktop and native Linux Docker — no `network_mode: host`
  needed, no Host networking toggle, no LAN-IP gymnastics.
- **Mount must be read-write** wherever the exe writes (process subdir
  for logs and `DebugMessage/`, `9Data/` for `SubAbStateClass.txt`).
- **Windows bind mounts are directory-only.** When isolating a single
  file, put it in its own directory.
- **GamigoZR is yours.** The image ships no anti-cheat. The
  `GamigoZR.exe` from the standard ServerSource layout is what
  `START_GAMIGOZR=auto` expects.
- **Linux Wine prefix is pre-initialised** at image build time (with
  Mono and the ODBC override). First-run cost is paid once at build,
  not every container start.

## Repo layout

```
.
|-- Dockerfile.linux         # Ubuntu 24.04 + Wine
|-- Dockerfile.windows       # Server Core ltsc2022
|-- Dockerfile.sql.linux     # SQL Server 2022 on Linux
|-- Dockerfile.sql.windows   # SQL Server Express on Windows
|-- start.sh                 # Linux entrypoint
|-- start.ps1                # Windows entrypoint
|-- setup-sql.sh             # auto-restore for fiesta-sql-runtime (Linux)
|-- setup-sql.ps1            # auto-restore for fiesta-sql-runtime (Windows)
|-- build.sh                 # local Linux runtime build (+ optional --push)
|-- build.ps1                # local Windows runtime build (+ optional -Push)
|-- build-sql.sh             # local Linux SQL build
|-- build-sql.ps1            # local Windows SQL build
|-- combine-manifest.sh      # stitch multi-arch manifest after both pushes
|-- lib/fiesta-proxy/        # submodule: client-facing + s2s proxy
\-- example/                 # full 11-container stack against ServerSource
    |-- README.md            # operator quickstart for both platforms
    |-- windows/             # Docker Desktop in Windows-containers mode
    |   |-- docker-compose.yml
    |   \-- .env.example
    \-- linux/               # Docker on Linux (or Docker Desktop, Linux mode)
        |-- docker-compose.yml
        \-- .env.example
```
