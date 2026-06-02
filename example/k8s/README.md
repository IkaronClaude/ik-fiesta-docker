# `example/k8s/` — Fiesta server stack on Kubernetes

The same bridge + proxy topology as [`../linux/`](../linux/), as plain
Kubernetes manifests. Mirrors the design that runs the live Ikaron cluster.

```
              LoadBalancer (PUBLIC_IP) :9010/9013/9016/9019/9022/9025/9028
                                  │
                            fiesta-proxy            (rewrites WM/Zone -> PUBLIC_IP)
                                  │
        login ─ worldmanager ─ zone00..04           (cluster pod network)
          │          │            │
       account  accountlog   character  gamelog     (DB bridges)
                                  │
                               mssql                 (fiesta-sql-runtime, or external)
```

- Runtime pods discover each other's s2s endpoints by **headless Service**
  name (the baked-in proxy resolves `INTERNAL_HOST_*` per connection).
- **fiesta-proxy** is the only externally-exposed component.
- Each zone runs its own GamigoZR crypt-blob stub.
- The server files tree is shared to all nodes over **NFS (RWX)** so game
  pods aren't pinned to one node.

Images are the published multi-arch Docker Hub builds
(`ikaronclaude/fiesta-*:latest`) — no local build needed.

## Prerequisites

1. **server files on one node.** Put your `server files`-shaped tree
   (`9Data/`, `Login/`, `Zone00/`…`Zone04/`, `GamigoZR/`, `Databases/`) on a
   node's filesystem (default path `/root/fiesta-files`).
2. **`nfs-common` on every node** that may run game pods:
   `apt-get install -y nfs-common`. Without the `mount.nfs` helper the RWX
   PVC mount fails with `exit status 32`.
3. **GamigoZR crypt blob** — extract `response.txt` once from real GamigoZR
   (see `Dockerfile.gamigozr-stub` in the repo root).

## Configure

Edit before applying:

| File | Field |
|------|-------|
| `00-namespace-config.yaml` | `game-env.PUBLIC_IP` (the LB address clients reach) and the `fiesta-sql` Secret `SA_PASSWORD` |
| `10-nfs.yaml` | the data node's `nodeSelector` hostname, the `hostPath` to your server files, and the PV's `nfs.server` (that node's cluster-routable IP) |

Create the GamigoZR blob ConfigMap (the zones mount it):

```bash
kubectl create configmap gamigozr-blob -n fiesta --from-file=response.txt=./response.txt
```

## Deploy

```bash
kubectl apply -k example/k8s/        # or: kubectl apply -f example/k8s/

# game pods default to replicas: 0 -- scale the tier up once SQL is healthy:
kubectl -n fiesta wait --for=condition=ready pod -l app=mssql --timeout=300s
kubectl scale -n fiesta -l tier=game deploy --replicas=1
```

Point a Fiesta client at `PUBLIC_IP:9010`.

## Notes / tuning

- **Resource requests** are sized from real usage: zones `cpu:1`/`mem:2560Mi`
  (burst to a 4-core limit during map load), bridges `500m`/`512Mi`,
  login/WM `300m`/`512Mi`. Memory is the binding constraint — under-requesting
  lets the scheduler overpack a node and OOM it. Each loaded zone uses
  ~2.1 GiB, so size your nodes accordingly (5 zones ≈ 11 GiB + the rest).
- **`kubectl scale` vs GitOps:** if you manage this with Argo/Flux, set
  `ignoreDifferences` on `/spec/replicas` (and `RespectIgnoreDifferences`)
  so manual scaling isn't reverted on sync.
- **External SQL:** delete `20-sql.yaml` and point `game-env.SQL_HOST` at
  your server; pre-restore the six fiesta DBs (Account, AccountLog,
  World00_Character, World00_GameLog, StatisticsData, OperatorTool) there.
- **Single-node (no NFS):** skip `10-nfs.yaml`, and in the game manifests
  replace the `fiesta-source` PVC volume with a `hostPath` to your
  server files pinned (`nodeSelector`) to that node. Simpler, but no spread.
- **Proxy exposure:** `60-proxy.yaml` uses a `LoadBalancer` Service. See its
  header for NodePort / Traefik-TCP alternatives if you have no LB.
- **External players** must be able to reach the LB IP on all 7 TCP ports.
