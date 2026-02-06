# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Scaleway < Base
        attr_accessor :api_key, :project_id, :zone, :image, :ssh_key_path
        attr_reader :servers

        def initialize
          super
          @zone = "fr-par-1"
          @image = "ubuntu_jammy"
          @servers = {}
          @ssh_key_path = nil
        end

        def location
          @zone
        end

        def location=(val)
          @zone = val
        end

        def add_server_group(name, type:, count: 1)
          @servers[name.to_sym] = ServerGroup.new(name:, type:, count:)
        end

        def multi_server?
          @servers.any?
        end

        def ssh_keys_configured?
          @ssh_key_path && !@ssh_key_path.empty? && File.exist?(File.expand_path(@ssh_key_path))
        end

        def read_ssh_keys
          return nil unless ssh_keys_configured?

          private_key_path = File.expand_path(@ssh_key_path)
          public_key_path = "#{private_key_path}.pub"

          raise Error::Configuration, "SSH public key not found: #{public_key_path}" unless File.exist?(public_key_path)

          {
            private_key: File.read(private_key_path),
            public_key: File.read(public_key_path).strip
          }
        end

        def ssh_private_key
          File.read(File.expand_path(ssh_key_path))
        end

        def ssh_public_key
          File.read(File.expand_path("#{ssh_key_path}.pub")).strip
        end

        def provider_name
          :scaleway
        end

        def supports_self_hosted?
          true
        end

        def validate!
          raise Error::Configuration, "compute.api_key is required for Scaleway" if api_key.nil? || api_key.empty?

          if project_id.nil? || project_id.empty?
            raise Error::Configuration, "compute.project_id is required for Scaleway"
          end

          raise Error::Configuration, "compute.ssh_key_path is required" if ssh_key_path.nil? || ssh_key_path.empty?

          unless File.exist?(File.expand_path(ssh_key_path))
            raise Error::Configuration, "SSH private key not found: #{ssh_key_path}"
          end

          return if File.exist?(File.expand_path("#{ssh_key_path}.pub"))

          raise Error::Configuration, "SSH public key not found: #{ssh_key_path}.pub"
        end

        def client
          @client ||= Clients::Compute::Scaleway.new(api_key: @api_key, project_id: @project_id, zone: @zone)
        end
      end
    end
  end
end
