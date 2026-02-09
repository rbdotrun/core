# frozen_string_literal: true

module RbrunCore
  module K3s
    module Installer
    # Mirrors for k3s binary downloads (installer script uses INSTALL_K3S_MIRROR env var)
    # GitHub is primary, with fallbacks for when GitHub is down
    MIRRORS = [
      nil, # Default (GitHub)
      "https://rancher-mirror.rancher.cn/k3s"
    ].freeze

    INSTALLER_URLS = [
      "https://get.k3s.io",
      "https://rancher-mirror.rancher.cn/k3s/k3s-install.sh"
    ].freeze

    class << self
      # Generate install command for k3s server (master node)
      def server_install_command(exec_args:)
        install_with_fallback(env_vars: "INSTALL_K3S_EXEC=\"#{exec_args}\"")
      end

      # Generate install command for k3s agent (worker node)
      def agent_install_command(master_url:, token:, agent_args:)
        env_vars = "K3S_URL=\"#{master_url}\" K3S_TOKEN=\"#{token}\""
        install_with_fallback(env_vars:, script_args: "agent #{agent_args}")
      end

      private

        def install_with_fallback(env_vars:, script_args: nil)
          attempts = build_install_attempts(env_vars, script_args)
          attempts.join(" || ")
        end

        def build_install_attempts(env_vars, script_args)
          attempts = []

          INSTALLER_URLS.each_with_index do |installer_url, idx|
            mirror = MIRRORS[idx]
            mirror_env = mirror ? "INSTALL_K3S_MIRROR=\"#{mirror}\" " : ""
            script_suffix = script_args ? " - #{script_args}" : ""

            attempts << "(curl -sfL #{installer_url} | sudo #{mirror_env}#{env_vars} sh -s#{script_suffix})"
          end

          attempts
        end
    end
    end
  end
end
