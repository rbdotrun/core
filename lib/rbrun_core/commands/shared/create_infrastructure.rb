# frozen_string_literal: true

module RbrunCore
  module Commands
    module Shared
      class CreateInfrastructure

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          @on_step&.call("Firewall", :in_progress)
          firewall = create_firewall!
          @on_step&.call("Firewall", :done)

          @on_step&.call("Network", :in_progress)
          network = compute_client.find_or_create_network(
            @ctx.prefix,
            location:
          )
          @on_step&.call("Network", :done)

          create_all_servers!(firewall_id: firewall.id, network_id: network.id)
        end

        private

          def create_all_servers!(firewall_id:, network_id:)
            desired = build_desired_servers
            existing = discover_existing_servers
            master_key = desired.keys.first

            validate_master_unchanged!(existing, master_key)

            to_create = desired.keys - existing.keys
            to_remove = existing.keys - desired.keys

            if to_remove.include?(master_key)
              raise Error::Standard,
                    "Cannot remove master node #{@ctx.prefix}-#{master_key} — scale down other groups first"
            end

            # Store servers to remove - will be removed after deploy_manifests
            @ctx.servers_to_remove = to_remove.sort.reverse.map { |key| "#{@ctx.prefix}-#{key}" }

            # Build servers hash from kept existing servers
            servers = {}
            (desired.keys & existing.keys).each do |key|
              servers[key] = existing[key]
            end

            # Scale up — create missing servers
            to_create.each do |key|
              group = desired[key]
              server_name = "#{@ctx.prefix}-#{key}"

              @on_step&.call("Server", :in_progress, server_name)

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

              @on_step&.call("Server", :done, server_name)
            end

            @ctx.servers = servers
            first = servers[desired.keys.first]
            @ctx.server_id = first[:id]
            @ctx.server_ip = first[:ip]

            # Wait for SSH only on new servers
            unless @ctx.new_servers.empty?
              @on_step&.call("SSH", :in_progress)
              @ctx.new_servers.each do |key|
                srv = servers[key]
                ssh = Clients::Ssh.new(host: srv[:ip], private_key: @ctx.ssh_private_key, user: Naming.default_user)
                ssh.wait_until_ready(max_attempts: 36, interval: 5)
              end
              @on_step&.call("SSH", :done)
            end
          end

          def build_desired_servers
            compute = @ctx.config.compute_config
            desired = {}

            # Master servers (always present)
            master = compute.master
            (1..master.count).each do |i|
              desired["#{Naming::MASTER_GROUP}-#{i}"] = master
            end

            # Additional server groups (optional)
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
                private_ip: nil, group: key.split("-").first,
                instance_type: server.instance_type
              }
            end
            existing
          end

          def validate_master_unchanged!(existing, master_key)
            existing_master = existing[master_key]
            return unless existing_master

            configured_type = @ctx.config.compute_config.master.instance_type
            return if existing_master[:instance_type] == configured_type

            raise Error::Standard,
                  "Master instance_type mismatch: existing=#{existing_master[:instance_type]}, " \
                  "config=#{configured_type}. Cannot change master type without destroying infrastructure."
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
              instance_type: server_type,
              location:,
              image: @ctx.config.compute_config.image,
              user_data:,
              labels: { purpose: @ctx.target.to_s },
              firewall_ids: [ firewall_id ],
              network_ids: [ network_id ]
            )
          end

          def compute_client
            @ctx.compute_client
          end

          def location
            @ctx.config.compute_config.location
          end
      end
    end
  end
end
