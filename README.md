# fiesta-docker -- bring-your-own runtime container for Fiesta Online servers

A clean, generic container image for running a Fiesta Online server process
(`Login.exe`, `Zone.exe`, `Account.exe`, etc.). The image ships **no game
files** -- you mount your server folder at runtime and tell it which exe to
run. The same interface works on both **Linux** (via Wine) and **Windows**
(native).

```
docker run --rm --network host \
    -v /path/to/Server:/fiesta \
    -v /path/to/Server/9Data/ServerInfo:/fiesta/9Data/ServerInfo \
    -e SA_PASSWORD=YourStrongPassword1 \
    fiesta-server-runtime:latest \
    Login/Login.exe
```

For the full 13-container stack (SQL Server + 11 game processes + GamigoZR),
see [`example/`](example/).

## What's in the image

| Layer             | Linux (Ubuntu 24.04)              | Windows (Server Core ltsc2022)           |
|-------------------|-----------------------------------|------------------------------------------|
| Runtime           | Wine + 32-bit WoW64 + Mono        | VC++ 2015-2022 x86 redistributable       |
| SQL driver        | unixODBC + FreeTDS (32-bit)       | Microsoft ODBC Driver 17 for SQL Server  |
| Required registry | `Fantasy\*` + `GBO\*` set at startup | same                                  |
| Entrypoint        | `/usr/local/bin/start.sh`         | `C:\start.ps1`                           |

What's **not** in the image: any of `9Data/`, `Login/`, `Zone*/`, `Account/`,
`GamigoZR/`, `ServerInfo.txt`, or any other Fiesta-derived files. You bring
those yourself at run time.

## Runtime interface

The exe to launch is the trailing CMD arg (or `FIESTA_EXE` env var). Everything
else is configured via env vars:

| Env var          | Default                              | Description |
|------------------|--------------------------------------|-------------|
| `FIESTA_PATH`    | `/fiesta` (Linux), `C:\fiesta` (Windows) | Mount point inside the container where your server folder lives. |
| `FIESTA_EXE`     | (use trailing CMD arg)               | Relative path from `FIESTA_PATH` to the exe to launch. Examples: `Zone01/Zone.exe`, `Login\Login.exe`. Either slash works. |
| `PUBLIC_IP`      | _(unset)_                            | If set, the IP field in every `SERVER_INFO` row whose trailing comment says `PUBLIC_IP` (the client-facing rows) is rewritten to this value. `LOCALHOST`-tagged rows stay `127.0.0.1`. Labels and ports are never touched. |
| `SQL_HOST`       | `127.0.0.1`                          | SQL Server hostname for the ODBC rewrite. Works with host networking + SQL on the same host. |
| `SQL_PORT`       | `1433`                               | SQL Server port. |
| `SA_PASSWORD`    | _(unset)_                            | If set, replaces `PWD=` values in `ODBC_INFO` rows. |
| `ODBC_DRIVER`    | `SQL Server` (Linux) / `ODBC Driver 17 for SQL Server` (Windows) | ODBC driver name inserted into `DRIVER={...}`. |
| `START_GAMIGOZR` | `auto`                               | `auto` = start GamigoZR iff the target exe is `Zone.exe`. `1` = always, `0` = never. Use `0` when running a dedicated `gamigozr` container. |
| `GAMIGOZR_DIR`   | `GamigoZR`                           | Subfolder under `FIESTA_PATH` containing `GamigoZR.exe`. |
| `SERVICE_NAME`   | `_<dirname>`                         | Override the Wine SCM / Windows service name (default derives from `dirname(FIESTA_EXE)`). |
| `KEEP_ALIVE`     | `0`                                  | `1` keeps the container alive after the game process exits, so you can `docker exec` in to investigate. |

## Mount layout the entrypoint expects

