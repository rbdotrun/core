Restructure rbrun-core into layered architecture

Goal

Reorganize lib/rbrun_core/ from a flat, service-grouped layout into four clear architectural layers:

- Foundation (root): version, errors, naming, context
- config/: configuration DSL + provider/cloudflare configs
- clients/: pure API/protocol wrappers
- generators/: artifact producers (YAML, manifests)
- commands/: orchestrators with steps nested under their command

Also: rename Ruby modules to match new file paths, extract inlined destroy logic into proper steps, restructure tests to mirror.

---

Target directory structure

lib/rbrun_core/  
 rbrun_core.rb # entry point (rewritten requires)  
 version.rb  
 errors.rb # renamed from http_errors.rb  
 naming.rb  
 context.rb

config/  
 configuration.rb # RbrunCore::Configuration (main DSL)  
 git.rb # RbrunCore::Config::Git  
 claude.rb # RbrunCore::Config::Claude  
 cloudflare.rb # RbrunCore::Config::Cloudflare  
 compute/  
 base.rb # RbrunCore::Config::Compute::Base  
 registry.rb # RbrunCore::Config::Compute::Registry  
 hetzner.rb # RbrunCore::Config::Compute::Hetzner  
 scaleway.rb # RbrunCore::Config::Compute::Scaleway

clients/  
 base.rb # RbrunCore::Clients::Base  
 ssh.rb # RbrunCore::Clients::Ssh  
 kubectl.rb # RbrunCore::Clients::Kubectl  
 github.rb # RbrunCore::Clients::Github  
 cloudflare.rb # RbrunCore::Clients::Cloudflare  
 cloudflare_r2.rb # RbrunCore::Clients::CloudflareR2  
 cloudflare_worker.rb # RbrunCore::Clients::CloudflareWorker  
 compute/  
 types.rb # RbrunCore::Clients::Compute::Types (Server, Volume, etc.)  
 hetzner.rb # RbrunCore::Clients::Compute::Hetzner  
 scaleway.rb # RbrunCore::Clients::Compute::Scaleway

generators/  
 cloud_init.rb # RbrunCore::Generators::CloudInit  
 k3s.rb # RbrunCore::Generators::K3s (stays)  
 compose.rb # RbrunCore::Generators::Compose (stays)  
 kubernetes_resources.rb # RbrunCore::Generators::KubernetesResources

commands/  
 shared/  
 create_infrastructure.rb # RbrunCore::Commands::Shared::CreateInfrastructure  
 delete_infrastructure.rb # RbrunCore::Commands::Shared::DeleteInfrastructure (new)  
 cleanup_tunnel.rb # RbrunCore::Commands::Shared::CleanupTunnel (new)  
 deploy/  
 command.rb # RbrunCore::Commands::Deploy  
 setup_k3s.rb # RbrunCore::Commands::Deploy::SetupK3s  
 provision_volume.rb # RbrunCore::Commands::Deploy::ProvisionVolume  
 setup_tunnel.rb # RbrunCore::Commands::Deploy::SetupTunnel  
 build_image.rb # RbrunCore::Commands::Deploy::BuildImage  
 cleanup_images.rb # RbrunCore::Commands::Deploy::CleanupImages  
 deploy_manifests.rb # RbrunCore::Commands::Deploy::DeployManifests  
 deploy_sandbox/  
 command.rb # RbrunCore::Commands::DeploySandbox  
 setup_application.rb # RbrunCore::Commands::DeploySandbox::SetupApplication  
 destroy/  
 command.rb # RbrunCore::Commands::Destroy  
 cleanup_volumes.rb # RbrunCore::Commands::Destroy::CleanupVolumes (extracted)  
 destroy_sandbox/  
 command.rb # RbrunCore::Commands::DestroySandbox  
 stop_containers.rb # RbrunCore::Commands::DestroySandbox::StopContainers (extracted)

Test structure (mirrors source)

test/  
 test_helper.rb  
 rbrun_core_test.rb  
 context_test.rb  
 naming_test.rb  
 config/  
 configuration_test.rb  
 clients/  
 ssh_test.rb  
 cloudflare_test.rb  
 cloudflare_worker_test.rb  
 compute/  
 hetzner_test.rb  
 scaleway_test.rb  
 generators/  
 cloud_init_test.rb  
 k3s_test.rb  
 compose_test.rb  
 commands/  
 shared/  
 create_infrastructure_test.rb  
 deploy/  
 command_test.rb  
 setup_k3s_test.rb  
 build_image_test.rb  
 deploy_manifests_test.rb  
 provision_volume_test.rb  
 setup_tunnel_test.rb  
 deploy_sandbox/  
 command_test.rb  
 setup_application_test.rb  
 destroy/  
 command_test.rb  
 destroy_sandbox/  
 command_test.rb

