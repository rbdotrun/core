# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Aws < Base
        attr_accessor :access_key_id, :secret_access_key, :region, :server, :image, :ssh_key_path
        attr_reader :servers

        def initialize
          super
          @region = "us-east-1"
          @image = "ubuntu-22.04"
          @server = "t3.micro"
          @servers = {}
          @ssh_key_path = nil
        end

        def provider_name
          :aws
        end

        def location
          @region
        end

        def location=(val)
          @region = val
        end

        def add_server_group(name, type:, count: 1)
          @servers[name.to_sym] = ServerGroup.new(name:, type:, count:)
        end

        def multi_server?
          @servers.any?
        end

        def supports_self_hosted?
          true
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

        def validate!
          raise Error::Configuration, "compute.access_key_id required" if access_key_id.nil? || access_key_id.empty?

          if secret_access_key.nil? || secret_access_key.empty?
            raise Error::Configuration, "compute.secret_access_key required"
          end

          raise Error::Configuration, "compute.ssh_key_path is required" if ssh_key_path.nil? || ssh_key_path.empty?

          unless File.exist?(File.expand_path(ssh_key_path))
            raise Error::Configuration, "SSH private key not found: #{ssh_key_path}"
          end

          return if File.exist?(File.expand_path("#{ssh_key_path}.pub"))

          raise Error::Configuration, "SSH public key not found: #{ssh_key_path}.pub"
        end

        def client
          @client ||= Clients::Compute::Aws.new(
            access_key_id:,
            secret_access_key:,
            region:
          )
        end
      end
    end
  end
end
