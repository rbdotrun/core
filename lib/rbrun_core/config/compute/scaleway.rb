# frozen_string_literal: true

module RbrunCore
  module Config
    module Compute
      class Scaleway < Base
        attr_accessor :api_key, :project_id, :zone, :image, :ssh_key_path, :root_volume_size
        attr_reader :servers

        DEFAULT_ROOT_VOLUME_SIZE = 20 # GB

        def initialize
          super
          @zone = "fr-par-1"
          @image = "ubuntu_jammy"
          @servers = {}
          @ssh_key_path = nil
          @root_volume_size = DEFAULT_ROOT_VOLUME_SIZE
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
          ssh_key_path_present? && private_key_exists?
        end

        def read_ssh_keys
          return nil unless ssh_keys_configured?

          validate_public_key_exists!

          {
            private_key: File.read(private_key_path),
            public_key: File.read(public_key_path).strip
          }
        end

        def ssh_private_key
          File.read(private_key_path)
        end

        def ssh_public_key
          File.read(public_key_path).strip
        end

        def provider_name
          :scaleway
        end

        def supports_self_hosted?
          true
        end

        def validate!
          validate_api_key!
          validate_project_id!
          validate_ssh_key_path!
          validate_private_key_exists!
          validate_public_key_exists!
        end

        def client
          @client ||= Clients::Compute::Scaleway.new(
            api_key: @api_key,
            project_id: @project_id,
            zone: @zone,
            root_volume_size: @root_volume_size
          )
        end

        private

          def validate_api_key!
            return if api_key && !api_key.empty?

            raise Error::Configuration, "compute.api_key is required for Scaleway"
          end

          def validate_project_id!
            return if project_id && !project_id.empty?

            raise Error::Configuration, "compute.project_id is required for Scaleway"
          end

          def validate_ssh_key_path!
            return if ssh_key_path_present?

            raise Error::Configuration, "compute.ssh_key_path is required"
          end

          def validate_private_key_exists!
            return if private_key_exists?

            raise Error::Configuration, "SSH private key not found: #{ssh_key_path}"
          end

          def validate_public_key_exists!
            return if public_key_exists?

            raise Error::Configuration, "SSH public key not found: #{ssh_key_path}.pub"
          end

          def ssh_key_path_present?
            ssh_key_path && !ssh_key_path.empty?
          end

          def private_key_exists?
            File.exist?(private_key_path)
          end

          def public_key_exists?
            File.exist?(public_key_path)
          end

          def private_key_path
            File.expand_path(ssh_key_path)
          end

          def public_key_path
            "#{private_key_path}.pub"
          end
      end
    end
  end
end
