# frozen_string_literal: true

require "json"
require "securerandom"
require "yaml"
require "base64"
require "shellwords"
require "faraday"
require "faraday/net_http"
require "logger"

# Foundation
require_relative "rbrun_core/version"
require_relative "rbrun_core/errors"
require_relative "rbrun_core/waiter"
require_relative "rbrun_core/naming"
require_relative "rbrun_core/local_git"
require_relative "rbrun_core/logger"

# Config
require_relative "rbrun_core/config/git"
require_relative "rbrun_core/config/claude"
require_relative "rbrun_core/config/compute/base"
require_relative "rbrun_core/config/compute/server_group"
require_relative "rbrun_core/config/compute/hetzner"
require_relative "rbrun_core/config/compute/scaleway"
require_relative "rbrun_core/config/compute/aws"
require_relative "rbrun_core/config/compute/registry"
require_relative "rbrun_core/config/cloudflare"
require_relative "rbrun_core/config/configuration"
require_relative "rbrun_core/config/loader"

# Clients
require_relative "rbrun_core/clients/base"
require_relative "rbrun_core/clients/ssh"
require_relative "rbrun_core/clients/kubectl"
require_relative "rbrun_core/clients/github"
require_relative "rbrun_core/clients/cloudflare"
require_relative "rbrun_core/clients/cloudflare_r2"
require_relative "rbrun_core/clients/cloudflare_worker"
require_relative "rbrun_core/clients/compute/types"
require_relative "rbrun_core/clients/compute/interface"
require_relative "rbrun_core/clients/compute/hetzner"
require_relative "rbrun_core/clients/compute/scaleway"
require_relative "rbrun_core/clients/compute/aws"

# Generators
require_relative "rbrun_core/generators/cloud_init"
require_relative "rbrun_core/generators/k3s"
require_relative "rbrun_core/generators/compose"

# Context
require_relative "rbrun_core/context"

# Topology
require_relative "rbrun_core/topology"

# Commands — shared steps
require_relative "rbrun_core/commands/shared/create_infrastructure"
require_relative "rbrun_core/commands/shared/delete_infrastructure"
require_relative "rbrun_core/commands/shared/cleanup_tunnel"

# Commands — deploy
require_relative "rbrun_core/commands/deploy/setup_k3s"
require_relative "rbrun_core/commands/deploy/setup_tunnel"
require_relative "rbrun_core/commands/deploy/build_image"
require_relative "rbrun_core/commands/deploy/cleanup_images"
require_relative "rbrun_core/commands/deploy/deploy_manifests"
require_relative "rbrun_core/commands/deploy/command"

# Commands — deploy_sandbox
require_relative "rbrun_core/commands/deploy_sandbox/setup_application"
require_relative "rbrun_core/commands/deploy_sandbox/command"

# Commands — destroy
require_relative "rbrun_core/commands/destroy/command"

# Commands — destroy_sandbox
require_relative "rbrun_core/commands/destroy_sandbox/stop_containers"
require_relative "rbrun_core/commands/destroy_sandbox/command"

module RbrunCore
end
