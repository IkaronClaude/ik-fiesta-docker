# Example: full Fiesta server stack with `fiesta-server-runtime`

This `docker-compose.yml` brings up a complete 13-container Fiesta server
(SQL Server + 11 game processes + GamigoZR anti-cheat) on top of an
**unmodified** ServerSource-shaped tree.

## What you need

- A working ServerSource-shaped directory on the host. The expected layout:

  ```
  Server/
  |-- 9Data/                  (game data, ServerInfo/, Shine/, ...)
  |-- Account/Account.exe
  |-- AccountLog/AccountLog.exe
  |-- Character/Character.exe
  |-- GameLog/GameLog.exe
  |-- Login/Login.exe
  |-- WorldManager/WorldManager.exe
  |-- Zone00/Zone.exe ... Zone04/Zone.exe
  |-- GamigoZR/GamigoZR.exe
  \-- Databases/              (.bak files restored on first SQL boot)
  ```

- The `fiesta-server-runtime:latest` image available locally (`docker build`
  from the repo root, or pull from your registry).
- Docker + docker compose. Linux host with `network_mode: host` support.

## Quick start

1. Create a `.env` next to this `docker-compose.yml`:

   ```
   FIESTA_SERVER=/abs/path/to/Server
   SA_PASSWORD=YourStrongPassword1
   ```

2. `docker compose up -d`

3. Tail a service:

   ```
   docker compose logs -f login
   ```

That's it. The `init` service seeds per-container overlays of
`9Data/ServerInfo/` under `./serverinfo/<service>/` so the per-container ODBC
rewrite and `_ServerGroup.txt` writes don't fight each other.

## What gets modified in your ServerSource

The runtime image rewrites only `9Data/ServerInfo/ServerInfo.txt` (in each
per-container overlay, NOT the original under `${FIESTA_SERVER}`):

- `SERVER=.\SQLEXPRESS` -> `SERVER=127.0.0.1,1433`
- `PWD=<hardcoded>`     -> `PWD=${SA_PASSWORD}`
- The `; PUBLIC_IP`-tagged `SERVER_INFO` rows get their IP rewritten. If you
  set `PUBLIC_IP` in `.env`, that value is used; if you don't, the container
  auto-detects its own outbound IP (`ip route get 1.1.1.1` -> `src`) and uses
  that. Auto-detect is the right answer with `network_mode: host` -- the
  detected IP is by definition one the server can `bind(2)`, and on a host-
  networked container it's the same IP external clients use to reach you.

Labels (`"PG_Login"`, `"PG_W00_Z01"`, ...) and ports are never touched.

The `Zone.exe` processes will write `9Data/SubAbStateClass.txt` on startup.
Because `${FIESTA_SERVER}` is bind-mounted read-write, this lives in your
original tree -- that's expected behaviour.

## Running on Docker Desktop for Windows / Mac

The example uses `network_mode: host` because Fiesta's process model has the
server bind and advertise the **same** IP (the `; PUBLIC_IP`-tagged row in
`ServerInfo.txt`), with the rest of the cluster reaching each other on
`127.0.0.1`. On a native Linux Docker host that's perfect: leave `PUBLIC_IP`
unset, the runtime auto-detects the host LAN IP, off-host clients connect.

On **Docker Desktop**, host-mode is awkward. Even with the experimental
**Host networking** toggle on (Settings → Resources → Network, 4.34+),
containers don't share the Mac/Windows NIC -- they share Docker Desktop's
internal Linux VM network (`192.168.65.0/24`). The only IP that's both
bindable inside the container **and** reachable from the host is `127.0.0.1`,
which Docker Desktop forwards back to the host when the toggle is on.

What that means in practice:

- **Same-machine testing works.** Leave `PUBLIC_IP` unset; the runtime
  detects it's on Docker Desktop, picks `127.0.0.1`, and the server binds
  there. You can `Test-NetConnection 127.0.0.1 -Port 9010` from PowerShell
  and the real Fiesta client (pointed at `127.0.0.1`) can log in.
- **Off-host LAN clients cannot reach the server in this setup.** That's
  a Docker Desktop limitation, not a fiesta-docker limitation. The
  `127.0.0.1` advertised in `ServerInfo.txt` is meaningless to other
  machines on your LAN.
- For a **LAN-accessible / publicly-accessible** server, deploy on a
  native Linux Docker host (bare metal, VM, k8s -- anything Linux). There
  the auto-detected outbound IP IS the host's LAN address and everything
  works end-to-end with no toggles.

You still need the Host networking toggle on Docker Desktop for the
`127.0.0.1` forwarding to work; without it, even same-machine connectivity
fails. The toggle requires WSL2 mirrored networking on Windows
(`[wsl2]\nnetworkingMode=mirrored` in `%USERPROFILE%\.wslconfig`) and a
Docker Desktop restart, and it must be set via the GUI (not
`settings-store.json`). **Caveat: with the toggle ON, `docker build` can't
reach apt mirrors and hangs forever** -- toggle it OFF to rebuild images,
then back ON to run the stack.

A future bridge-network + per-container tunnel sidecar (see `PLAN.md`) will
make off-host clients work on Docker Desktop too, but isn't built yet.

## Customising

- **More zones.** Copy a `zoneNN` service block and adjust `command:` plus
  the overlay dir. Add a row to the `init` service's loop.
- **Different SQL port.** Set `SQL_PORT=1500` in `.env`; both `sqlserver`'s
  host binding and the ODBC rewrite pick it up.
- **External clients (non-localhost).** Set `PUBLIC_IP=<your-public-ip>` in
  `.env`. The runtime rewrites the client-facing rows in each container's
  ServerInfo.txt.
- **Where the DB data lives.** Docker-managed named volume called
  `sql-data` (the project-scoped name is
  `<compose-project>_sql-data`, e.g. `example_sql-data`). Volumes
  outlive containers, images, and `docker compose down`.

## What happens on `docker compose down`?

The DB data is in a **named volume**, so:

- `docker compose down`          -- stops + removes containers. DB data is safe.
- `docker compose stop / start`  -- DB data is safe.
- `docker compose rm`            -- DB data is safe.
- `docker rmi fiesta-sql-runtime:latest` -- DB data is safe.
- `docker compose down -v`       -- **DELETES the DB**. The `-v` flag wipes
                                    named volumes too. Don't run this unless
                                    you actually want a clean slate.
- `docker volume rm example_sql-data` -- **DELETES the DB**, explicitly.

On the next `up` the SQL container starts cleanly, the entrypoint sees the
data files on the volume, and skips the restore pass. New `.bak` files
dropped into `Databases/` get restored automatically on next start (since
their DBs aren't registered yet).

If you want the data on a path you control (so even `down -v` is harmless),
edit `docker-compose.yml` and replace `sql-data:/var/opt/mssql` with a bind
mount like `/srv/fiesta/sql-data:/var/opt/mssql`. Note: SQL Server on Linux
needs strict POSIX semantics, so bind mounts on **Windows hosts** (Docker
Desktop) tend to break sqlservr. Use bind mounts only on Linux hosts; on
Windows, stick with the named volume.

## Simpler one-off run

If you just want to test a single process without the whole stack:

```
docker run --rm --network host \
  -v /path/to/Server:/fiesta \
  -v /path/to/Server/9Data/ServerInfo:/fiesta/9Data/ServerInfo \
  -e SA_PASSWORD=YourStrongPassword1 \
  fiesta-server-runtime:latest \
  Login/Login.exe
```
