# frozen_string_literal: true

module RbrunCore
  module Shared
    class CreateInfrastructure
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        firewall = create_firewall_step!
        network = create_network_step!
        create_servers_step!(firewall_id: firewall.id, network_id: network.id)
      end

      private

        def create_firewall_step!
          @on_step&.call("Firewall", :in_progress)
          firewall = compute_client.find_or_create_firewall(@ctx.prefix, rules: firewall_rules)
          @on_step&.call("Firewall", :done)
          firewall
        end

        def create_network_step!
          @on_step&.call("Network", :in_progress)
          network = compute_client.find_or_create_network(@ctx.prefix, location:)
          @on_step&.call("Network", :done)
          network
        end

        def create_servers_step!(firewall_id:, network_id:)
          desired = build_desired_servers
          existing = discover_existing_servers

          validate_master_unchanged!(existing, desired.keys.first)
          plan_server_changes!(desired, existing)
          create_missing_servers!(desired, existing, firewall_id:, network_id:)
          update_context!(desired, existing)
          wait_for_new_servers!
        end

        def plan_server_changes!(desired, existing)
          master_key = desired.keys.first
          to_remove = existing.keys - desired.keys

          if to_remove.include?(master_key)
            raise Error::Standard,
                  "Cannot remove master node #{@ctx.prefix}-#{master_key} — scale down other groups first"
          end

          @ctx.servers_to_remove = to_remove.sort.reverse.map { |key| server_name(key) }
        end

        def create_missing_servers!(desired, existing, firewall_id:, network_id:)
          to_create = desired.keys - existing.keys

          to_create.each do |key|
            name = server_name(key)
            @on_step&.call("Server", :in_progress, name)

            server = create_server!(
              name:,
              server_type: desired[key].type,
              firewall_id:,
              network_id:
            )

            existing[key] = build_server_info(server, key)
            @ctx.new_servers.add(key)

            @on_step&.call("Server", :done, name)
          end
        end

        def update_context!(desired, servers)
          kept_servers = desired.keys.each_with_object({}) do |key, hash|
            hash[key] = servers[key] if servers[key]
          end

          @ctx.servers = kept_servers

          first = kept_servers[desired.keys.first]
          @ctx.server_id = first[:id]
          @ctx.server_ip = first[:ip]
        end

        def wait_for_new_servers!
          return if @ctx.new_servers.empty?

          @on_step&.call("SSH", :in_progress)

          @ctx.new_servers.each do |key|
            srv = @ctx.servers[key]
            ssh = Clients::Ssh.new(host: srv[:ip], private_key: @ctx.ssh_private_key, user: Naming.default_user)
            ssh.wait_until_ready(max_attempts: 36, interval: 5)
          end

          @on_step&.call("SSH", :done)
        end

        def build_desired_servers
          compute = @ctx.config.compute_config
          desired = {}

          add_master_servers!(desired, compute.master)
          add_worker_servers!(desired, compute.servers)

          desired
        end

        def add_master_servers!(desired, master)
          (1..master.count).each do |i|
            desired["#{Naming::MASTER_GROUP}-#{i}"] = master
          end
        end

        def add_worker_servers!(desired, servers)
          servers.each do |group_name, group|
            (1..group.count).each do |i|
              desired["#{group_name}-#{i}"] = group
            end
          end
        end

        def discover_existing_servers
          all_servers = compute_client.list_servers
          pattern = /\A#{Regexp.escape(@ctx.prefix)}-(\w+-\d+)\z/

          all_servers.each_with_object({}) do |server, existing|
            match = server.name.match(pattern)
            next unless match

            key = match[1]
            existing[key] = build_existing_server_info(server, key)
          end
        end

        def build_server_info(server, key)
          {
            id: server.id,
            ip: server.public_ipv4,
            private_ip: nil,
            group: extract_group(key)
          }
        end

        def build_existing_server_info(server, key)
          {
            id: server.id,
            ip: server.public_ipv4,
            private_ip: nil,
            group: extract_group(key),
            instance_type: server.instance_type
          }
        end

        def extract_group(key)
          key.split("-").first
        end

        def server_name(key)
          "#{@ctx.prefix}-#{key}"
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

        def firewall_rules
          rules = [ ssh_firewall_rule ]
          rules << k3s_firewall_rule unless sandbox?
          rules
        end

        def ssh_firewall_rule
          { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] }
        end

        def k3s_firewall_rule
          { direction: "in", protocol: "tcp", port: "6443", source_ips: [ "10.0.0.0/16" ] }
        end

        def sandbox?
          @ctx.target == :sandbox
        end

        def create_server!(name:, server_type:, firewall_id:, network_id:)
          user_data = CloudInit.generate(ssh_public_key: @ctx.ssh_public_key)

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
