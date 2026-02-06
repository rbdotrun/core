Ready to code?

Here is Claude's plan:  
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
Replace Ruby DSL with YAML configuration

Goal

Replace user-facing Ruby DSL with YAML. One file per target. Drop --branch, resolve(), target-hashes. Add multi-server with runs_on placement. Redis is service-only. Storage automatic (1 R2 bucket). Drop git: from YAML entirely —  
 repo auto-detected from remote, PAT from gh auth token. Drop cloud volumes — host path only. Delete KubernetesResources entirely.

CLI change: --env sandbox → --config config/sandbox.yml

---

YAML schema

target: sandbox

compute:  
 provider: hetzner  
 api_key: ${HETZNER_API_TOKEN}  
 location: ash  
 image: ubuntu-22.04  
 ssh_key_path: ~/.ssh/id_ed25519

# Single-server mode (compose) — use `server`:

server: cpx11

# Multi-server mode (K3s) — use `servers` (mutually exclusive with `server`):

# servers:

# web:

# type: cpx21

# count: 2

# worker:

# type: cpx11

# count: 1

cloudflare:  
 api_token: ${CLOUDFLARE_API_TOKEN}  
 account_id: ${CLOUDFLARE_ACCOUNT_ID}  
 domain: example.com

claude:  
 auth_token: ${ANTHROPIC_API_KEY}

databases:  
 postgres:  
 runs_on: worker # optional (only valid with multi-server)  
 image: pgvector/pgvector:pg17 # optional — default: postgres:16-alpine

services:  
 redis: # image is REQUIRED for all services  
 image: redis:7-alpine  
 meilisearch:  
 image: getmeili/meilisearch:v1.6  
 subdomain: search  
 runs_on: worker # optional (only valid with multi-server)  
 env: # optional per-service env vars  
 MEILI_MASTER_KEY: ${MEILI_KEY}  
 MEILI_ENV: production

app:  
 dockerfile: Dockerfile  
 processes:  
 web:  
 command: bin/rails server  
 port: 3000  
 subdomain: www  
 runs_on: [web]  
 worker:  
 command: bin/jobs  
 runs_on: [worker]

setup:

- bundle install
- rails db:prepare  


env:  
 RAILS_ENV: production  
 SECRET_KEY_BASE: ${SECRET_KEY_BASE}

---

Implementation phases

Phase 1: Add LocalGit module

New: lib/rbrun_core/local_git.rb — current_branch, repo_from_remote, gh_auth_token (shells out to gh auth token, raises if missing/unauthenticated)  
 New: test/local_git_test.rb  
 Modify: lib/rbrun_core.rb — add require

---

Phase 2: Update config model

2a. New Config::Compute::ServerGroup

New: lib/rbrun_core/config/compute/server_group.rb

class ServerGroup  
 attr_accessor :type, :count  
 attr_reader :name  
 def initialize(name:, type:, count: 1)  
 @name = name.to_sym  
 @type = type  
 @count = count  
 end  
 end

2b. Config::Compute::Hetzner (config/compute/hetzner.rb)

- Remove attr_accessor :server_type, @server_type = "cpx11"
- Add attr_accessor :server (string, single-server mode — compose)
- Add attr_reader :servers → @servers = {} (multi-server mode — K3s)
- Add def add_server_group(name, type:, count: 1) method
- Add def multi_server? → @servers.any?  


2c. Config::Compute::Base (config/compute/base.rb)

- Remove vm_based?  


2d. Configuration (config/configuration.rb)

- Add attr_accessor :target
- Delete attr_accessor :websocket_url, :api_url
- Delete resolve method
- Delete validate_for_target! method
- Delete Config::Storage class + storage DSL + storage? + storage_config
- Remove redis from Config::Database::DEFAULT_IMAGES
- Remove volume_size from Config::Database (no cloud volumes)
- Add runs_on to Config::Database (symbol), Config::Service (symbol), Config::Process (array)
- Remove replicas from Config::Process
- Config::Service: add attr_accessor :image, :env — image required (Loader raises if missing), env optional (hash)
- Config::Database: image optional (has defaults per type), remove redis from defaults  


