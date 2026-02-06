# Real-World Testing Guide

End-to-end testing of rbrun-core using the dummy-rails app.

---

## Test Environment

| Component | Path |
|-----------|------|
| CLI | `/Users/ben/Desktop/apps/rbrun/cli` |
| Core | `/Users/ben/Desktop/apps/rbrun/core` |
| Test App | `/Users/ben/Desktop/dummy-rails` |
| Config | `/Users/ben/Desktop/dummy-rails/rbrun.yaml` |
| Env File | `/Users/ben/Desktop/dummy-rails/.env` |

---

## Test App Configuration

### Multi-server with reconciliation (`rbrun.yaml`)

```yaml
target: production

compute:
  provider: hetzner
  api_key: ${HETZNER_API_TOKEN}
  ssh_key_path: ~/.ssh/id_rsa
  location: ash
  servers:
    app:
      type: cpx21
      count: 2
    worker:
      type: cpx21
      count: 1
    db:
      type: cpx21

cloudflare:
  api_token: ${CLOUDFLARE_API_TOKEN}
  account_id: ${CLOUDFLARE_ACCOUNT_ID}
  domain: rb.run

databases:
  postgres: ~

app:
  dockerfile: Dockerfile
  processes:
    web:
      command: "./bin/thrust ./bin/rails server"
      port: 80
      subdomain: dummy-rails
      replicas: 2
      runs_on:
        - app
    worker:
      command: bin/jobs
      replicas: 2
      runs_on:
        - worker

setup:
  - bin/rails db:prepare

env:
  RAILS_ENV: production
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}
```

---

## CLI Commands

All commands run from CLI directory:

```bash
cd /Users/ben/Desktop/apps/rbrun/cli
```

### Deploy

```bash
bundle exec rbrun release deploy \
  -c ~/Desktop/dummy-rails/rbrun.yaml \
  -f ~/Desktop/dummy-rails \
  -e ~/Desktop/dummy-rails/.env
```

### Status

```bash
bundle exec rbrun release status -c ~/Desktop/dummy-rails/rbrun.yaml
```

### Logs

```bash
bundle exec rbrun release logs -c ~/Desktop/dummy-rails/rbrun.yaml
```

### SSH into server

```bash
bundle exec rbrun release ssh -c ~/Desktop/dummy-rails/rbrun.yaml
```

### Run command in pod

```bash
bundle exec rbrun release exec "rails console" -c ~/Desktop/dummy-rails/rbrun.yaml
```

### Destroy

```bash
bundle exec rbrun release destroy -c ~/Desktop/dummy-rails/rbrun.yaml
```

### Check resources

```bash
bundle exec rbrun release resources -c ~/Desktop/dummy-rails/rbrun.yaml
```

---

## Validation Commands

After SSH into server (`rbrun release ssh`):

### Cluster nodes

```bash
kubectl get nodes -o wide
```

Expected output (4 nodes for config above):
```
NAME                        STATUS   ROLES                  AGE
production-dummy-rails-app-1      Ready    control-plane,master   ...
production-dummy-rails-app-2      Ready    <none>                 ...
production-dummy-rails-worker-1   Ready    <none>                 ...
production-dummy-rails-db-1       Ready    <none>                 ...
```

### Pods distribution

```bash
kubectl get pods -o wide
```

Expected:
- 2 web pods on app nodes
- 2 worker pods on worker node
- 1 postgres pod on db node
- 1 tunnel pod on master

### Pod labels / node affinity

```bash
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}'
```

### Deployments

```bash
kubectl get deployments
```

Expected replicas:
- web: 2/2
- worker: 2/2
- postgres: 1/1
- tunnel: 1/1

### Services

```bash
kubectl get services
```

### Ingress

```bash
kubectl get ingress
```

---

## Test Scenarios

### 1. Fresh Deploy

1. Start with no infrastructure
2. Run deploy
3. Verify:
   - All servers created in Hetzner
   - K3s cluster formed
   - All pods running
   - App accessible at `https://dummy-rails.rb.run`

```bash
curl -I https://dummy-rails.rb.run
```

### 2. Scale Up

1. Change `compute.servers.app.count: 2` → `3`
2. Run deploy
3. Verify:
   - Only `app-3` created (app-1, app-2 untouched)
   - `app-3` joined to K3s cluster
   - No pod disruption during scale-up

### 3. Scale Down

1. Change `compute.servers.app.count: 3` → `1`
2. Run deploy
3. Verify:
   - `app-3` drained first, then `app-2`
   - Pods rescheduled to remaining nodes
   - Servers deleted from Hetzner
   - K3s nodes removed
   - Zero downtime (curl during scale-down returns 200)

### 4. Idempotent Redeploy

1. Make no config changes
2. Run deploy
3. Verify:
   - No infrastructure changes
   - Only image build + rollout
   - `new_servers` is empty
   - Workers skipped ("Skipping existing worker" in logs)

### 5. Code Change Deploy

1. Change app code (e.g., view text)
2. Commit and push
3. Run deploy
4. Verify:
   - Rolling update with zero downtime
   - New pods created before old ones terminated
   - App reflects code change

### 6. Full Destroy

1. Run destroy
2. Verify:
   - All servers deleted from Hetzner
   - Firewall deleted
   - Network deleted
   - Cloudflare tunnel deleted
   - DNS records removed
   - `rbrun release resources` shows nothing

---

## Test Matrix

| Scenario | Servers | Pods | Expected Behavior |
|----------|---------|------|-------------------|
| Fresh deploy | 0 → 4 | 0 → 6 | All created |
| Scale up app | 2 → 3 | 4 → 4 | 1 server added, pods redistribute |
| Scale down app | 3 → 1 | 4 → 4 | 2 servers drained+deleted, pods migrate |
| Add worker group | 3 → 4 | 4 → 4 | 1 server added, worker pods move |
| Idempotent | 4 → 4 | 6 → 6 | No infra changes, image rollout only |
| Destroy | 4 → 0 | 6 → 0 | All deleted |

---

## Troubleshooting

### Pods stuck in Pending

```bash
kubectl describe pod <pod-name>
```

Check node selector / affinity matches available nodes.

### Node not joining cluster

SSH to worker, check K3s agent:
```bash
systemctl status k3s-agent
journalctl -u k3s-agent -f
```

### Drain timeout

Check for pods with PodDisruptionBudget or finalizers:
```bash
kubectl get pods --field-selector spec.nodeName=<node> -o wide
kubectl describe pod <stuck-pod>
```

### SSH connection refused

Server still provisioning. Wait for cloud-init to complete:
```bash
# From local
ssh root@<ip> "cloud-init status --wait"
```

---

## Live Test URLs

| Environment | URL |
|-------------|-----|
| Production | https://dummy-rails.rb.run |

---

## Notes

- Master node is always first server of first group (e.g., `app-1`)
- Master cannot be removed (reconciliation raises error)
- Scale-down removes highest-index servers first
- Processes with subdomain require `replicas >= 2`
- Default replicas is 2
- Deploy uses local folder directly (no GitHub clone)