---

Complete file + module rename mapping

Foundation (root level)  
 ┌────────────────┬──────────────────────────────┬────────────────────────────────────────────────┬──────────────────────────┬──────────────────────────────────────────────────┐  
 │ Old path │ New path │ Old module │ New module │ Notes │  
 ├────────────────┼──────────────────────────────┼────────────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────┤  
 │ http_errors.rb │ errors.rb │ RbrunCore::Error, ApiError, ConfigurationError │ same │ file rename only │  
 ├────────────────┼──────────────────────────────┼────────────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────┤  
 │ base_client.rb │ (deleted, moves to clients/) │ RbrunCore::BaseClient │ RbrunCore::Clients::Base │ │  
 ├────────────────┼──────────────────────────────┼────────────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────┤  
 │ version.rb │ version.rb │ same │ same │ no change │  
 ├────────────────┼──────────────────────────────┼────────────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────┤  
 │ naming.rb │ naming.rb │ same │ same │ no change │  
 ├────────────────┼──────────────────────────────┼────────────────────────────────────────────────┼──────────────────────────┼──────────────────────────────────────────────────┤  
 │ context.rb │ context.rb │ same │ same │ update internal refs: Ssh::Client → Clients::Ssh │  
 └────────────────┴──────────────────────────────┴────────────────────────────────────────────────┴──────────────────────────┴──────────────────────────────────────────────────┘  
 Config layer  
 ┌──────────────────────────────────────┬────────────────────────────┬────────────────────────────────────────┬──────────────────────────────────────┐  
 │ Old path │ New path │ Old module │ New module │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ configuration.rb │ config/configuration.rb │ RbrunCore::Configuration │ same (class name unchanged) │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ (inline classes in configuration.rb) │ (stay inline) │ RbrunCore::DatabaseConfig │ RbrunCore::Config::Database │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ │ │ RbrunCore::BackupConfig │ RbrunCore::Config::Backup │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ │ │ RbrunCore::ServiceConfig │ RbrunCore::Config::Service │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ │ │ RbrunCore::AppConfig │ RbrunCore::Config::App │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ │ │ RbrunCore::ProcessConfig │ RbrunCore::Config::Process │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ │ │ RbrunCore::StorageConfig │ RbrunCore::Config::Storage │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ configuration/git_config.rb │ config/git.rb │ RbrunCore::Configuration::GitConfig │ RbrunCore::Config::Git │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ configuration/claude_config.rb │ config/claude.rb │ RbrunCore::Configuration::ClaudeConfig │ RbrunCore::Config::Claude │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ cloudflare/config.rb │ config/cloudflare.rb │ RbrunCore::Cloudflare::Config │ RbrunCore::Config::Cloudflare │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ providers/base.rb │ config/compute/base.rb │ RbrunCore::Providers::Base │ RbrunCore::Config::Compute::Base │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ providers/registry.rb │ config/compute/registry.rb │ RbrunCore::Providers::Registry │ RbrunCore::Config::Compute::Registry │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ providers/hetzner/config.rb │ config/compute/hetzner.rb │ RbrunCore::Providers::Hetzner::Config │ RbrunCore::Config::Compute::Hetzner │  
 ├──────────────────────────────────────┼────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────┤  
 │ providers/scaleway/config.rb │ config/compute/scaleway.rb │ RbrunCore::Providers::Scaleway::Config │ RbrunCore::Config::Compute::Scaleway │  
 └──────────────────────────────────────┴────────────────────────────┴────────────────────────────────────────┴──────────────────────────────────────┘  
 Key cross-layer refs to update in config classes:

- Hetzner#client → Clients::Compute::Hetzner.new(api_key:) (was Client.new(api_key:))
- Scaleway#client → Clients::Compute::Scaleway.new(api_key:, project_id:, zone:)
- Config::Cloudflare#client → Clients::Cloudflare.new(api_token:, account_id:)
- Config::Cloudflare#r2 → Clients::CloudflareR2.new(api_token:, account_id:)
- Configuration#initialize → Config::Git.new, Config::Claude.new
- Configuration#compute → Config::Compute::Registry.build(provider, &)
- Configuration#cloudflare → Config::Cloudflare.new
- Config::Compute::Registry::PROVIDERS → update string constants to new class paths

