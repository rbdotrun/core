# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      # Canonical interface for all compute providers.
      # Each provider must implement these methods, returning normalized Types::* structs.
      module Interface
        def self.included(base)
          base.class_eval do
            def self.required_methods
              %i[
                find_or_create_server find_server delete_server wait_for_server wait_for_server_deletion
                find_or_create_firewall find_firewall delete_firewall
                find_or_create_network find_network delete_network
                find_or_create_ssh_key find_ssh_key delete_ssh_key
                validate_credentials
              ]
            end
          end
        end

        # Server methods
        def find_or_create_server(name:, instance_type:, location:, image:, user_data: nil, labels: {}, firewall_ids: [], network_ids: [])
          raise NotImplementedError, "#{self.class}#find_or_create_server not implemented"
        end

        def find_server(name)
          raise NotImplementedError, "#{self.class}#find_server not implemented"
        end

        def delete_server(id)
          raise NotImplementedError, "#{self.class}#delete_server not implemented"
        end

        def delete_server_by_name(name)
          server = find_server(name)
          return nil unless server

          delete_server(server.id)
        end

        def wait_for_server(id)
          raise NotImplementedError, "#{self.class}#wait_for_server not implemented"
        end

        def wait_for_server_deletion(id)
          raise NotImplementedError, "#{self.class}#wait_for_server_deletion not implemented"
        end

        # Firewall methods
        def find_or_create_firewall(name, rules:)
          raise NotImplementedError, "#{self.class}#find_or_create_firewall not implemented"
        end

        def find_firewall(name)
          raise NotImplementedError, "#{self.class}#find_firewall not implemented"
        end

        def delete_firewall(id)
          raise NotImplementedError, "#{self.class}#delete_firewall not implemented"
        end

        # Network methods
        def find_or_create_network(name, location:)
          raise NotImplementedError, "#{self.class}#find_or_create_network not implemented"
        end

        def find_network(name)
          raise NotImplementedError, "#{self.class}#find_network not implemented"
        end

        def delete_network(id)
          raise NotImplementedError, "#{self.class}#delete_network not implemented"
        end

        # SSH Key methods
        def find_or_create_ssh_key(name:, public_key:)
          raise NotImplementedError, "#{self.class}#find_or_create_ssh_key not implemented"
        end

        def find_ssh_key(name)
          raise NotImplementedError, "#{self.class}#find_ssh_key not implemented"
        end

        def delete_ssh_key(id)
          raise NotImplementedError, "#{self.class}#delete_ssh_key not implemented"
        end

        # Validation
        def validate_credentials
          raise NotImplementedError, "#{self.class}#validate_credentials not implemented"
        end
      end
    end
  end
end