2e. Config::Git (config/git.rb)

- Remove repo requirement from validate!
- Remove pat requirement from validate! (auto-populated at runtime via gh auth token)  


2f. Tests

Modify: test/config/configuration_test.rb

- Delete: test*resolve*_ (3), test*validate_for_target*_ (4), test_app_allows_replicas_with_hash, test_storage_creates_config, test_database_allows_overriding_image_and_volume
- Update compute tests for servers DSL (no server_type)
- Update test_env_collects_variables — scalar
- Add: test_target_accessor, test_compute_server_groups, test_database_runs_on, test_process_runs_on  


---

Phase 3: Delete volumes + KubernetesResources

Files to DELETE  
 ┌────────────────────────────────────────────────────┬────────────────────────────────────────────────────────────┐  
 │ File │ Reason │  
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/generators/kubernetes_resources.rb │ Dropped entirely — no resource limits, no priority classes │  
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/provision_volume.rb │ No cloud volumes — host path only │  
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/destroy/cleanup_volumes.rb │ No cloud volumes to clean up │  
 ├────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────┤  
 │ test/commands/deploy/provision_volume_test.rb │ Test for deleted file │  
 └────────────────────────────────────────────────────┴────────────────────────────────────────────────────────────┘  
 Files to MODIFY

lib/rbrun_core/commands/deploy/command.rb

- Delete line 17: ProvisionVolume.new(@ctx, on_log: @on_log).run if needs_volume?
- Delete needs_volume? method (lines 33–35)  


lib/rbrun_core/commands/destroy/command.rb

- Delete line 16: CleanupVolumes.new(@ctx, on_log: @on_log).run  


lib/rbrun_core/commands/deploy/setup_k3s.rb

- Delete line 138: apply_manifest!(Generators::KubernetesResources.priority_class_yaml)  


lib/rbrun_core/generators/k3s.rb — remove all KubernetesResources references:

- KubernetesResources.priority_class_for(...) → delete priority_class: from all deployment calls
- KubernetesResources.for(...) → delete resources: from all container hashes
- Remove priority_class parameter from deployment helper method  


lib/rbrun_core.rb — remove 3 requires:

- rbrun_core/generators/kubernetes_resources
- rbrun_core/commands/deploy/provision_volume
- rbrun_core/commands/destroy/cleanup_volumes  


---

Phase 4: Add Config::Loader

New: lib/rbrun_core/config/loader.rb

- Loader.load(path, env: ENV) → returns Configuration
- ${VAR} interpolation: walks parsed hash, ${NAME} → env.fetch(NAME)
- Uses DSL methods internally to populate Configuration
- No git: section in YAML — auto-populated: repo from LocalGit.repo_from_remote, pat from LocalGit.gh_auth_token
- databases: only accepts :postgres/:sqlite (no redis)
- Validates server vs servers mutual exclusivity — raise if both present, raise if neither
- Validates runs_on only allowed when servers (plural) is used — raise if runs_on appears with server (singular)  


New: test/config/loader_test.rb

Modify: lib/rbrun_core.rb — add requires for server_group and loader

---

Phase 5: Update Context

Modify: lib/rbrun_core/context.rb

- target: optional → defaults to config.target
- branch: optional → defaults to LocalGit.current_branch
- Add attr_accessor :servers (hash of "group-N" => { id:, ip: })
- server_ip returns control plane IP (first server)  


Modify: test/context_test.rb — add auto-detection tests

---

Phase 6: Remove resolve() call sites  
 ┌──────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────┐  
 │ File │ Change │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ commands/shared/create_infrastructure.rb:50 │ Rewrite for multi-server (iterate server groups) │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ commands/deploy/setup_tunnel.rb:39,52,74,82 │ resolve(x.subdomain, ...) → x.subdomain │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ commands/deploy_sandbox/setup_application.rb:132–134 │ Remove resolve, use value directly │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ generators/k3s.rb │ Remove target: param, @target, resolve helper, 4 call sites │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ generators/compose.rb:101 │ resolve(value, ...) → value.to_s │  
 ├──────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────┤  
 │ commands/deploy/deploy_manifests.rb:21 │ Remove target: from K3s.new │  
 └──────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────┘  
 Note: provision_volume.rb resolve site already deleted in Phase 3.

