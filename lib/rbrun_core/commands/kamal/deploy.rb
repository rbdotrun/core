# frozen_string_literal: true

module RbrunCore
  module Commands
    module Kamal
      class Deploy
        def initialize(ctx, on_step: nil, on_state_change: nil)
          @ctx = ctx
          @on_step = on_step
          @on_state_change = on_state_change
          @servers = {}
          @network = nil
          @firewall = nil
          @load_balancer = nil
        end

        def run
          change_state(:provisioning)

          provision_infrastructure!
          configure_dns!

          change_state(:deploying)

          generate_config!
          run_kamal_deploy!

          change_state(:deployed)
        rescue StandardError
          change_state(:failed)
          raise
        end

        private

          def prefix
            "#{@ctx.config.name}-kamal"
          end

          # --- Infrastructure provisioning (Hetzner API only, no SSH) ---

          def provision_infrastructure!
            create_network!
            create_firewall!
            create_servers!
            create_load_balancer! if needs_load_balancer?
          end

          def create_network!
            @on_step&.call("Network", :in_progress)
            @network = compute_client.find_or_create_network(prefix, location:)
            @on_step&.call("Network", :done)
          end

          def create_firewall!
            @on_step&.call("Firewall", :in_progress)
            @firewall = compute_client.find_or_create_firewall(prefix, rules: firewall_rules)
            @on_step&.call("Firewall", :done)
          end

          def create_servers!
            server_count.times do |i|
              name = "#{prefix}-web-#{i + 1}"
              @on_step&.call("Server", :in_progress, name)

              server = compute_client.find_or_create_server(
                name:,
                instance_type: server_type,
                location:,
                image: "ubuntu-24.04",
                user_data: cloud_init,
                labels: { purpose: "kamal", role: "web" },
                firewall_ids: [ @firewall.id ],
                network_ids: [ @network.id ]
              )

              @servers[name] = {
                id: server.id,
                ip: server.public_ipv4,
                private_ip: server.private_ipv4,
                role: :web
              }

              @on_step&.call("Server", :done, name)
            end
          end

          def create_load_balancer!
            @on_step&.call("Load balancer", :in_progress)

            lb = compute_client.find_or_create_load_balancer(
              name: "#{prefix}-lb",
              type: "lb11",
              location:,
              network_id: @network&.id
            )
            @load_balancer = lb

            attach_lb_to_network!(lb)
            sync_lb_targets!(lb)
            ensure_lb_service!(lb)

            @on_step&.call("Load balancer", :done)
          end

          def attach_lb_to_network!(lb)
            compute_client.attach_load_balancer_to_network(
              load_balancer_id: lb.id,
              network_id: @network.id
            )
          rescue Error::Api => e
            raise unless e.message.include?("already_added") || e.message.include?("uniqueness")
          end

          def sync_lb_targets!(lb)
            @servers.each_value do |server|
              next unless server[:role] == :web

              compute_client.add_load_balancer_target(
                load_balancer_id: lb.id,
                server_id: server[:id],
                use_private_ip: true
              )
            rescue Error::Api => e
              raise unless e.message.include?("target_already_defined")
            end
          end

          def ensure_lb_service!(lb)
            compute_client.add_load_balancer_service(
              load_balancer_id: lb.id,
              protocol: "tcp",
              listen_port: 443,
              destination_port: 443,
              health_check: { protocol: "tcp", port: 443, interval: 15, timeout: 10, retries: 3 }
            )
          rescue Error::Api => e
            raise unless e.message.include?("already") || e.message.include?("uniqueness")
          end

          # --- DNS configuration (Cloudflare API only, no SSH) ---

          def configure_dns!
            return unless @ctx.cloudflare_configured?

            @on_step&.call("DNS", :in_progress)

            target_ip = public_entry_ip
            return unless target_ip

            zone_id = cloudflare_client.get_zone_id(zone_domain)
            cloudflare_client.ensure_a_record(zone_id, domain, target_ip, proxied: true)
            cloudflare_client.set_ssl_mode(zone_id, "full")

            @on_step&.call("DNS", :done)
          end

          # --- Config generation (local file I/O only) ---

          def generate_config!
            @on_step&.call("Config", :in_progress)

            builder = ConfigBuilder.new(
              config: @ctx.config,
              servers: @servers,
              domain:
            )

            output_dir = @ctx.source_folder || "."

            deploy_dir = File.join(output_dir, "config")
            FileUtils.mkdir_p(deploy_dir)
            File.write(File.join(deploy_dir, "deploy.yml"), builder.to_yaml)

            secrets_dir = File.join(output_dir, ".kamal")
            FileUtils.mkdir_p(secrets_dir)
            File.write(File.join(secrets_dir, "secrets"), builder.to_secrets)

            @on_step&.call("Config", :done)
          end

          # --- Kamal invocation (delegates SSH to Kamal) ---

          def run_kamal_deploy!
            @on_step&.call("Deploy", :in_progress)

            config_file = File.join(@ctx.source_folder || ".", "config", "deploy.yml")
            command = first_deploy? ? "setup" : "deploy"

            success = system("kamal", command, "--config-file=#{config_file}", "-y")
            raise Error::Standard, "kamal #{command} failed" unless success

            @on_step&.call("Deploy", :done)
          end

          def first_deploy?
            # First deploy if all servers were just created (no prior kamal setup)
            @servers.values.all? { |s| s[:newly_created] }
          end

          # --- Helpers ---

          def needs_load_balancer?
            server_count > 1
          end

          def public_entry_ip
            if @load_balancer
              @load_balancer.public_ipv4
            else
              # Single-server mode: A record points to server's public IP
              @servers.values.first&.dig(:ip)
            end
          end

          def server_count
            1 # Single-server default; override via CLI options in the future
          end

          def server_type
            @ctx.config.compute_config&.master&.instance_type || "cpx21"
          end

          def location
            @ctx.config.compute_config&.location || "ash"
          end

          def domain
            @ctx.config.cloudflare_config&.domain
          end

          def zone_domain
            parts = domain.to_s.split(".")
            parts.length > 2 ? parts.last(2).join(".") : domain
          end

          def cloud_init
            Generators::CloudInit.generate(ssh_public_key: @ctx.ssh_public_key)
          end

          def firewall_rules
            [
              { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] },
              { direction: "in", protocol: "tcp", port: "443", source_ips: [ "0.0.0.0/0", "::/0" ] },
              { direction: "in", protocol: "tcp", port: "80", source_ips: [ "0.0.0.0/0", "::/0" ] },
              { direction: "in", protocol: "tcp", port: "any", source_ips: [ "10.0.0.0/16" ] },
              { direction: "in", protocol: "udp", port: "any", source_ips: [ "10.0.0.0/16" ] }
            ]
          end

          def compute_client = @ctx.compute_client
          def cloudflare_client = @ctx.cloudflare_client

          def change_state(state)
            @ctx.state = state
            @on_state_change&.call(state)
          end
      end
    end
  end
end
