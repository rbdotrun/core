# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Hetzner < Base
        attr_accessor :api_key, :location, :image, :ssh_key_path
        attr_reader :servers

        def initialize
          super
          @servers = {}
          @location = "ash"
          @image = "ubuntu-22.04"
          @ssh_key_path = nil
          @root_volume_size_set = false
        end

        def root_volume_size=(_value)
          @root_volume_size_set = true
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

        def provider_name
          :hetzner
        end

        def supports_self_hosted?
          true
        end

        def validate!
          if @root_volume_size_set
            raise Error::Configuration, "root_volume_size is not supported for Hetzner"
          end
          raise Error::Configuration, "compute.api_key is required for Hetzner" if api_key.nil? || api_key.empty?
          raise Error::Configuration, "compute.ssh_key_path is required" if ssh_key_path.nil? || ssh_key_path.empty?

          unless File.exist?(File.expand_path(ssh_key_path))
            raise Error::Configuration,
                  "SSH private key not found: #{ssh_key_path}"
          end
          return if File.exist?(File.expand_path("#{ssh_key_path}.pub"))

          raise Error::Configuration,
                "SSH public key not found: #{ssh_key_path}.pub"
        end

        def ssh_private_key
          File.read(File.expand_path(ssh_key_path))
        end

        def ssh_public_key
          File.read(File.expand_path("#{ssh_key_path}.pub")).strip
        end

        def client
          @client ||= Clients::Compute::Hetzner.new(api_key: @api_key)
        end
      end
    end
  end
end