```
<FIESTA_PATH>/
|-- 9Data/                        # game data, configs (ServerInfo/, Shine/, ...)
|-- GamigoZR/GamigoZR.exe         # anti-cheat (needed for Zone.exe)
|-- Login/Login.exe
|-- Account/Account.exe
|-- AccountLog/AccountLog.exe
|-- Character/Character.exe
|-- GameLog/GameLog.exe
|-- WorldManager/WorldManager.exe
|-- Zone00/Zone.exe ... Zone04/Zone.exe   # any zone name works
\-- ...
```

This is the same as the standard ServerSource layout, so you can mount it
unmodified.

## What the entrypoint actually rewrites

Default-shape `ServerInfo.txt` from ServerSource has three things that need
fixing before the server boots:

- `DRIVER={SQL Server};SERVER=.\SQLEXPRESS;UID=sa;PWD=<hardcoded-default>`
  in every `ODBC_INFO` row.
- Hardcoded `127.0.0.1` for every `SERVER_INFO` IP (works for in-host
  traffic but external clients need the public IP).

The runtime walks `#include` directives from the per-process config dir
(`Login/LoginServerInfo.txt`, `Zone01/ZoneServerInfo/ZoneServerInfo.txt`, ...)
and rewrites the included files at their natural paths:

- `SERVER=.\SQLEXPRESS` -> `SERVER=${SQL_HOST},${SQL_PORT}` (always, since
  the named-instance reference doesn't work via FreeTDS or modern ODBC).
- `DRIVER={SQL Server}` -> `DRIVER={${ODBC_DRIVER}}` (only on Windows where
  the legacy driver isn't installed).
- `PWD=<old>` -> `PWD=${SA_PASSWORD}` (only when `SA_PASSWORD` is set).
- The IP on `SERVER_INFO` rows tagged `; PUBLIC_IP` -> `${PUBLIC_IP}` (only
  when `PUBLIC_IP` is set). `; LOCALHOST` rows are untouched. Labels and
  ports are never modified.

The rewrite is idempotent -- running the container twice produces the same
output. The included files must be writable: either mount the whole server
folder read-write, or per-container overlay-mount `9Data/ServerInfo/`. The
operator decides. The image never copies files around behind your back.

If you don't want any of these rewrites, simply don't set the env vars and
keep your existing `ODBC_INFO` strings free of `.\SQLEXPRESS` -- the
entrypoint will then leave your configs alone.

## Per-container writable directories

The Fiesta exes write to a couple of files at runtime. With multiple
containers sharing the same `${FIESTA_PATH}` mount, the recommended pattern
is to overlay-mount the dirs that need per-container writes:

- **`9Data/ServerInfo/`** -- holds `_ServerGroup.txt` (written per service)
  and `ServerInfo.txt` (rewritten per container). Overlay per service.
- **`9Data/SubAbStateClass.txt`** -- written by `Zone.exe` on startup. If
  the `9Data/` mount is read-write, it lives there; otherwise overlay its
  parent.

Windows containers **only support directory-level bind mounts** (not single
files), which is why `ServerInfo.txt` and `_ServerGroup.txt` are isolated as
a whole `9Data/ServerInfo/` directory.

The `example/docker-compose.yml` shows this pattern with an `init` service
that seeds the per-container overlay dirs once.

## Quick start

### Linux

```bash
docker run --rm --network host \
    -v /path/to/Server:/fiesta \
    -v /path/to/Server/9Data/ServerInfo:/fiesta/9Data/ServerInfo \
    -e SA_PASSWORD=YourStrongPassword1 \
    fiesta-server-runtime:linux \
    Login/Login.exe
```

### Windows

```powershell
docker run --rm `
    -v C:\Server:C:\fiesta `
    -v C:\Server\9Data\ServerInfo:C:\fiesta\9Data\ServerInfo `
    -e SA_PASSWORD=YourStrongPassword1 `
    fiesta-server-runtime:windows `
    Login\Login.exe
```

### Any zone name

```bash
# Launch a zone called "MyZone" (folder MyZone/, exe Zone.exe inside it).
docker run --rm --network host \
    -v /path/to/Server:/fiesta \
    -v /path/to/Server/9Data/ServerInfo:/fiesta/9Data/ServerInfo \
    -e SA_PASSWORD=YourStrongPassword1 \
    fiesta-server-runtime:linux \
    MyZone/Zone.exe
```

The image doesn't care about zone numbering. `Zone00`, `Zone01`, `Wasteland`,
or anything else works as long as the directory contains `Zone.exe`.

## Building

### Linux only (local)

```bash
./build.sh
# -> fiesta-server-runtime:linux
```

### Windows only (local)

```powershell
# Switch Docker Desktop to "Windows containers" first.
.\build.ps1
# -> fiesta-server-runtime:windows
```

### True multi-platform manifest

Windows images must be built on a Windows Docker host, so the multi-arch
manifest is stitched in three steps:

```bash
# 1. On a Linux host
./build.sh --push ghcr.io/you/fiesta-server-runtime:latest

# 2. On a Windows host (Docker Desktop in Windows-container mode)
.\build.ps1 -Push ghcr.io/you/fiesta-server-runtime:latest

# 3. On either host
./combine-manifest.sh ghcr.io/you/fiesta-server-runtime:latest

# Verify
docker buildx imagetools inspect ghcr.io/you/fiesta-server-runtime:latest
```

After this, `docker pull ghcr.io/you/fiesta-server-runtime:latest` fetches
the linux or windows variant automatically based on the host's OS.

## How startup works

1. Parse the trailing CMD arg / `FIESTA_EXE` into directory + exe name.
2. Verify the mount and exe exist; print the folder listing on failure.
3. Walk `#include` directives in `${FIESTA_PATH}/<process-dir>/*.txt` and
   rewrite the targets in place (see "What the entrypoint actually rewrites"
   above).
4. Set the `Fantasy\Fighter` and `GBO\*` registry keys the Fiesta exes
   check at startup.
5. (Zones only, or when `START_GAMIGOZR=1`) Register and start the
   `GamigoZR` service from `${FIESTA_PATH}/${GAMIGOZR_DIR}/GamigoZR.exe`.
6. `cd` to the process directory.
7. Register the game exe as a Windows service (`_<dirname>` by default)
   via `sc.exe` (Wine SCM on Linux, native SCM on Windows) and start it.
   Running the exe directly would block on `StartServiceCtrlDispatcher()`.
8. Tail any `.txt` log files the exe writes (`Msg_*`, `Dbg.txt`,
   `*CallStack*.txt`, `DebugMessage/*`, plus a `stdout.txt` capture on
   Linux).
9. Watch the service / process; the container exits when the process dies
   (unless `KEEP_ALIVE=1`).

## Notes and gotchas

- **`network_mode: host`** is the easy path on Linux: every service binds
  the ports it needs on the host and inter-process traffic stays on
  `127.0.0.1`. The default config works as-is.
- **Mount must be read-write** wherever the exe writes (the process subdir
  for logs and `DebugMessage/`, and `9Data/` for `SubAbStateClass.txt`).
- **Windows bind mounts are directory-only.** When isolating a single file,
  put it in its own directory.
- **GamigoZR is yours.** The image doesn't bundle any anti-cheat. The
  `GamigoZR.exe` in the standard ServerSource layout is the one
  `START_GAMIGOZR=auto` expects.
- **Windows build needs `set DOCKER_BUILDKIT=0`** before `docker build`
  because BuildKit doesn't support Windows containers. `build.ps1` handles
  this.
- **Linux Wine prefix is pre-initialised** at image build time (with Mono
  and the ODBC override). First-run cost is paid once at build, not every
  container start.

## Repo layout

```
.
|-- Dockerfile.linux         # Ubuntu 24.04 + Wine
|-- Dockerfile.windows       # Server Core ltsc2022
|-- start.sh                 # Linux entrypoint
|-- start.ps1                # Windows entrypoint
|-- build.sh                 # local Linux build (+ optional --push)
|-- build.ps1                # local Windows build (+ optional -Push)
|-- combine-manifest.sh      # stitch the multi-arch manifest after both pushes
\-- example/                 # full 13-container stack against ServerSource
    |-- docker-compose.yml
    \-- README.md
```