Clients layer  
 ┌──────────────────────────────┬──────────────────────────────┬────────────────────────────────────────┬───────────────────────────────────────┐  
 │ Old path │ New path │ Old module │ New module │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ base_client.rb │ clients/base.rb │ RbrunCore::BaseClient │ RbrunCore::Clients::Base │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ ssh/client.rb │ clients/ssh.rb │ RbrunCore::Ssh::Client │ RbrunCore::Clients::Ssh │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ kubernetes/kubectl.rb │ clients/kubectl.rb │ RbrunCore::Kubernetes::Kubectl │ RbrunCore::Clients::Kubectl │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ github/client.rb │ clients/github.rb │ RbrunCore::Github::Client │ RbrunCore::Clients::Github │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ cloudflare/client.rb │ clients/cloudflare.rb │ RbrunCore::Cloudflare::Client │ RbrunCore::Clients::Cloudflare │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ cloudflare/r2.rb │ clients/cloudflare_r2.rb │ RbrunCore::Cloudflare::R2 │ RbrunCore::Clients::CloudflareR2 │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ cloudflare/worker.rb │ clients/cloudflare_worker.rb │ RbrunCore::Cloudflare::Worker │ RbrunCore::Clients::CloudflareWorker │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ providers/types.rb │ clients/compute/types.rb │ RbrunCore::Providers::Types │ RbrunCore::Clients::Compute::Types │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ providers/hetzner/client.rb │ clients/compute/hetzner.rb │ RbrunCore::Providers::Hetzner::Client │ RbrunCore::Clients::Compute::Hetzner │  
 ├──────────────────────────────┼──────────────────────────────┼────────────────────────────────────────┼───────────────────────────────────────┤  
 │ providers/scaleway/client.rb │ clients/compute/scaleway.rb │ RbrunCore::Providers::Scaleway::Client │ RbrunCore::Clients::Compute::Scaleway │  
 └──────────────────────────────┴──────────────────────────────┴────────────────────────────────────────┴───────────────────────────────────────┘  
 Key updates:

- All clients that inherit BaseClient → inherit Clients::Base
- Hetzner/Scaleway clients that reference Types::Server etc → Compute::Types::Server (resolved within Clients::Compute)
- SSH client error classes (RbrunCore::Ssh::Client::CommandError etc.) → RbrunCore::Clients::Ssh::CommandError

Generators layer  
 ┌─────────────────────────┬────────────────────────────────────┬──────────────────────────────────┬────────────────────────────────────────────┐  
 │ Old path │ New path │ Old module │ New module │  
 ├─────────────────────────┼────────────────────────────────────┼──────────────────────────────────┼────────────────────────────────────────────┤  
 │ providers/cloud_init.rb │ generators/cloud_init.rb │ RbrunCore::Providers::CloudInit │ RbrunCore::Generators::CloudInit │  
 ├─────────────────────────┼────────────────────────────────────┼──────────────────────────────────┼────────────────────────────────────────────┤  
 │ generators/k3s.rb │ generators/k3s.rb │ RbrunCore::Generators::K3s │ same │  
 ├─────────────────────────┼────────────────────────────────────┼──────────────────────────────────┼────────────────────────────────────────────┤  
 │ generators/compose.rb │ generators/compose.rb │ RbrunCore::Generators::Compose │ same │  
 ├─────────────────────────┼────────────────────────────────────┼──────────────────────────────────┼────────────────────────────────────────────┤  
 │ kubernetes/resources.rb │ generators/kubernetes_resources.rb │ RbrunCore::Kubernetes::Resources │ RbrunCore::Generators::KubernetesResources │  
 └─────────────────────────┴────────────────────────────────────┴──────────────────────────────────┴────────────────────────────────────────────┘  
 Commands layer

