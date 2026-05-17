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
- If `PUBLIC_IP` is set, the `; PUBLIC_IP`-tagged `SERVER_INFO` rows get
  their IP rewritten.

Labels (`"PG_Login"`, `"PG_W00_Z01"`, ...) and ports are never touched.

The `Zone.exe` processes will write `9Data/SubAbStateClass.txt` on startup.
Because `${FIESTA_SERVER}` is bind-mounted read-write, this lives in your
original tree -- that's expected behaviour.

## Customising

- **More zones.** Copy a `zoneNN` service block and adjust `command:` plus
  the overlay dir. Add a row to the `init` service's loop.
- **Different SQL port.** Set `SQL_PORT=1500` in `.env`; both `sqlserver`'s
  host binding and the ODBC rewrite pick it up.
- **External clients (non-localhost).** Set `PUBLIC_IP=<your-public-ip>` in
  `.env`. The runtime rewrites the client-facing rows in each container's
  ServerInfo.txt.

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