Test changes:

- test/generators/k3s_test.rb — remove target: from all K3s.new calls
- test/generators/compose_test.rb:56 — scalar env value  


---

Phase 7: Multi-server infrastructure + K3s cluster join

7a. CreateInfrastructure (commands/shared/create_infrastructure.rb)

Single-server mode (compute.server): same as today — create 1 server with the given type, store on ctx.server_id / ctx.server_ip. No ctx.servers hash needed.

Multi-server mode (compute.servers):

First deploy (no existing servers):  
 create firewall → create network → create SSH key →  
 for each server group, for each index 1..count:  
 create server (type from group, name: "{prefix}-{group}-{i}") →  
 store all servers on ctx.servers →  
 wait SSH on all

Subsequent deploys (release mode) — state reconciliation:

1.  List existing servers from compute provider (by prefix match)
2.  Build desired state from YAML (server groups × counts)
3.  Diff:
    - servers_to_create = desired - existing
    - servers_to_delete = existing - desired
4.  Create new servers (same flow as first deploy)
5.  For each server_to_delete:  
    a. kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --timeout=300s  
    b. Wait for drain completion  
    c. kubectl delete node <node-name>  
    d. Delete server from compute provider
6.  Store final server set on ctx.servers
7.  Wait SSH on new servers  


Naming convention for diffing: servers named {prefix}-{group}-{i} (e.g. myapp-production-web-1, myapp-production-worker-2). The compute API list_servers filtered by prefix gives current state. Desired state is computed from YAML  
 group names × counts.

Note: Scale-up adds web-3 etc. Scale-down removes highest index first. Type changes (e.g. cpx11 → cpx21) require drain + delete + recreate — treated as delete old + create new.

ctx.servers structure: { "web-1" => { id: "srv-1", ip: "1.2.3.4", private_ip: nil, group: "web" }, ... }

First server created = master (K3s control plane). ctx.server_ip = master's public IP.

7b. SetupK3s rewrite (commands/deploy/setup_k3s.rb)

Reference: /Users/ben/Desktop/gems/cli/lib/nvoi/cli/deploy/steps/setup_k3s.rb

Master node setup (first server — runs on ctx.server_ip):

1.  wait_for_cloud_init / discover_network / install_docker / configure_registries — same as today
2.  Discover private IP: ip -4 addr show <iface> | grep inet where iface = enp7s0 (Hetzner private network)
3.  Install K3s server mode:  
    curl -sfL https://get.k3s.io | sudo sh -s - server \  
     --bind-address <private_ip> \  
     --advertise-address <private_ip> \  
     --node-ip <private_ip> \  
     --flannel-backend wireguard-native \  
     --flannel-iface <iface> \  
     --disable traefik \  
     --node-name <server_name> \  
     --write-kubeconfig-mode 644
4.  Retrieve cluster token: sudo cat /var/lib/rancher/k3s/server/node-token
5.  Setup kubeconfig (same as today, but server: uses private IP)
6.  Deploy registry + ingress (same as today, minus priority classes)
7.  Label master node: kubectl label node <name> rbrun.dev/server-group=<group> --overwrite  


Worker node setup (all other servers — iterate ctx.servers, skip master):

1.  SSH into worker via its public IP
2.  wait_for_cloud_init / discover_network / install_docker / configure_registries
3.  Discover worker private IP
4.  Join K3s cluster as agent:  
    curl -sfL https://get.k3s.io | K3S_URL="https://<master_private_ip>:6443" \  
     K3S_TOKEN="<cluster_token>" sh -s - agent \  
     --node-ip <worker_private_ip> \  
     --flannel-iface <iface> \  
     --node-name <worker_name>
5.  Wait for node ready: kubectl get node <name> until Ready
6.  Label worker: kubectl label node <name> rbrun.dev/server-group=<group> --overwrite  


