# ik-fiesta-docker — BYO runtime containers for Fiesta Online servers

Generic container images for running a Fiesta Online server. They ship **no game
files** — you mount your own **Fiesta server files** (the standard `9Data/` +
per-process exe tree the community calls "server files" / "files") at runtime and
tell each container which exe to run. Two flavours, one contract:

- **Linux** (Ubuntu 24.04 + Wine, 32-bit WoW64, unixODBC + FreeTDS)
- **Windows** (Server Core ltsc2022 + VC++ x86 redistributable + ODBC)

Three images make up a full deployment:

| Image | Purpose |
|-------|---------|
| `fiesta-server-runtime` | runs one game exe (Login, WM, Zone, DB bridge). S2S proxy baked in. |
| `fiesta-sql-runtime`    | SQL Server with `.bak` auto-restore (operator-mounted `Databases/`). |
| `fiesta-proxy`          | client-facing rewriting proxy. The only public-facing container in a deployment. |

The published images live under **`ikaronclaude`** on Docker Hub — use them as-is
if you don't want to build anything. The full 11-container stack (SQL + DB bridges
+ Login + WM + five Zones + proxy) lives in [`example/`](example/) — parallel
compose files for Windows and Linux containers.

---

## Using it

Two ways, both feeding the same compose files in `example/`: pull the published
images, or build your own.

### Option A: Pull the published images (recommended)

Just point your deployment at the `ikaronclaude` images — nothing to build:

```bash
docker pull ikaronclaude/fiesta-server-runtime:latest
docker pull ikaronclaude/fiesta-sql-runtime:latest
docker pull ikaronclaude/fiesta-proxy:latest
```

These are the compose defaults, so a fresh clone of `example/` runs against them
with no image config. (To use your own rebuilt images instead, set
`RUNTIME_IMAGE` / `SQL_IMAGE` / `PROXY_IMAGE` in `.env` to your own
owner/registry tags.)

Then follow the operator quickstart in [`example/README.md`](example/README.md):
clone, drop in your BYO bits (server files, your GamigoZR crypt blob, your XOR
table), `cp .env.example .env`, edit, `docker compose up -d`.

### Option B: Build the images yourself

