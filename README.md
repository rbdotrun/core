# rbrun-core

Core engine for rbrun. Handles everything from server provisioning to Kubernetes deployment.

## Deployment strategies

The `target` config value determines which deployment strategy is used:

| Target | Strategy | Naming | Use case |
|--------|----------|--------|----------|
| `sandbox` | Docker Compose | `rbrun-sandbox-{slug}` | Ephemeral PR previews, testing |
| Any other value | K3s/Kubernetes | `{app-name}-{target}` | Persistent deployments |

**Important:** `target` is required in your config. There is no default.

### Sandbox flow

Each `sandbox deploy` generates a unique 6-char slug (e.g., `a3f8b2`), creating isolated infrastructure:
- Server: `rbrun-sandbox-a3f8b2`
- Single-server only (no multi-server, no `runs_on`)
- No K3s, uses Docker Compose directly
- Destroyed with `sandbox destroy`

### Release flow

For `target: production`, `target: staging`, or any non-sandbox value:
- Server: `{app-name}-{target}-master-1` (e.g., `myapp-production-master-1`)
- Persistent volumes, backups, K3s cluster
- Multiple environments run side by side with different targets

```yaml
# rbrun.yaml           → myapp-production-*
target: production

# rbrun.staging.yaml   → myapp-staging-*
target: staging
```

## Features

### Declarative infrastructure
- Define servers, databases, services, and processes in a single YAML
- Reconciliation engine diffs desired state against cloud provider — creates what's missing, removes what's excess
- Idempotent: redeploying the same config is a no-op for infrastructure

### Unified server naming with implicit master
- Master server(s) always created as `prefix-master-1`, `prefix-master-2`, etc.
- Additional worker groups use `prefix-{group}-{N}` format (e.g., `prefix-app-1`, `prefix-worker-1`)
- Database and tunnel always pinned to master node
- Pin processes/services to groups via `runs_on`
- Scale groups up/down by changing `count` — reconciliation handles the rest

### Server reconciliation
- Scale up: new servers are created, joined to K3s as workers, labeled
- Scale down: pods are drained (cordoned, evicted, polled until empty), K3s node removed, server deleted from provider
- Scale down processes highest-index-first (`app-3` before `app-2`)
- Master node (`master-1`) is protected — cannot be removed or changed

### Kubernetes (K3s)
- Automatic K3s installation on master with WireGuard networking
- Worker nodes auto-join the cluster
- Existing workers are detected and skipped on redeploy
- All nodes re-labeled on every deploy (picks up group changes)
- In-cluster Docker registry (NodePort 30500)
- NGINX ingress controller with Cloudflare tunnel for HTTPS

### Replica management
- Per-process replica count (`replicas: N`)
- Default: 2 replicas per process
- Processes with a subdomain (public-facing) enforce minimum 2 replicas for zero-downtime rolling deploys
- Background workers can run with any replica count

### Databases
- Postgres with configurable image, username, database name
- Host-path volumes for data persistence
- Connection env vars auto-injected (`DATABASE_URL`, `POSTGRES_*`)
- Backup configuration (schedule, retention)
- Always runs on master node (data persistence)

### Services
- Sidecar services (Redis, Meilisearch, etc.) with custom images
- Auto-injected service URLs (`REDIS_URL`, `MEILISEARCH_URL`)
- Per-service environment variables and secrets
- Optional public subdomain per service

### Cloudflare integration
- Tunnel-based HTTPS ingress (no open ports except SSH)
- Per-process and per-service subdomains
- DNS record management

### Docker build
- Builds on the server (no CI dependency)
- Pushes to in-cluster registry
- Old images cleaned up after deploy

### SSH
- Cloud-init for initial server setup
- Key-based auth, no passwords
- Retry logic for SSH connection during provisioning
- Execute commands with timeout and error handling

### Environment & secrets
- `${VAR}` interpolation from .env files
- Env vars stored as Kubernetes Secrets
- Auto-generated database credentials

## Architecture

```
rbrun-core/
├── lib/rbrun_core/
│   ├── clients/              # API + SSH clients
│   │   ├── compute/          #   Hetzner, Scaleway
│   │   ├── cloudflare.rb     #   Cloudflare API + R2 + Workers
│   │   ├── kubectl.rb        #   kubectl via SSH (apply, drain, delete, scale)
│   │   ├── github.rb         #   GitHub API
│   │   └── ssh.rb            #   SSH execution with retry
│   ├── commands/             # Orchestration
│   │   ├── deploy/           #   Full release deploy pipeline
│   │   ├── deploy_sandbox/   #   Sandbox deploy (Docker Compose)
│   │   ├── destroy/          #   Tear down release
│   │   ├── destroy_sandbox/  #   Tear down sandbox
│   │   └── shared/           #   create_infrastructure, delete_infrastructure
│   ├── config/               # Configuration loading + validation
│   │   ├── compute/          #   Provider configs (Hetzner, Scaleway)
│   │   ├── configuration.rb  #   Top-level config struct
│   │   └── loader.rb         #   YAML parser with env interpolation
│   ├── generators/           # Manifest generation
│   │   ├── cloud_init.rb     #   Cloud-init user-data
│   │   ├── compose.rb        #   Docker Compose (sandboxes)
│   │   └── k3s.rb            #   K8s manifests (Deployments, Services, Ingress, Secrets)
│   ├── context.rb            # In-memory deploy state
│   ├── errors.rb             # Error hierarchy
│   ├── local_git.rb          # Git repo detection
│   └── naming.rb             # Resource naming conventions
└── test/                     # Minitest suite, 252 tests
```

## Compute providers

| Provider | Status | Multi-server | Notes |
|----------|--------|--------------|-------|
| Hetzner | Stable | Yes | Full reconciliation, US + EU datacenters |
| Scaleway | Stable | No | Single-server, EU only |

## Deploy pipeline (release)

```
CreateInfrastructure  →  SetupK3s  →  SetupTunnel  →  BuildImage  →  DeployManifests
       │                    │             │               │               │
  Firewall, Network    K3s master    Cloudflare      Docker build    kubectl apply
  Server reconcile     Join workers  Tunnel setup    Push to registry  Wait rollout
  Wait SSH             Label nodes
```

## Deploy pipeline (sandbox)

```
CreateInfrastructure  →  SetupApplication
       │                       │
  Single server           Docker Compose
  Wait SSH                Clone, build, up
```

## Dependencies

- `faraday` — HTTP client for cloud APIs
- `net-ssh` — SSH execution
- `sshkey` — SSH key generation

## Test suite

```
380 runs, 695 assertions, 0 failures, 0 errors
```

```bash
bundle exec rake test
```
