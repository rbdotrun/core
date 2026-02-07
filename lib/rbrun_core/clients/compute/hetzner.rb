# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      class Hetzner < Base
        include Interface

        BASE_URL = "https://api.hetzner.cloud/v1"

        NETWORK_ZONES = {
          "fsn1" => "eu-central",
          "nbg1" => "eu-central",
          "hel1" => "eu-central",
          "ash" => "us-east",
          "hil" => "us-west"
        }.freeze

        def initialize(api_key:)
          @api_key = api_key
          raise Error::Standard, "Hetzner API key not configured" if @api_key.nil? || @api_key.empty?

          super(timeout: 300)
        end

        def find_or_create_server(name:, instance_type:, image: "ubuntu-22.04", location: nil, ssh_keys: [],
                                  user_data: nil, labels: {}, firewall_ids: [], network_ids: [])
          existing = find_server(name)
          return existing if existing

          create_server(name:, instance_type:, image:, location:, ssh_keys:, user_data:, labels:,
                        firewall_ids:, network_ids:)
        end

        def create_server(name:, instance_type:, image: "ubuntu-22.04", location: nil, ssh_keys: [], user_data: nil,
                          labels: {}, firewall_ids: [], network_ids: [])
          payload = {
            name:, server_type: instance_type, image:, location:,
            start_after_create: true, labels: labels || {}
          }
          payload[:ssh_keys] = ssh_keys if ssh_keys.any?
          payload[:user_data] = user_data if user_data && !user_data.empty?
          payload[:firewalls] = firewall_ids.map { |id| { firewall: id.to_i } } if firewall_ids&.any?
          payload[:networks] = network_ids.map(&:to_i) if network_ids&.any?

          response = post("/servers", payload)
          to_server(response["server"])
        end

        def get_server(id)
          response = get("/servers/#{id.to_i}")
          to_server(response["server"])
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def find_server(name)
          response = get("/servers", name:)
          server = response["servers"]&.first
          server ? to_server(server) : nil
        end

        def list_servers(label_selector: nil)
          params = {}
          params[:label_selector] = label_selector if label_selector
          response = get("/servers", params)
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
          server_id = id.to_i

          begin
            server = get("/servers/#{server_id}")["server"]

            # Detach from firewalls and wait for actions to complete
            get("/firewalls")["firewalls"].each do |fw|
              fw["applied_to"]&.each do |applied|
                next unless applied["type"] == "server" && applied.dig("server", "id") == server_id

                response = remove_firewall_from_server(fw["id"], server_id)
                wait_for_action(response.dig("actions", 0, "id")) if response.dig("actions", 0, "id")
              rescue StandardError
              end
            end

            # Detach from networks and wait for actions to complete
            server["private_net"]&.each do |pn|
              response = detach_server_from_network(server_id, pn["network"])
              wait_for_action(response.dig("action", "id")) if response.dig("action", "id")
            rescue StandardError
            end
          rescue Error::Api => e
            return nil if e.not_found?

            raise
          end

          delete("/servers/#{server_id}")
          wait_for_server_deletion(server_id)
        end

        def power_on(id) = post("/servers/#{id.to_i}/actions/poweron")
        def power_off(id) = post("/servers/#{id.to_i}/actions/poweroff")
        def shutdown(id) = post("/servers/#{id.to_i}/actions/shutdown")
        def reboot(id) = post("/servers/#{id.to_i}/actions/reboot")

        def list_firewalls
          response = get("/firewalls")
          response["firewalls"].map { |f| to_firewall(f) }
        end

        def find_or_create_network(name, location:, ip_range: "10.0.0.0/16", subnet_range: "10.0.0.0/24")
          existing = find_network(name)
          return existing if existing

          network_zone = NETWORK_ZONES[location] || "eu-central"
          response = post("/networks", {
                            name:, ip_range:,
                            subnets: [ { type: "cloud", ip_range: subnet_range, network_zone: } ]
                          })
          to_network(response["network"])
        end

        def find_network(name)
          response = get("/networks", name:)
          network = response["networks"]&.first
          network ? to_network(network) : nil
        end

        def list_networks
          response = get("/networks")
          response["networks"].map { |n| to_network(n) }
        end

        def delete_network(id)
          delete("/networks/#{id.to_i}")
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def find_or_create_firewall(name, rules: nil)
          existing = find_firewall(name)
          return existing if existing

          rules ||= [
            { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0", "::/0" ] }
          ]
          response = post("/firewalls", { name:, rules: })
          to_firewall(response["firewall"])
        end

        def find_firewall(name)
          response = get("/firewalls", name:)
          firewall = response["firewalls"]&.first
          firewall ? to_firewall(firewall) : nil
        end

        def delete_firewall(id)
          delete("/firewalls/#{id.to_i}")
        rescue Error::Api => e
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

        def validate_credentials
          get("/server_types")
          true
        rescue Error::Api => e
          raise Error::Standard, "Hetzner credentials invalid: #{e.message}" if e.unauthorized?

          raise
        end

        # Volume Management
        def find_or_create_volume(name:, size:, location:, labels: {}, format: "xfs")
          existing = find_volume(name)
          return existing if existing

          create_volume(name:, size:, location:, labels:, format:)
        end

        def create_volume(name:, size:, location:, labels: {}, format: "xfs")
          response = post("/volumes", {
                            name:, size:, location:, labels: labels || {},
                            automount: false, format:
                          })
          to_volume(response["volume"])
        end

        def get_volume(id)
          response = get("/volumes/#{id.to_i}")
          to_volume(response["volume"])
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def find_volume(name)
          response = get("/volumes", name:)
          volume = response["volumes"]&.first
          volume ? to_volume(volume) : nil
        end

        def list_volumes(label_selector: nil)
          params = {}
          params[:label_selector] = label_selector if label_selector
          response = get("/volumes", params)
          response["volumes"].map { |v| to_volume(v) }
        end

        def attach_volume(volume_id:, server_id:, automount: false)
          volume = get_volume(volume_id)
          if volume&.server_id && !volume.server_id.empty? && volume.server_id.to_s != server_id.to_s
            detach_volume(volume_id:)
          end

          response = post("/volumes/#{volume_id.to_i}/actions/attach", {
                            server: server_id.to_i, automount:
                          })
          wait_for_action(response["action"]["id"]) if response["action"]
          get_volume(volume_id)
        end

        def detach_volume(volume_id:)
          response = post("/volumes/#{volume_id.to_i}/actions/detach")
          wait_for_action(response["action"]["id"]) if response["action"]
        rescue Error::Api => e
          raise unless e.message.include?("not attached")
        end

        def delete_volume(id)
          delete("/volumes/#{id.to_i}")
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def resize_volume(id, size:)
          response = post("/volumes/#{id.to_i}/actions/resize", { size: })
          wait_for_action(response["action"]["id"]) if response["action"]
          get_volume(id)
        end

        def wait_for_device_path(volume_id, _ssh_client)
          Waiter.poll(max_attempts: 30, interval: 2, message: "Volume device path not available") do
            volume = get("/volumes/#{volume_id.to_i}")["volume"]
            device = volume&.dig("linux_device")
            device unless device.nil? || device.empty?
          end
        end

        def wait_for_action(action_id, max_attempts: 60, interval: 2)
          Waiter.poll(max_attempts:, interval:, message: "Action #{action_id} timed out after #{max_attempts * interval} seconds") do
            response = get("/actions/#{action_id}")
            status = response.dig("action", "status")

            if status == "error"
              raise Error::Standard, "Action #{action_id} failed: #{response.dig('action', 'error', 'message')}"
            end

            status == "success"
          end
        end

        private

          def auth_headers
            { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json" }
          end

          def to_server(data)
            Types::Server.new(
              id: data["id"].to_s, name: data["name"], status: data["status"],
              public_ipv4: data.dig("public_net", "ipv4", "ip"),
              private_ipv4: data["private_net"]&.first&.dig("ip"),
              instance_type: data.dig("server_type", "name"),
              image: data.dig("image", "name"),
              location: data.dig("datacenter", "name"),
              labels: data["labels"] || {},
              created_at: data["created"]
            )
          end

          def to_firewall(data)
            Types::Firewall.new(
              id: data["id"].to_s, name: data["name"],
              rules: data["rules"] || [], created_at: data["created"]
            )
          end

          def to_network(data)
            Types::Network.new(
              id: data["id"].to_s, name: data["name"],
              ip_range: data["ip_range"], subnets: data["subnets"] || [],
              location: nil, created_at: data["created"]
            )
          end

          def to_volume(data)
            Types::Volume.new(
              id: data["id"].to_s, name: data["name"],
              size: data["size"], server_id: data["server"]&.to_s,
              location: data.dig("location", "name"),
              labels: data["labels"] || {},
              created_at: data["created"]
            )
          end

          def remove_firewall_from_server(firewall_id, server_id)
            post("/firewalls/#{firewall_id}/actions/remove_from_resources", {
                   remove_from: [ { type: "server", server: { id: server_id } } ]
                 })
          end

          def detach_server_from_network(server_id, network_id)
            post("/servers/#{server_id}/actions/detach_from_network", { network: network_id })
          end
      end
    end
  end
end
