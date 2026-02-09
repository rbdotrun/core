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
                find_or_create_server find_server list_servers delete_server wait_for_server wait_for_server_deletion
                find_or_create_firewall find_firewall delete_firewall
                find_or_create_network find_network delete_network
                find_or_create_load_balancer find_load_balancer list_load_balancers delete_load_balancer
                attach_load_balancer_to_network add_load_balancer_target add_load_balancer_service
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

        def list_servers(**filters)
          raise NotImplementedError, "#{self.class}#list_servers not implemented"
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

        # Load balancer methods
        def find_or_create_load_balancer(name:, type:, location:, network_id: nil, firewall_ids: [], labels: {})
          raise NotImplementedError, "#{self.class}#find_or_create_load_balancer not implemented"
        end

        def find_load_balancer(name)
          raise NotImplementedError, "#{self.class}#find_load_balancer not implemented"
        end

        def list_load_balancers(**filters)
          raise NotImplementedError, "#{self.class}#list_load_balancers not implemented"
        end

        def delete_load_balancer(id)
          raise NotImplementedError, "#{self.class}#delete_load_balancer not implemented"
        end

        def attach_load_balancer_to_network(load_balancer_id:, network_id:)
          raise NotImplementedError, "#{self.class}#attach_load_balancer_to_network not implemented"
        end

        def add_load_balancer_target(load_balancer_id:, server_id:, use_private_ip: true)
          raise NotImplementedError, "#{self.class}#add_load_balancer_target not implemented"
        end

        def add_load_balancer_service(load_balancer_id:, protocol: "tcp", listen_port: 443,
                                      destination_port: 443, health_check: {})
          raise NotImplementedError, "#{self.class}#add_load_balancer_service not implemented"
        end

        # Validation
        def validate_credentials
          raise NotImplementedError, "#{self.class}#validate_credentials not implemented"
        end

        # Server type info
        def server_type_memory_mb(instance_type)
          raise NotImplementedError, "#{self.class}#server_type_memory_mb not implemented"
        end
      end
    end
  end
end