Existing steps → nested under commands:  
 ┌────────────────────────────────┬──────────────────────────────────────────────┬────────────────────────────────────────┬──────────────────────────────────────────────────────┐  
 │ Old path │ New path │ Old module │ New module │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/create_infrastructure.rb │ commands/shared/create_infrastructure.rb │ RbrunCore::Steps::CreateInfrastructure │ RbrunCore::Commands::Shared::CreateInfrastructure │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/setup_k3s.rb │ commands/deploy/setup_k3s.rb │ RbrunCore::Steps::SetupK3s │ RbrunCore::Commands::Deploy::SetupK3s │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/provision_volume.rb │ commands/deploy/provision_volume.rb │ RbrunCore::Steps::ProvisionVolume │ RbrunCore::Commands::Deploy::ProvisionVolume │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/setup_tunnel.rb │ commands/deploy/setup_tunnel.rb │ RbrunCore::Steps::SetupTunnel │ RbrunCore::Commands::Deploy::SetupTunnel │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/build_image.rb │ commands/deploy/build_image.rb │ RbrunCore::Steps::BuildImage │ RbrunCore::Commands::Deploy::BuildImage │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/cleanup_images.rb │ commands/deploy/cleanup_images.rb │ RbrunCore::Steps::CleanupImages │ RbrunCore::Commands::Deploy::CleanupImages │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/deploy_manifests.rb │ commands/deploy/deploy_manifests.rb │ RbrunCore::Steps::DeployManifests │ RbrunCore::Commands::Deploy::DeployManifests │  
 ├────────────────────────────────┼──────────────────────────────────────────────┼────────────────────────────────────────┼──────────────────────────────────────────────────────┤  
 │ steps/setup_application.rb │ commands/deploy_sandbox/setup_application.rb │ RbrunCore::Steps::SetupApplication │ RbrunCore::Commands::DeploySandbox::SetupApplication │  
 └────────────────────────────────┴──────────────────────────────────────────────┴────────────────────────────────────────┴──────────────────────────────────────────────────────┘  
 Existing commands → command.rb inside subdirectories:  
 ┌─────────────────────────────┬─────────────────────────────────────┬─────────────────────────────────────┬────────────┐  
 │ Old path │ New path │ Old module │ New module │  
 ├─────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────┼────────────┤  
 │ commands/deploy.rb │ commands/deploy/command.rb │ RbrunCore::Commands::Deploy │ same │  
 ├─────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────┼────────────┤  
 │ commands/deploy_sandbox.rb │ commands/deploy_sandbox/command.rb │ RbrunCore::Commands::DeploySandbox │ same │  
 ├─────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────┼────────────┤  
 │ commands/destroy.rb │ commands/destroy/command.rb │ RbrunCore::Commands::Destroy │ same │  
 ├─────────────────────────────┼─────────────────────────────────────┼─────────────────────────────────────┼────────────┤  
 │ commands/destroy_sandbox.rb │ commands/destroy_sandbox/command.rb │ RbrunCore::Commands::DestroySandbox │ same │  
 └─────────────────────────────┴─────────────────────────────────────┴─────────────────────────────────────┴────────────┘  
 New files — extracted from inlined destroy logic:  
 ┌─────────────────────────────────────────────┬─────────────────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  
 │ New path │ New module │ Extracted from │  
 ├─────────────────────────────────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ commands/shared/delete_infrastructure.rb │ RbrunCore::Commands::Shared::DeleteInfrastructure │ Destroy#delete_infrastructure! + DestroySandbox#delete_infrastructure! │  
 ├─────────────────────────────────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ commands/shared/cleanup_tunnel.rb │ RbrunCore::Commands::Shared::CleanupTunnel │ Destroy#cleanup_tunnel! + DestroySandbox#cleanup_tunnel! (merged to superset — always attempt DNS cleanup, it's idempotent) │  
 ├─────────────────────────────────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ commands/destroy/cleanup_volumes.rb │ RbrunCore::Commands::Destroy::CleanupVolumes │ Destroy#cleanup_volumes! │  
 ├─────────────────────────────────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤  
 │ commands/destroy_sandbox/stop_containers.rb │ RbrunCore::Commands::DestroySandbox::StopContainers │ DestroySandbox#stop_containers! │  
 └─────────────────────────────────────────────┴─────────────────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  
 Step references inside commands update:

Deploy command.rb:

# Before

Steps::CreateInfrastructure.new(@ctx, on_log: @on_log).run  
 Steps::SetupK3s.new(@ctx, on_log: @on_log).run

# After

Shared::CreateInfrastructure.new(@ctx, on_log: @on_log).run  
 SetupK3s.new(@ctx, on_log: @on_log).run # nested class, no prefix needed

Destroy command.rb:

# Before (inlined methods)

# After

Shared::CleanupTunnel.new(@ctx, on_log: @on_log).run if @ctx.cloudflare_configured?  
 CleanupVolumes.new(@ctx, on_log: @on_log).run  
 Shared::DeleteInfrastructure.new(@ctx, on_log: @on_log).run

---

Implementation order

Phase 1: Create directory structure

mkdir -p lib/rbrun_core/{config/compute,clients/compute,generators,commands/{shared,deploy,deploy_sandbox,destroy,destroy_sandbox}}  
 mkdir -p test/{config,clients/compute,generators,commands/{shared,deploy,deploy_sandbox,destroy,destroy_sandbox}}