Single-server optimization: When only 1 server total, skip private IP discovery / WireGuard / network binding. Install K3s with --disable traefik only (same as current behavior). No cluster join needed.

7c. K3s generator (generators/k3s.rb) — nodeSelector

Add nodeSelector to deployments when runs_on is present:

# For processes: runs_on is an array → schedule on any matching group

spec[:nodeSelector] = { "rbrun.dev/server-group" => runs_on.first.to_s }

# For multiple groups, use nodeAffinity with In operator instead

# For databases/services: runs_on is a string

spec[:nodeSelector] = { "rbrun.dev/server-group" => runs_on.to_s }

When runs_on is an array with multiple entries, use pod affinity:  
 affinity:  
 nodeAffinity:  
 requiredDuringSchedulingIgnoredDuringExecution:  
 nodeSelectorTerms:  
 - matchExpressions:  
 - key: rbrun.dev/server-group  
 operator: In  
 values: [web, worker]

7d. Test updates

- test/commands/shared/create_infrastructure_test.rb — multi-server stub expectations
- test/commands/deploy/setup_k3s_test.rb — master/worker setup, node labeling, single-server fallback
- test/generators/k3s_test.rb — nodeSelector in generated manifests  


---

Phase 8: Redis cleanup

- Remove :redis from Config::Database::DEFAULT_IMAGES
- Compose generator: config.database?(:redis) || config.service?(:redis) → config.service?(:redis)
- SetupApplication: same
- K3s generator: remove redis_manifests from database_manifests, redis handled via service_manifests  


---

Phase 9: Update examples

Modify: examples/deploy.rb — use Config::Loader.load(path)  
 New: examples/production.yaml

---

Phase 10: Verify

bundle exec rake test

---

Files summary  
 ┌─────────────────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  
 │ File │ Action │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ NEW │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/local_git.rb │ Branch + repo auto-detection │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/compute/server_group.rb │ Server group config struct │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/loader.rb │ YAML parsing + ${VAR} interpolation │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/local_git_test.rb │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/config/loader_test.rb │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ examples/production.yaml │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ DELETE │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/generators/kubernetes_resources.rb │ No resource limits / priority classes │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/provision_volume.rb │ No cloud volumes │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/destroy/cleanup_volumes.rb │ No cloud volumes │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/commands/deploy/provision_volume_test.rb │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ MODIFY │ │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core.rb │ Add 3 requires, remove 3 requires │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/configuration.rb │ +target, -resolve, -validate_for_target!, -websocket/api_url, -Storage, -volume_size, -replicas, +runs_on, -redis from DB │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/compute/hetzner.rb │ servers hash replaces server_type │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/compute/base.rb │ -vm_based? │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/config/git.rb │ repo optional in validate! │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/context.rb │ auto-detect branch/target; +servers hash │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/command.rb │ remove ProvisionVolume step │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/destroy/command.rb │ remove CleanupVolumes step │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/shared/create_infrastructure.rb │ multi-server loop │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/setup_k3s.rb │ remove priority class apply; add node labeling │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/setup_tunnel.rb │ remove 4 resolve() calls │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy/deploy_manifests.rb │ remove target: from K3s.new │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/commands/deploy_sandbox/setup_application.rb │ remove resolve(); simplify redis │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/generators/k3s.rb │ remove resolve/target, remove KubernetesResources refs, add nodeSelector, remove redis from DB path │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ lib/rbrun_core/generators/compose.rb │ remove resolve(); simplify redis │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ examples/deploy.rb │ rewrite for YAML │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/config/configuration_test.rb │ remove ~10 tests; update compute/env; add new │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/context_test.rb │ add auto-detection tests │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/generators/k3s_test.rb │ remove target:; update for no KubernetesResources │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/generators/compose_test.rb │ scalar env; redis as service │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/commands/shared/create_infrastructure_test.rb │ multi-server │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/commands/deploy/setup_k3s_test.rb │ node labeling; no priority classes │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/commands/deploy/command_test.rb │ remove ProvisionVolume stub │  
 ├─────────────────────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ test/commands/destroy/command_test.rb │ remove CleanupVolumes stub │  
 └─────────────────────
