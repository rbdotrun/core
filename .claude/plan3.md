# Implementation Plan: Local Build with SSH Tunnel to Remote Registry

## Summary

Adapt rbrun to build Docker images locally and push to the remote in-cluster registry via SSH tunnel, eliminating remote build compute and context streaming.

## Current State

**rbrun (now):**
```
Local machine                    Remote server
[source files] --SSH stream--> [Docker daemon builds] --> [registry:30500]
```
- Build context streamed over SSH to remote Docker daemon via DOCKER_HOST=ssh://
- Build compute uses server CPU/RAM
- Build cache accumulates on server disk
- No local Docker required

**Kamal (reference):**
```
Local machine                              Remote server
[local registry:5000] <--SSH tunnel--  [docker pull localhost:5000]
     ^
     |
[local build + push]
```
- Runs local registry container on dev machine
- Builds locally with buildx + `network=host` driver option
- SSH **remote** port forwarding: remote's localhost:5000 tunnels back to local registry
- Remote servers pull through tunnel

## Target State

**rbrun (proposed):**
```
Local machine                              Remote server
[local build] --> push to localhost:LOCAL_PORT
                           |
                      SSH tunnel (local forward)
                           |
                           v
                    [registry:30500 on server]
```
- Build locally with local Docker daemon
- SSH **local** port forwarding: forward local port to remote's 30500
- Push to `localhost:LOCAL_PORT` which tunnels to remote registry
- No context streaming, local CPU/RAM used

## Key Differences from Kamal

| Aspect | Kamal | rbrun (proposed) |
|--------|-------|------------------|
| Registry location | Local container | Remote in-cluster |
| SSH tunnel direction | Remote forward (R) | Local forward (L) |
| Who pulls | Remote servers pull from local | K3s pulls from local registry |
| Image storage | Local, then pulled | Pushed directly to remote |

We use **local** port forwarding (not remote) because we want to push TO the remote registry, not have remotes pull FROM us.

---

## Implementation Details

### 1. Add SSH Port Forwarding to SSH Client

**File:** `lib/rbrun_core/clients/ssh.rb`

Add method using Net::SSH's forwarding capabilities:

```ruby
# Forward a local port to a remote host:port (as seen from the SSH server)
# This creates: localhost:local_port -> SSH tunnel -> remote_host:remote_port
def with_local_forward(local_port:, remote_host:, remote_port:)
  require 'concurrent'

  ready = Concurrent::Event.new
  stop_flag = Concurrent::AtomicBoolean.new(false)

  tunnel_thread = Thread.new do
    Net::SSH.start(@host, @user, **ssh_options.merge(
      port: @port,
      keepalive: true,
      keepalive_interval: 30
    )) do |ssh|
      ssh.forward.local(local_port, remote_host, remote_port)
      ready.set

      ssh.loop(0.1) { !stop_flag.true? }
    end
  rescue => e
    ready.set  # Unblock even on error
    raise
  end

  raise Ssh::ConnectionError, "SSH tunnel not ready after 30s" unless ready.wait(30)

  begin
    yield local_port
  ensure
    stop_flag.make_true
    tunnel_thread.join(5)
  end
end
```

For registry: `localhost:30501` (local) -> tunnel -> `localhost:30500` (on server)

### 2. Create Local Build Command

**New file:** `lib/rbrun_core/commands/deploy/build_image_local.rb`

```ruby
# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      # Builds Docker image locally and pushes to remote registry via SSH tunnel.
      #
      # Flow:
      # 1. Establish SSH tunnel: local port -> remote registry:30500
      # 2. Build image locally using local Docker daemon
      # 3. Push to localhost:tunnel_port (goes to remote registry)
      #
      # Benefits over remote build:
      # - Uses local CPU/RAM for build
      # - Build cache on local machine
      # - No build cache on server
      # - Only image layers transferred (not full context)
      #
      # Requires: local Docker daemon running
      class BuildImageLocal
        REGISTRY_PORT = 30_500
        LOCAL_TUNNEL_PORT = 30_501  # Avoid conflict if local 30500 in use

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
        end

        def run
          raise Error::Standard, "source_folder is required for build" unless @ctx.source_folder

          ssh_client = Clients::Ssh.new(
            host: @ctx.server_ip,
            private_key: @ctx.config.target_config.ssh_private_key,
            user: Naming.default_user
          )

          log("docker_build", "Building locally from #{@ctx.source_folder}")

          ssh_client.with_local_forward(
            local_port: LOCAL_TUNNEL_PORT,
            remote_host: "localhost",
            remote_port: REGISTRY_PORT
          ) do
            result = build_and_push!(@ctx.source_folder)
            @ctx.registry_tag = result[:registry_tag]
          end
        end

        private

        def build_and_push!(context_path)
          ts = Time.now.utc.strftime("%Y%m%d%H%M%S")
          prefix = @ctx.prefix
          local_tag = "#{prefix}:#{ts}"

          # Tag for tunnel endpoint (where we push)
          tunnel_tag = "localhost:#{LOCAL_TUNNEL_PORT}/#{prefix}:#{ts}"
          # Tag for K3s (what pods reference - the actual remote registry)
          registry_tag = "localhost:#{REGISTRY_PORT}/#{prefix}:#{ts}"

          dockerfile = @ctx.config.app_config.dockerfile
          platform = @ctx.config.app_config.platform

          # Build locally with buildx, push directly to registry through tunnel
          # --output=type=registry pushes as part of build (no separate push step)
          # registry.insecure=true allows HTTP registry
          run_docker!(
            "buildx", "build",
            "--platform", platform,
            "--pull",
            "-f", dockerfile,
            "-t", tunnel_tag,
            "--output=type=registry,registry.insecure=true",
            ".",
            chdir: context_path
          )

          # Also tag locally for reference
          run_docker!("buildx", "build",
                      "--platform", platform,
                      "-f", dockerfile,
                      "-t", local_tag,
                      "-t", "#{prefix}:latest",
                      "--load",  # Load into local docker
                      ".",
                      chdir: context_path)

          { local_tag: local_tag, registry_tag: registry_tag, timestamp: ts }
        end

        def run_docker!(*args, chdir: nil)
          opts = chdir ? { chdir: } : {}
          # No DOCKER_HOST - uses local Docker daemon
          success = system("docker", *args, **opts)
          raise Error::Standard, "docker #{args.first} failed" unless success
        end

        def log(category, message = nil)
          @logger&.log(category, message)
        end
      end
    end
  end
end
```