Phase 2: Foundation files

1.  Rename http_errors.rb → errors.rb (file rename only, module names unchanged)
2.  Update context.rb — change Ssh::Client → Clients::Ssh

Phase 3: Config layer

1.  Move + remodule configuration/git_config.rb → config/git.rb (Config::Git)
2.  Move + remodule configuration/claude_config.rb → config/claude.rb (Config::Claude)
3.  Move + remodule cloudflare/config.rb → config/cloudflare.rb (Config::Cloudflare)
4.  Move + remodule providers/base.rb → config/compute/base.rb (Config::Compute::Base)
5.  Move + remodule providers/registry.rb → config/compute/registry.rb (Config::Compute::Registry)
6.  Move + remodule providers/hetzner/config.rb → config/compute/hetzner.rb (Config::Compute::Hetzner)
7.  Move + remodule providers/scaleway/config.rb → config/compute/scaleway.rb (Config::Compute::Scaleway)
8.  Move + remodule configuration.rb → config/configuration.rb (update all internal refs to new names)

Phase 4: Clients layer

1.  Move + remodule base_client.rb → clients/base.rb (Clients::Base)
2.  Move + remodule ssh/client.rb → clients/ssh.rb (Clients::Ssh)
3.  Move + remodule kubernetes/kubectl.rb → clients/kubectl.rb (Clients::Kubectl)
4.  Move + remodule github/client.rb → clients/github.rb (Clients::Github)
5.  Move + remodule cloudflare/client.rb → clients/cloudflare.rb (Clients::Cloudflare)
6.  Move + remodule cloudflare/r2.rb → clients/cloudflare_r2.rb (Clients::CloudflareR2)
7.  Move + remodule cloudflare/worker.rb → clients/cloudflare_worker.rb (Clients::CloudflareWorker)
8.  Move + remodule providers/types.rb → clients/compute/types.rb (Clients::Compute::Types)
9.  Move + remodule providers/hetzner/client.rb → clients/compute/hetzner.rb (Clients::Compute::Hetzner)
10. Move + remodule providers/scaleway/client.rb → clients/compute/scaleway.rb (Clients::Compute::Scaleway)

Phase 5: Generators layer

1.  Move + remodule providers/cloud_init.rb → generators/cloud_init.rb (Generators::CloudInit)
2.  generators/k3s.rb — stays, no module change
3.  generators/compose.rb — stays, no module change
4.  Move + remodule kubernetes/resources.rb → generators/kubernetes_resources.rb (Generators::KubernetesResources)

Phase 6: Commands layer

1.  Move steps into command subdirectories (update module wrapping)
2.  Move command files into command.rb within subdirectories
3.  Extract destroy inlined logic into new step files
4.  Update command files to reference nested steps

Phase 7: Entry point

Rewrite lib/rbrun_core.rb with new require_relative paths in dependency order.

Phase 8: Tests

1.  Move test files to mirror new source structure
2.  Update all module constant references in tests
3.  Update test_helper.rb (any Ssh::Client refs → Clients::Ssh)
4.  Update rbrun_core_test.rb — remove RbrunCore::Steps check, add RbrunCore::Clients

Phase 9: Cleanup

1.  Delete empty old directories: steps/, providers/, cloudflare/, ssh/, github/, kubernetes/, configuration/
2.  Update examples/deploy.rb (module refs should still work — Configuration, Context, Commands::Deploy unchanged)

Phase 10: Verify

Run bundle exec rake test — all tests must pass.

---

Key risks

1.  Cross-layer config→client references: Config classes instantiate their clients via relative module resolution (Client.new). After split, these need explicit paths (Clients::Compute::Hetzner.new). Must update every config class's  
    #client method.
2.  Registry string constants: Config::Compute::Registry::PROVIDERS uses string class names ("RbrunCore::Providers::Hetzner::Config"). Must update to new paths ("RbrunCore::Config::Compute::Hetzner").
3.  Steps nesting under command class: Commands::Deploy is both a class (the orchestrator) and a namespace (for its steps). Ruby allows nested classes inside a class — step files reopen the class to add nested classes. This is  
    idiomatic but each step file must wrap its class definition inside class Deploy.
4.  Shared steps referenced with Shared:: prefix: Inside a command like Deploy#run, shared steps are called as Shared::CreateInfrastructure.new(...) while own steps are just SetupK3s.new(...). This distinction is intentional and  
    readable.
