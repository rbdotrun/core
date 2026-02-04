# frozen_string_literal: true

require "json"
require "securerandom"
require "yaml"
require "base64"
require "shellwords"
require "faraday"
require "faraday/net_http"
require "logger"

# Core
require_relative "rbrun_core/version"
require_relative "rbrun_core/http_errors"
require_relative "rbrun_core/base_client"
require_relative "rbrun_core/naming"

# Configuration
require_relative "rbrun_core/configuration/git_config"
require_relative "rbrun_core/configuration/claude_config"
require_relative "rbrun_core/configuration"

# Providers
require_relative "rbrun_core/providers/types"
require_relative "rbrun_core/providers/base"
require_relative "rbrun_core/providers/cloud_init"
require_relative "rbrun_core/providers/hetzner/config"
require_relative "rbrun_core/providers/hetzner/client"
require_relative "rbrun_core/providers/scaleway/config"
require_relative "rbrun_core/providers/scaleway/client"
require_relative "rbrun_core/providers/registry"

# Cloudflare
require_relative "rbrun_core/cloudflare/config"
require_relative "rbrun_core/cloudflare/client"
require_relative "rbrun_core/cloudflare/worker"
require_relative "rbrun_core/cloudflare/r2"

# GitHub
require_relative "rbrun_core/github/client"

# SSH
require_relative "rbrun_core/ssh/client"

# Kubernetes
require_relative "rbrun_core/kubernetes/resources"
require_relative "rbrun_core/kubernetes/kubectl"

# Generators
require_relative "rbrun_core/generators/k3s"
require_relative "rbrun_core/generators/compose"

# Context
require_relative "rbrun_core/context"

# Steps
require_relative "rbrun_core/steps/create_infrastructure"
require_relative "rbrun_core/steps/setup_k3s"
require_relative "rbrun_core/steps/build_image"
require_relative "rbrun_core/steps/deploy_manifests"
require_relative "rbrun_core/steps/provision_volume"
require_relative "rbrun_core/steps/setup_tunnel"
require_relative "rbrun_core/steps/setup_application"
require_relative "rbrun_core/steps/cleanup_images"

# Commands
require_relative "rbrun_core/commands/deploy"
require_relative "rbrun_core/commands/deploy_sandbox"
require_relative "rbrun_core/commands/destroy"
require_relative "rbrun_core/commands/destroy_sandbox"

module RbrunCore
end