### 3. Add Configuration Option

**File:** `lib/rbrun_core/dsl/deploy.rb`

Add `local_build` option:

```ruby
def local_build(value = true)
  @config.local_build = value
end
```

**File:** `lib/rbrun_core/config/deploy.rb`

```ruby
attr_accessor :local_build

def initialize
  # ...existing...
  @local_build = false  # Default to remote build for backwards compatibility
end
```

### 4. Update Deploy Orchestration

**File:** `lib/rbrun_core/commands/deploy.rb`

```ruby
def build_image
  if @ctx.config.deploy_config.local_build
    Deploy::BuildImageLocal.new(@ctx, logger: @logger).run
  else
    Deploy::BuildImage.new(@ctx, logger: @logger).run
  end
end
```

### 5. Handle Insecure Registry

Using `--output=type=registry,registry.insecure=true` in buildx handles this automatically. No local Docker daemon config changes needed.

### 6. Add concurrent-ruby Dependency

**File:** `rbrun_core.gemspec`

```ruby
spec.add_dependency "concurrent-ruby", "~> 1.2"
```

Already used by SSHKit transitively, but make it explicit.

---

## Files to Create/Modify

| File | Action | Description |
|------|--------|-------------|
| `lib/rbrun_core/clients/ssh.rb` | Modify | Add `with_local_forward` method |
| `lib/rbrun_core/commands/deploy/build_image_local.rb` | Create | New local build command |
| `lib/rbrun_core/commands/deploy.rb` | Modify | Add build strategy selection |
| `lib/rbrun_core/config/deploy.rb` | Modify | Add `local_build` attribute |
| `lib/rbrun_core/dsl/deploy.rb` | Modify | Add `local_build` DSL method |
| `rbrun_core.gemspec` | Modify | Add concurrent-ruby dependency |

---

## Testing Strategy

1. **Unit test SSH tunnel**: Mock Net::SSH, verify `forward.local` called correctly
2. **Integration test**: Build small test image, verify it appears in remote registry via `docker images` over SSH
3. **Cross-platform test**: Build on M1 Mac for linux/amd64, verify runs on server

---

## Migration Path

1. Add `local_build: true` as **opt-in** config
2. Keep existing `BuildImage` as default (backwards compatible)
3. Users enable via DSL:
   ```ruby
   deploy do
     local_build true
   end
   ```
   Or YAML:
   ```yaml
   deploy:
     local_build: true
   ```

---

## Benefits

- Local CPU/RAM used for builds
- Build cache on local machine (faster rebuilds)
- No build cache accumulation on server
- Only image layers pushed (not full source context)
- Local Docker required (already common for development)

---

## Potential Issues & Mitigations

| Issue | Mitigation |
|-------|------------|
| Large images over slow connection | First build transfers all layers; subsequent builds only changed layers (like before) |
| Cross-platform (M1 → amd64) | buildx handles via QEMU; `--platform linux/amd64` works |
| CI/CD without local Docker | Keep remote build as default; CI uses remote build |
| Port 30501 already in use | Make tunnel port configurable or auto-find free port |
| buildx not installed | Detect and fall back to regular docker build + push, or error with clear message |

---

## Verification Commands

```bash
# Test SSH tunnel manually
ssh -L 30501:localhost:30500 deploy@server_ip

# In another terminal, push to tunnel
docker tag myimage localhost:30501/myimage:test
docker push localhost:30501/myimage:test

# Verify on server
ssh deploy@server_ip docker images | grep myimage
```
