# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class CreateInfrastructure
        def initialize(ctx, on_log: nil)
          @ctx = ctx
          @on_log = on_log
        end

        def run
          log("firewall", "Finding or creating firewall")
          firewall = create_firewall!

          log("network", "Finding or creating network")
          network = compute_client.find_or_create_network(
            @ctx.prefix,
            location:
          )

          if multi_server?
            create_multi_server!(firewall_id: firewall.id, network_id: network.id)
          else
            create_single_server!(firewall_id: firewall.id, network_id: network.id)
          end
        end

        private

          def multi_server?
            @ctx.config.compute_config.respond_to?(:multi_server?) && @ctx.config.compute_config.multi_server?
          end

          def create_single_server!(firewall_id:, network_id:)
            log("server", "Finding or creating server")
            server = create_server!(
              name: @ctx.prefix,
              server_type: @ctx.config.compute_config.server,
              firewall_id:, network_id:
            )

            @ctx.server_id = server.id
            @ctx.server_ip = server.public_ipv4

            log("ssh_wait", "Waiting for SSH")
            wait_for_ssh!
          end

          def create_multi_server!(firewall_id:, network_id:)
            desired = build_desired_servers
            existing = discover_existing_servers
            master_key = desired.keys.first

            to_create = desired.keys - existing.keys
            to_remove = existing.keys - desired.keys

            if to_remove.include?(master_key)
              raise RbrunCore::Error,
                    "Cannot remove master node #{@ctx.prefix}-#{master_key} — scale down other groups first"
            end

            # Scale down (highest index first)
            unless to_remove.empty?
              # Need kubectl via master SSH for drain/delete
              master_existing = existing[master_key]
              @ctx.server_ip = master_existing[:ip]

              to_remove.sort.reverse.each do |key|
                node_name = "#{@ctx.prefix}-#{key}"
                log("scale_down", "Removing #{node_name}")

                begin
                  kubectl = Clients::Kubectl.new(@ctx.ssh_client)
                  kubectl.drain(node_name, max_attempts: 1, interval: 0)
                rescue RbrunCore::Error => e
                  log("drain_warning", "Drain failed for #{node_name}: #{e.message}, continuing")
                end

                begin
                  kubectl = Clients::Kubectl.new(@ctx.ssh_client)
                  kubectl.delete_node(node_name, max_attempts: 1, interval: 0)
                rescue RbrunCore::Error
                  # best effort
                end

                compute_client.delete_server(existing[key][:id])
              end
            end

            # Build servers hash from kept existing servers
            servers = {}
            (desired.keys & existing.keys).each do |key|
              servers[key] = existing[key]
            end

            # Scale up — create missing servers
            to_create.each do |key|
              group = desired[key]
              server_name = "#{@ctx.prefix}-#{key}"
              log("server", "Creating server #{server_name}")

              server = create_server!(
                name: server_name,
                server_type: group.type,
                firewall_id:, network_id:
              )

              servers[key] = {
                id: server.id, ip: server.public_ipv4,
                private_ip: nil, group: key.split("-").first
              }
              @ctx.new_servers.add(key)
            end

            @ctx.servers = servers
            first = servers[desired.keys.first]
            @ctx.server_id = first[:id]
            @ctx.server_ip = first[:ip]

            # Wait for SSH only on new servers
            unless @ctx.new_servers.empty?
              log("ssh_wait", "Waiting for SSH on new servers")
              @ctx.new_servers.each do |key|
                srv = servers[key]
                ssh = Clients::Ssh.new(host: srv[:ip], private_key: @ctx.ssh_private_key, user: Naming.default_user)
                ssh.wait_until_ready(max_attempts: 36, interval: 5)
              end
            end
          end

          def build_desired_servers
            compute = @ctx.config.compute_config
            desired = {}
            compute.servers.each do |group_name, group|
              (1..group.count).each do |i|
                desired["#{group_name}-#{i}"] = group
              end
            end
            desired
          end

          def discover_existing_servers
            all_servers = compute_client.list_servers
            prefix = @ctx.prefix
            pattern = /\A#{Regexp.escape(prefix)}-(\w+-\d+)\z/

            existing = {}
            all_servers.each do |server|
              match = server.name.match(pattern)
              next unless match

              key = match[1]
              existing[key] = {
                id: server.id, ip: server.public_ipv4,
                private_ip: nil, group: key.split("-").first
              }
            end
            existing
          end

          def create_firewall!
            rules = [ { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] } ]
            if @ctx.target != :sandbox
              rules << { direction: "in", protocol: "tcp", port: "6443", source_ips: [ "10.0.0.0/16" ] }
            end
            compute_client.find_or_create_firewall(@ctx.prefix, rules:)
          end

          def create_server!(name:, server_type:, firewall_id:, network_id:)
            user_data = Generators::CloudInit.generate(ssh_public_key: @ctx.ssh_public_key)

            compute_client.find_or_create_server(
              name:,
              server_type:,
              location:,
              image: @ctx.config.compute_config.image,
              user_data:,
              labels: { purpose: @ctx.target.to_s },
              firewalls: [ firewall_id ],
              networks: [ network_id ]
            )
          end

          def wait_for_ssh!(timeout: 180)
            @ctx.ssh_client.wait_until_ready(max_attempts: timeout / 5, interval: 5)
          end

          def compute_client
            @ctx.compute_client
          end

          def location
            @ctx.config.compute_config.location
          end

          def log(category, message = nil)
            @on_log&.call(category, message)
          end
      end
    end
  end
end