Set `RUNTIME_IMAGE` / `SQL_IMAGE` / `PROXY_IMAGE` to your local tags (the compose
also defaults to local `fiesta-*-runtime:latest` tags if you leave them unset) and
run the builds in [Building your own images](#building-your-own-images). Useful to
modify the proxy / startup scripts, pin specific Wine/.NET/SQL versions, or build
air-gapped. **The proxy is open source** — see
[Bring your own proxy](#bring-your-own-proxy).

### Single-process quickstart (no compose, host networking)

Mostly useful for smoke-testing the runtime image itself. **This uses
`--network host`, not the proxy** — the exe binds the addresses in its
`SERVER_INFO` rows directly on the host's network, so it's the simplest way to
run one process but it does *not* give you the proxy's node-placement / client
rewriting. For the real topology use the compose stack (below).

```bash
# Linux
docker run --rm --network host \
    -v /path/to/server-files:/fiesta \
    -e SA_PASSWORD=YourStrongPassword1 \
    ikaronclaude/fiesta-server-runtime:latest \
    Login/Login.exe
```

```powershell
# Windows
docker run --rm `
    -v C:\server-files:C:\fiesta `
    -e SA_PASSWORD=YourStrongPassword1 `
    ikaronclaude/fiesta-server-runtime:latest `
    Login\Login.exe
```

You pick the exe with the trailing arg (here `Login/Login.exe`); the container
figures out *which* Fiesta service that is by reading the `MY_SERVER` line from
that process's own `ServerInfo` — not from the folder or exe name (see
[How startup works](#how-startup-works)).

### Full stack (compose)

For the production topology — bridge networking, baked-in proxy, five zones, ODBC
rewrites, the GamigoZR crypt-blob stub per Zone — see
[`example/README.md`](example/README.md). The compose files cover both pulling
(Option A) and building (Option B); the operator picks via `.env`.

---

## Runtime interface

The exe to launch is the trailing `CMD` arg (or `FIESTA_EXE` env). Everything else
is env-var-driven:

| Env var          | Default                              | Description |
|------------------|--------------------------------------|-------------|
| `FIESTA_PATH`    | `/fiesta` (Linux), `C:\fiesta` (Windows) | Mount point inside the container where your server files live. |
| `FIESTA_EXE`     | (use trailing `CMD` arg)             | Relative path under `FIESTA_PATH`. Example: `Zone01/Zone.exe`. Either slash works. |
| `PUBLIC_IP`      | _(unset)_                            | If set, the IP in every `; PUBLIC_IP`-tagged `SERVER_INFO` row is rewritten to this value. `; LOCALHOST` rows untouched. |
| `SQL_HOST`       | `127.0.0.1`                          | SQL Server hostname for the ODBC rewrite. |
| `SQL_PORT`       | `1433`                               | SQL Server port. |
| `SA_PASSWORD`    | _(unset)_                            | If set, replaces `PWD=` values in `ODBC_INFO` rows. |
| `SQL_CONNECTION_STRING` | _(unset)_                     | If set, replaces the **entire** connection-string field of every `ODBC_INFO` row verbatim. Wins over `SQL_HOST` / `SA_PASSWORD` / `ODBC_DRIVER`. The init query (`USE <db>; ...`) is preserved per row. |
| `ODBC_DRIVER`    | `SQL Server` (both platforms)        | ODBC driver name in `DRIVER={...}`. The 32-bit Fiesta exes can't load the x64-only Driver 17, so the legacy in-box driver is the default. |
| `CRYPT_BLOB_PATH`| `/etc/gamigozr/response.txt`         | The GamigoZR crypt blob the in-container stub serves to Zone clients. Mount your blob here (the example compose maps `gamigozr-blob/response.txt`). |
| `START_GAMIGOZR` | `auto`                               | `auto` = serve the GamigoZR crypt blob (via the baked-in stub) for `Zone.exe`. `1` = always, `0` = never. |
| `GAMIGOZR_DIR`   | `GamigoZR`                           | **Legacy** — subfolder holding the old `GamigoZR.exe`, used only as a fallback if no crypt blob is mounted (and it generally won't work — see below). |
| `SERVICE_NAME`   | _(from `MY_SERVER`)_                 | SCM service name. Defaults to the name on the process's own `MY_SERVER` line in `ServerInfo`; falls back to `_<dirname>` only if no `MY_SERVER` is found (e.g. GamigoZR). Set to override. |
| `KEEP_ALIVE`     | `0`                                  | `1` keeps the container alive after the game exe exits, for `docker exec`. |
| `INTERNAL_HOST_<svc>` | _(unset)_                       | Per-service docker hostname for the s2s proxy rewrite. See `example/`. |
| `S2S_PROXY_DISABLED` | `0`                              | `1` skips the baked-in s2s proxy and rewrites every s2s row to the resolved peer IP at boot (the old, node-pinned behaviour). |

## Mount layout the entrypoint expects

```
<FIESTA_PATH>/
|-- 9Data/                        # game data + configs (ServerInfo/, Shine/, ...)
|-- Login/Login.exe
|-- Account/Account.exe
|-- AccountLog/AccountLog.exe
|-- Character/Character.exe
|-- GameLog/GameLog.exe
|-- WorldManager/WorldManager.exe
\-- Zone00/Zone.exe ... Zone04/Zone.exe   # any zone folder name works
```

This is just your standard Fiesta server files, mountable unmodified. (No
`GamigoZR/` is needed — see GamigoZR below.)

### GamigoZR

GamigoZR is **only relevant to the Zone exe**, which queries it once at boot. The
original .NET `GamigoZR.exe` is **not required and generally won't function
properly** in this setup. Instead, **ship your own GamigoZR crypt blob**
(`response.txt`): the runtime serves it from a tiny baked-in HTTP stub
(`127.0.0.1:58492`), gated on `START_GAMIGOZR`/`CRYPT_BLOB_PATH`. No GamigoZR
container or `.exe` needed at runtime.

**Extracting the blob (one-shot, needs a real GamigoZR once):** run a real
`GamigoZR.exe` so it listens on `127.0.0.1:58492`, then request the **exact path**
a Zone uses — the real service is path/param-specific, so `/` alone won't return
it. The Zone's boot request looks like:

```bash
curl "http://127.0.0.1:58492/GR.php?act=boot&title=Fiesta&nation=EU_US_REAL&pw=<your-pw>&world=0&machine=Zone1" > response.txt
```

`title`/`nation` come from your server build and `world`/`machine` are per zone.
`pw` appears to be a constant compiled into the Zone exe (not a password you set)
— and many GamigoZR builds don't even validate it (the response is a static
blob), so its exact value usually doesn't matter; just reuse what your zone sends.
To discover your exact request, point a Zone at a logging HTTP server on `:58492`
and read what it asks for. The stub then replays that one blob for every
request (each Zone asks the same fixed URL).

### XOR cipher table

The client↔server (c2s) packets are XOR'd with a fixed, build-specific table the
proxy needs (bring-your-own — none ships here). Supply it as inline hex
(`XOR_TABLE_HEX`) or a file (`XOR_TABLE_PATH` — hex text **or** raw binary). Hex
parsing tolerates spaces, commas and `0x`:

```ini
XOR_TABLE_HEX=A3 1F 00 C4 7E 9B 2D 55     # spaces  (bytes are made-up)
XOR_TABLE_HEX=a31f00c47e9b2d55             # bare hex
XOR_TABLE_HEX=0xA3,0x1F,0x00,0xC4          # 0x + commas
```

The length isn't fixed by the tooling (the cipher wraps mod the table length) —
it just has to be the same table your client uses.

## What the entrypoint rewrites

The default-shape `ServerInfo.txt` from server files has two things that need
fixing before the server boots:

- `DRIVER={SQL Server};SERVER=.\SQLEXPRESS;UID=sa;PWD=<hardcoded>` in every
  `ODBC_INFO` row (the named-instance reference doesn't work via FreeTDS / modern
  ODBC).
- Hardcoded `127.0.0.1` in every client-facing `SERVER_INFO` row.

The runtime walks `#include` directives from the per-process config dir
(`Login/LoginServerInfo.txt`, `Zone01/ZoneServerInfo/ZoneServerInfo.txt`, ...) and
rewrites the included files in place:

- **SQL access** is picked by env-var presence, in this order:
  1. `SQL_CONNECTION_STRING` set → the entire connection-string field of every
     `ODBC_INFO` row is replaced verbatim. The init query is preserved per row.
  2. `SQL_HOST` set explicitly → `SERVER=` and `PWD=` are patched per row, the
     source's `DRIVER={...}` clause is preserved.
  3. neither → the default `SQL_HOST=127.0.0.1` is used (for the bundled SQL
     container at the compose DNS name `sqlserver`).
- The IP on `SERVER_INFO` rows tagged `; PUBLIC_IP` → `${PUBLIC_IP}` (only when
  set). Labels and ports never modified.
- The IP on `SERVER_INFO` rows tagged `; LOCALHOST` → the docker hostname from
  `INTERNAL_HOST_<service-name>`, when set (bridge-networked example).

The rewrite is idempotent. The included files must be writable: mount the server
folder read-write, or per-container overlay-mount `9Data/ServerInfo/`. If you want
none of this, don't set the env vars and keep `.\SQLEXPRESS` out of your
`ODBC_INFO` strings — the entrypoint becomes a no-op.

## Per-container writable directories

Fiesta exes write a few files at runtime. With multiple containers sharing the
same `FIESTA_PATH` mount, overlay-mount the dirs that need per-container writes:

- **`9Data/ServerInfo/`** — `_ServerGroup.txt` (per service) and `ServerInfo.txt`
  (rewritten per container). Overlay per service.
- **`9Data/SubAbStateClass.txt`** — written by `Zone.exe` on startup.

Windows containers **only support directory-level bind mounts**, which is why
`9Data/ServerInfo/` is the per-container isolation unit. The example compose files
self-seed each container's `9Data/ServerInfo/` overlay on boot from a read-only
second mount of the same server files.

---

## Building your own images

Pulling from a registry is the easy path; build locally only if you need to modify
the runtime / proxy / SQL image. The example compose works either way — it
defaults to local `:latest` tags, and pulling only changes which tags the
`RUNTIME_IMAGE` / `SQL_IMAGE` / `PROXY_IMAGE` refs resolve to.

### Bring your own proxy

The proxy is fully open source ([`lib/fiesta-proxy`](lib/fiesta-proxy), repo
[ik-fiesta-proxy](https://github.com/IkaronClaude/ik-fiesta-proxy)). To run a
modified proxy: clone/edit it, then rebuild. Note the proxy is used in **two**
places — the client-facing `fiesta-proxy` container *and* the s2s proxy **baked
into the runtime image** — so a change usually means rebuilding **both** the
`fiesta-proxy` image (point `PROXY_IMAGE` at it) and the `fiesta-server-runtime`
image (which bakes `FiestaProxy.dll`).

### Local Linux build

```bash
docker build -t fiesta-server-runtime:latest -f Dockerfile.linux .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.linux .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile lib/fiesta-proxy
```

`./build.sh` wraps the runtime build (optional `--push`).

### Local Windows build

Docker Desktop in **Windows-containers** mode, then:

```powershell
docker build -t fiesta-server-runtime:latest -f Dockerfile.windows .
docker build -t fiesta-sql-runtime:latest    -f Dockerfile.sql.windows .
docker build -t fiesta-proxy:latest          -f lib/fiesta-proxy/Dockerfile.windows lib/fiesta-proxy
```

`.\build.ps1` wraps the runtime build (sets `DOCKER_BUILDKIT=0` — BuildKit doesn't
support Windows containers).

> **Heads-up:** if Docker Desktop's experimental *Host networking* toggle is on,
> `docker build` can't reach apt mirrors and hangs. Toggle it OFF for the build.

### Which arch(es) to build

**Multi-arch is optional.** If you only deploy one OS, build just that arch and
skip the manifest stitching — point your compose at the single-arch tag. Rules of
thumb:

- **Linux images** build on a Linux host (or WSL).
- **Windows images** build on a Windows host (Docker Desktop in Windows-containers
  mode).
- A **Windows** machine can build *both*: WSL for the Linux images, then switch
  Docker to Windows-containers for the Windows ones.
- A **Linux** machine can *probably* build the Windows variants under Wine too —
  **untested**.

### Multi-arch manifest (only if publishing both)

Build each OS on its own host, then stitch one tag that serves both:

```bash
# 1. On a Linux host
./build.sh --push ghcr.io/you/fiesta-server-runtime:latest
# 2. On a Windows host (Windows-containers mode)
.\build.ps1 -Push ghcr.io/you/fiesta-server-runtime:latest
# 3. On either host
./combine-manifest.sh ghcr.io/you/fiesta-server-runtime:latest
docker buildx imagetools inspect ghcr.io/you/fiesta-server-runtime:latest
```

After this, `docker pull` fetches the right variant per host OS. Same recipe for
the SQL and proxy images.

### Where the Dockerfiles live

| File | Builds |
|------|--------|
| `Dockerfile.linux` / `Dockerfile.windows` | `fiesta-server-runtime` |
| `Dockerfile.sql.linux` / `Dockerfile.sql.windows` | `fiesta-sql-runtime` |
| `lib/fiesta-proxy/Dockerfile` / `…Dockerfile.windows` | `fiesta-proxy` |

---

## How startup works

1. Parse the trailing `CMD` arg / `FIESTA_EXE` into directory + exe name.
2. Verify the mount and exe exist; print the folder listing on failure.
3. **Discover the service identity** by reading the `MY_SERVER` line from the
   `*.txt` config under the process's own directory (subfolders are searched —
   e.g. a Zone's `ZoneServerInfo/` — but never parent dirs of the exe). That name
   is what the exe registers under; `SERVICE_NAME=_<dirname>` is only a fallback
   when no `MY_SERVER` is present.
4. Walk `#include` directives and rewrite the SQL / `PUBLIC_IP` / `INTERNAL_HOST`
   targets per the rules above.
5. Set the `Fantasy\Fighter` and `GBO\*` registry keys the exes check.
6. Start the baked-in s2s proxy (`FiestaProxy.dll`) — unless `S2S_PROXY_DISABLED=1`.
7. (Zones) Serve the GamigoZR crypt blob from the baked-in HTTP stub (when
   `START_GAMIGOZR`/`CRYPT_BLOB_PATH` apply).
8. Register the exe as a service under the discovered name via `sc.exe` (Wine SCM
   on Linux, native SCM on Windows). Direct exec would block on
   `StartServiceCtrlDispatcher()`.
9. Tail the exe's `.txt` logs, then watch the service; the container exits when the
   process dies (unless `KEEP_ALIVE=1`).

## Notes and gotchas

- **Bridge networking + baked-in proxy** is the example's model. Only the proxy
  container publishes ports; runtime containers reach peers by docker DNS. The
  proxy rewrites WM/Zone endpoints in `WORLDSELECT_ACK` / `CHAR_LOGIN_ACK` to
  `PUBLIC_IP`, so external clients see one address. No `network_mode: host`, no
  LAN-IP gymnastics — and because peers go through the local s2s proxy, services
  aren't pinned to fixed nodes (survives reschedules / evictions).
- **Mount must be read-write** wherever the exe writes (process subdir logs,
  `9Data/SubAbStateClass.txt`).
- **Windows bind mounts are directory-only.** Isolate a single file by giving it
  its own directory.
- **GamigoZR**: only relevant to Zones; ship your own crypt blob (`response.txt`)
  — the real `.exe` isn't needed and won't work here.
- **Linux Wine prefix is pre-initialised** at build time; first-run cost is paid
  once, not per container start.

## Repo layout

```
.
|-- Dockerfile.linux / .windows          # fiesta-server-runtime
|-- Dockerfile.sql.linux / .windows      # fiesta-sql-runtime
|-- start.sh / start.ps1                 # entrypoints
|-- setup-sql.sh / setup-sql.ps1         # SQL .bak auto-restore
|-- build*.sh / build*.ps1               # local build wrappers
|-- combine-manifest.sh                  # stitch multi-arch manifest
|-- gen-proxy-config.sh / .ps1           # derive PROXY_ROUTES from ServerInfo.txt
|-- lib/fiesta-proxy/                     # submodule: client-facing + s2s proxy
\-- example/                              # full 11-container stack
    |-- README.md                         # operator quickstart (both platforms)
    |-- linux/  windows/  k8s/            # compose + .env.example + manifests
```
