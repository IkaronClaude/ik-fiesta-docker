# Run a Fiesta Online server

Brings up the full stack — SQL + DB bridges + Login + WorldManager + 5 zones,
fronted by one client-facing proxy. Images are prebuilt and multi-arch on
Docker Hub, so **there's nothing to compile**. You bring the game files.

Pick one:

- **Docker Compose** (one host) → [Compose quick start](#compose-quick-start)
- **Kubernetes** (a cluster) → [`k8s/`](k8s/) + [k8s quick start](#kubernetes-quick-start)

---

## What you provide (BYO)

The images ship **no game files**. You supply:

1. **Your server files** — the standard layout:
   ```
   server-files/
   ├── 9Data/                    game data + configs
   ├── Login/Login.exe   WorldManager/WorldManager.exe
   ├── Account/  AccountLog/  Character/  GameLog/    (each *.exe)
   ├── Zone00/Zone.exe … Zone04/Zone.exe
   └── Databases/                your *.bak files (restored on first SQL boot)
   ```
2. **A GamigoZR crypt blob** (`response.txt`) — only needed by the Zone exe,
   which queries GamigoZR once at boot. Drop it in `gamigozr-blob/`; the in-zone
   stub replays it. The real `GamigoZR.exe` isn't needed at runtime — but you do
   need it **once** to extract the blob:

   ```bash
   # Run a real GamigoZR.exe so it listens on 127.0.0.1:58492, then request the
   # EXACT path the Zone uses (the path matters — '/' alone won't return it):
   curl "http://127.0.0.1:58492/GR.php?act=boot&title=Fiesta&nation=EU_US_REAL&pw=<your-pw>&world=0&machine=Zone1" > response.txt
   ```
   `title`/`nation` come from your server build and `world`/`machine` are per
   zone. `pw` looks like a constant baked into the Zone exe (not a password you
   set) — and many GamigoZR builds don't even validate it (the response is a
   static blob), so its exact value usually doesn't matter; just reuse what your
   zone sends. (To discover your exact request, point a Zone at a logging server
   on `:58492` and read what it asks for.)
3. **The XOR cipher table** — the c2s packet cipher. Required. Drop a file in
   `xor/` and point `XOR_TABLE_PATH` (or pass `XOR_TABLE_HEX`) at it. Accepted
   formats — hex parsing tolerates spaces, commas and `0x`:

   ```ini
   # inline (env)                         # made-up bytes — use your build's table
   XOR_TABLE_HEX=A3 1F 00 C4 7E 9B 2D 55
   XOR_TABLE_HEX=a31f00c47e9b2d55          # bare hex
   XOR_TABLE_HEX=0xA3,0x1F,0x00,0xC4       # 0x + commas
   # file (XOR_TABLE_PATH): the same hex as text, OR the raw binary table dumped
   #   to a file. Length isn't fixed — it just has to match your client's table.
   ```

You also choose **`PUBLIC_IP`** — the address your players actually connect
to (LAN IP, WAN/forwarded IP, or `127.0.0.1` for a local-only test).

---

## Compose quick start

```bash
cd example/linux          # or example/windows (Docker Desktop, Windows-containers mode)
cp .env.example .env
```

Edit `.env` — three required values:

```ini
FIESTA_SERVER=/abs/path/to/server-files
SA_PASSWORD=ChangeMe!Strong1
PUBLIC_IP=127.0.0.1            # the IP your client connects to
```

Drop your `response.txt` into `gamigozr-blob/`, then:

```bash
docker compose up -d
docker compose logs -f login
```

Point a Fiesta client at `PUBLIC_IP:9010`. That's it — the Linux example
pulls `ikaronclaude/fiesta-*:latest`; the Windows example does too (multi-arch).

> **Stock files? Nothing to configure** — the shipped `PROXY_ROUTES`, `ports:`,
> and `INTERNAL_HOST_*` are already wired for the standard 5-zone layout.
> **Different files** (extra zones, different ports, more worlds)? Don't
> hand-edit — regenerate the proxy block from your own `ServerInfo.txt` in one
> command and paste it in:
> ```bash
> ../../gen-proxy-config.sh --server-info /path/to/ServerInfo.txt --public-ip "$PUBLIC_IP"
> ```
> See [Regenerating the proxy config](#regenerating-the-proxy-config).

Create a test account (raw **uppercase** MD5 — see pitfalls):

```bash
docker compose exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S 127.0.0.1 -U sa \
  -P "$SA_PASSWORD" -C -d Account -Q \
  "INSERT INTO tUser (sUserID,sUserPW,sUserName,sUserIP) VALUES \
   ('testuser', UPPER(CONVERT(varchar(32), HASHBYTES('MD5','test123'), 2)), 'Test','127.0.0.1')"
```

Down: `docker compose down` (data is safe — see [DB persistence](#database--sql-options)).

---

## Kubernetes quick start

Full detail in [`k8s/README.md`](k8s/README.md). Minimal path:

```bash
# 1. Put server files on one node (default /root/fiesta-files) and install
#    nfs-common on every node:   apt-get install -y nfs-common
# 2. Edit example/k8s/00-namespace-config.yaml (PUBLIC_IP, SA_PASSWORD)
#        and example/k8s/10-nfs.yaml (data node name + its IP + hostPath)
# 3. Create the GamigoZR blob configmap:
kubectl create configmap gamigozr-blob -n fiesta --from-file=response.txt=./response.txt
# 4. Apply, wait for SQL, scale the game tier up:
kubectl apply -k example/k8s/
kubectl -n fiesta wait --for=condition=ready pod -l app=mssql --timeout=300s
kubectl scale -n fiesta -l tier=game deploy --replicas=1
```

Players connect to the `fiesta-proxy` LoadBalancer IP on `:9010`.

> Stock 5-zone files work as shipped. For a different layout, regenerate the
> proxy env in `k8s/60-proxy.yaml`:
> `./gen-proxy-config.sh --server-info /path/to/ServerInfo.txt --format k8s --host-suffix .fiesta.svc.cluster.local`

---

## Configuration

| Setting | Where | Notes |
|---------|-------|-------|
| `PUBLIC_IP` | `.env` / `game-env` ConfigMap | Advertised to clients. Must be the address they actually reach the proxy on. |
| `SA_PASSWORD` | `.env` / `fiesta-sql` Secret | Meet SQL's complexity policy (8+ chars, mixed). |
| `RUNTIME_IMAGE`/`SQL_IMAGE`/`PROXY_IMAGE` | compose `.env` | Override the Hub defaults to use locally-built tags. |
| `PROXY_PACKET_LOG=1` | proxy env | Per-frame opcode trace. Off by default. |

### Regenerating the proxy config

The example ships a `PROXY_ROUTES` string (and matching `ports:` /
`INTERNAL_HOST_*` map) wired for the stock five-zone topology. If your server
files have a different layout (extra zones, different ports, more worlds), don't
hand-edit it — generate it from your own `ServerInfo.txt`:

```bash
# Linux / macOS                          # Windows (PowerShell)
./gen-proxy-config.sh \                  .\gen-proxy-config.ps1 `
  --server-info path/to/ServerInfo.txt \   -ServerInfo path\to\ServerInfo.txt `
  --public-ip 203.0.113.7                  -PublicIp 203.0.113.7
```

It reads the `SERVER_INFO` rows, emits one route per client-facing row
(`FromServerType == 20`, i.e. the `; PUBLIC_IP` rows; zones get `:opaque`), and
prints the `ports:` list plus the `INTERNAL_HOST_*` map. `--format env` gives a
single-line dotenv form; `--format k8s --host-suffix .fiesta.svc.cluster.local`
emits the cluster-DNS variant for `k8s/60-proxy.yaml`. Paste the output into the
compose/k8s file. Service names match what the runtime (`start.sh`/`start.ps1`)
expects, so the proxy and the exes agree.

### Database / SQL options

- **Bundled SQL** (default): the `sqlserver` service / `mssql` StatefulSet
  auto-restores every `.bak` in `Databases/` on first boot, then `ATTACH`es
  the existing files on later boots (so `down`/`up` keeps your characters).
- **Persistence (compose):** Linux uses a **named volume** (`down -v` wipes
  it — don't). Windows uses a host bind mount. To force a fresh re-import,
  remove the volume/dir and bring the stack back up.
- **External SQL:** set `SQL_HOST` (+ drop the `bundled-sql` compose profile /
  delete `k8s/20-sql.yaml`), or set the full `SQL_CONNECTION_STRING`. You must
  pre-restore the six DBs (Account, AccountLog, World00_Character,
  World00_GameLog, StatisticsData, OperatorTool) yourself.

---

## Common pitfalls

Everything below is a real failure we hit and fixed — symptom → cause → fix.

### SQL Server

| Symptom | Cause | Fix |
|---------|-------|-----|
| Bridges log `DB_Init FAILED`; can't connect to SQL | The 32-bit Fiesta exes **can't load the x64-only ODBC Driver 17**. | Keep `ODBC_DRIVER={SQL Server}` (the legacy in-box driver — the image default). Don't "upgrade" it. |
| `sqlservr` crashes in `sqlpal.dll` right after start (Docker Desktop) | SQL Server on Linux needs POSIX-strict storage; a **Windows-host bind mount over Docker Desktop's 9P bridge** doesn't provide it. | Use a **named volume** for `/var/opt/mssql` (the Linux example's default). Bind mounts only on a native Linux host. |
| SQL worked, then a rebuild started crashing | The `mssql/server:2022-latest`/`2025-latest` tag is a **moving target**; a newer build regressed. | Pin to a specific CU tag (the Dockerfiles do: `…-CU…-ubuntu-22.04`). |
| SQL container restart-loops on boot; logins rejected with error 18401 | SQL is in **script upgrade mode** (applying CU upgrade to the DBs) and rejects logins until done — the readiness probe killed it early. | Already handled: `setup-sql` detects upgrade mode and waits. Just give it time / a generous probe `failureThreshold`. |
| Container shows `Running` but every login fails; DB seems dead | `sqlservr` was **OOM-killed inside the container** while PID 1 lived (so `OOMKilled=false` misleads). | Give SQL enough memory (≥2–3 GiB) and don't overcommit the node/host. |

### Login & accounts

| Symptom | Cause | Fix |
|---------|-------|-----|
| Client: *"please check id or password"* with correct creds | Either SQL is down (see above) **or** the stored password hash is wrong. | `tUser.sUserPW` is **raw MD5 hex, UPPERCASE**, no salt. Store the uppercase MD5 of the plaintext. |
| Login screen shows the world but joining hangs | Proxy isn't rewriting the WM/Zone endpoint, or `PUBLIC_IP` is wrong. | Check proxy logs for the `WORLDSELECT_ACK [rewritten]` line; set `PUBLIC_IP` to the address the client actually uses. |
| Zone screen black / client rejected on zone enter | Missing/incorrect GamigoZR crypt blob. | Put the real `response.txt` in `gamigozr-blob/` (compose) or the `gamigozr-blob` ConfigMap (k8s). |
| `zone00` loads fully then exits cleanly, crash-loops (others fine) | The town zone asserts on **`SlotMachineJackPotRanking`** with corrupted slot-machine ranking data in the DB. | Nuke the DB volume and let it **restore fresh from `.bak`** (the bad data was runtime state, not in the backup). |

### Kubernetes / resources

| Symptom | Cause | Fix |
|---------|-------|-----|
| Game-pod PVC mount fails: `mount failed: exit status 32` | `nfs-common` (the `mount.nfs` helper) isn't installed on the node. | `apt-get install -y nfs-common` on **every** node that runs game pods. |
| Pod crashes copying files: `cp: … Operation not supported` | `cp -a` can't preserve perms/xattrs over NFS, and aborts startup. | Fixed in the image (`cp -rL` fallback). Use a current image (`:latest` / `dev-3`+). |
| A node — or the whole cluster/API — falls over when scaling zones | **Under-requested resources**: zones requested ~`100m`/`1Gi` but use ~`1.5 CPU`/`2.1 GiB`, so the scheduler overpacked one node until it OOM'd (worse if all zones are pinned to one node). | Request memory at **real usage** (`mem:2560Mi`, `cpu:1` floor); don't pin all zones to one node. Pods then spread, and over-capacity goes `Pending` (safe) instead of nuking a node. Each loaded zone ≈ 2.1 GiB — size nodes accordingly. |
| `kubectl scale` keeps getting reverted | Argo/Flux re-syncs the git `replicas` value. | Set `ignoreDifferences` on `/spec/replicas` (+ `RespectIgnoreDifferences`), or change replicas in git. |
| Removed manifests still running after a sync | GitOps `prune: false`. | Delete the orphaned resources manually (`kubectl delete`). |

### Logs & build host

| Symptom | Cause | Fix |
|---------|-------|-----|
| Old/duplicate log lines interleaved in container output (Linux) | The persisted server files accumulates `Assert*/KQLog*/Message*` across runs; the tailer re-reads them from line 1. | Fixed in the image — `start.sh` cleans stale logs before launch. Use a current image. |
| Wall of `Could not resolve keysym XF86…` warnings (Linux) | Harmless `xkbcomp` noise from Xvfb. | Fixed — Xvfb output is redirected to `/tmp/xvfb.log`. |
| Hundreds of `s2s outbound accept/close` lines flooding logs | Per-connection s2s logging on by default. | Fixed — gated behind `PROXY_PACKET_LOG=1`. |
| `docker build` hangs forever reaching apt mirrors (Docker Desktop) | The experimental **Host networking** toggle blocks the build network. | Toggle Host networking **off** to build, back on to run. |
| Docker Desktop wedges (500s) during big builds | WSL2 VM out of memory/disk. | Give it headroom in `%USERPROFILE%\.wslconfig` (`memory`, `swap`); don't run other heavy stacks during a build. |
