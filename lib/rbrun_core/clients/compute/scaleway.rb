# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      class Scaleway < Base
        include Interface

        BASE_URL = "https://api.scaleway.com"

        def initialize(api_key:, project_id:, zone: "fr-par-1")
          @api_key = api_key
          @project_id = project_id
          @zone = zone
          raise RbrunCore::Error, "Scaleway API key not configured" if @api_key.nil? || @api_key.empty?
          raise RbrunCore::Error, "Scaleway project ID not configured" if @project_id.nil? || @project_id.empty?

          super(timeout: 300)
        end

        # Servers
        def find_or_create_server(name:, instance_type:, image:, location: nil, user_data: nil, labels: {},
                                  firewall_ids: [], network_ids: [])
          existing = find_server(name)
          return existing if existing

          create_server(name:, instance_type:, image:, location:, user_data:, labels:,
                        firewall_ids:, network_ids:)
        end

        def create_server(name:, instance_type:, image:, location: nil, user_data: nil, labels: {},
                          firewall_ids: [], network_ids: [])
          tags = labels_to_tags(labels)
          payload = { name:, commercial_type: instance_type, image:, project: @project_id, tags: }
          payload[:security_group] = firewall_ids.first if firewall_ids&.any?

          if user_data && !user_data.empty?
            payload[:cloud_init] = user_data
          end

          response = post(instance_path("/servers"), payload)
          server = to_server(response["server"])
          power_on(server.id)
          server
        end

        def get_server(id)
          response = get(instance_path("/servers/#{id}"))
          to_server(response["server"])
        rescue HttpErrors::ApiError => e
          raise unless e.not_found?

          nil
        end

        def find_server(name)
          response = get(instance_path("/servers"), name:, project: @project_id)
          server = response["servers"]&.find { |s| s["name"] == name }
          server ? to_server(server) : nil
        end

        def list_servers(tags: nil)
          params = { project: @project_id }
          params[:tags] = tags.join(",") if tags&.any?
          response = get(instance_path("/servers"), params)
          response["servers"].map { |s| to_server(s) }
        end

        def wait_for_server(id, max_attempts: 60, interval: 5)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not become running after #{max_attempts} attempts") do
            server = get_server(id)
            server if server&.status == "running"
          end
        end

        def wait_for_server_deletion(id, max_attempts: 30, interval: 2)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} was not deleted after #{max_attempts} attempts") do
            get_server(id).nil?
          end
        end

        def delete_server(id)
          server = get_server(id)
          return nil unless server

          if server.status == "running"
            power_off(id)
            wait_for_server_stopped(id)
          end

          full_server = get(instance_path("/servers/#{id}"))["server"]
          full_server["volumes"]&.each_value do |vol|
            delete_volume_internal(vol["id"]) if vol["id"]
          rescue StandardError
          end

          delete(instance_path("/servers/#{id}"))
        end

        def power_on(id) = post(instance_path("/servers/#{id}/action"), { action: "poweron" })
        def power_off(id) = post(instance_path("/servers/#{id}/action"), { action: "poweroff" })
        def reboot(id) = post(instance_path("/servers/#{id}/action"), { action: "reboot" })

        # SSH Keys
        def find_or_create_ssh_key(name:, public_key:)
          existing = find_ssh_key(name)
          return existing if existing

          response = post(iam_path("/ssh-keys"), { name:, public_key:, project_id: @project_id })
          to_ssh_key(response["ssh_key"])
        end

        def find_ssh_key(name)
          response = get(iam_path("/ssh-keys"), project_id: @project_id)
          key = response["ssh_keys"]&.find { |k| k["name"] == name }
          key ? to_ssh_key(key) : nil
        end

        def list_ssh_keys
          response = get(iam_path("/ssh-keys"), project_id: @project_id)
          response["ssh_keys"].map { |k| to_ssh_key(k) }
        end

        def delete_ssh_key(id) = delete(iam_path("/ssh-keys/#{id}"))

        # Firewalls (Security Groups)
        def find_or_create_firewall(name, rules: nil)
          existing = find_firewall(name)
          return existing if existing

          inbound_policy = rules&.any? ? "drop" : "accept"
          response = post(instance_path("/security_groups"), {
                            name:, project: @project_id,
                            inbound_default_policy: inbound_policy, outbound_default_policy: "accept"
                          })
          sg = to_firewall(response["security_group"])

          rules&.each do |rule|
            add_security_group_rule(sg.id, rule)
          end

          sg
        end

        def find_firewall(name)
          response = get(instance_path("/security_groups"), name:, project: @project_id)
          sg = response["security_groups"]&.find { |g| g["name"] == name }
          sg ? to_firewall(sg) : nil
        end

        def list_firewalls
          response = get(instance_path("/security_groups"), project: @project_id)
          (response["security_groups"] || []).map { |g| to_firewall(g) }
        end

        def delete_firewall(id)
          delete(instance_path("/security_groups/#{id}"))
        rescue HttpErrors::ApiError => e
          raise unless e.not_found?

          nil
        end

        # Networks (VPC Private Networks)
        def find_or_create_network(name, location:)
          existing = find_network(name)
          return existing if existing

          response = post(vpc_path("/private-networks"), {
                            name:, project_id: @project_id,
                            subnets: [ { subnet: "10.0.0.0/24" } ]
                          })
          to_network(response["private_network"])
        end

        def find_network(name)
          response = get(vpc_path("/private-networks"), name:, project_id: @project_id)
          network = response["private_networks"]&.find { |n| n["name"] == name }
          network ? to_network(network) : nil
        end

        def list_networks
          response = get(vpc_path("/private-networks"), project_id: @project_id)
          (response["private_networks"] || []).map { |n| to_network(n) }
        end

        def delete_network(id)
          delete(vpc_path("/private-networks/#{id}"))
        rescue HttpErrors::ApiError => e
          raise unless e.not_found?

          nil
        end

        def inventory
          {
            servers: list_servers,
            firewalls: list_firewalls,
            networks: list_networks
          }
        end

        # Validation
        def validate_credentials
          get(instance_path("/servers"), project: @project_id)
          true
        rescue HttpErrors::ApiError => e
          raise RbrunCore::Error, "Scaleway credentials invalid: #{e.message}" if e.unauthorized?

          raise
        end

        private

          def instance_path(path) = "/instance/v1/zones/#{@zone}#{path}"
          def iam_path(path) = "/iam/v1alpha1#{path}"

          def vpc_path(path)
            region = zone_to_region(@zone)
            "/vpc/v2/regions/#{region}#{path}"
          end

          def zone_to_region(zone) = zone.sub(/-\d+$/, "")

          def auth_headers
            { "X-Auth-Token" => @api_key }
          end

          def wait_for_server_stopped(id, max_attempts: 30, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not stop after #{max_attempts} attempts") do
              server = get_server(id)
              server if server.nil? || server.status == "stopped"
            end
          end

          def labels_to_tags(labels)
            return [] if labels.nil? || labels.empty?

            labels.map { |k, v| "#{k}=#{v}" }
          end

          def add_security_group_rule(sg_id, rule)
            direction = rule[:direction] == "in" ? "inbound" : "outbound"
            protocol = rule[:protocol]&.upcase || "TCP"
            port = rule[:port]

            post(instance_path("/security_groups/#{sg_id}/rules"), {
                   direction:, protocol:, dest_port_from: port.to_i, dest_port_to: port.to_i,
                   action: "accept", ip_range: "0.0.0.0/0"
                 })
          end

          def delete_volume_internal(id)
            delete(instance_path("/volumes/#{id}"))
          rescue HttpErrors::ApiError => e
            raise unless e.not_found?

            nil
          end

          def to_server(data)
            Types::Server.new(
              id: data["id"], name: data["name"], status: data["state"],
              public_ipv4: data.dig("public_ip", "address"),
              private_ipv4: data["private_ip"],
              instance_type: data["commercial_type"],
              image: data.dig("image", "name"),
              location: data["zone"], labels: tags_to_labels(data["tags"]),
              created_at: data["creation_date"]
            )
          end

          def to_ssh_key(data)
            Types::SshKey.new(
              id: data["id"], name: data["name"],
              fingerprint: data["fingerprint"], public_key: data["public_key"],
              created_at: data["created_at"]
            )
          end

          def to_firewall(data)
            Types::Firewall.new(
              id: data["id"], name: data["name"],
              rules: data["rules"] || [], created_at: data["creation_date"]
            )
          end

          def to_network(data)
            subnets = data["subnets"]&.map { |s| s["subnet"] } || []
            Types::Network.new(
              id: data["id"], name: data["name"],
              ip_range: subnets.first,
              subnets:,
              location: data["region"],
              created_at: data["created_at"]
            )
          end

          def tags_to_labels(tags)
            return {} if tags.nil? || tags.empty?

            tags.to_h do |t|
              if t.include?("=")
                k, v = t.split("=", 2)
                [ k, v ]
              else
                [ t, true ]
              end
            end
          end
      end
    end
  end
end
