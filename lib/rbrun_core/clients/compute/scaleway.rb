# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      class Scaleway < Base
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
        def find_or_create_server(name:, commercial_type:, image:, tags: [], security_group_id: nil)
          existing = find_server(name)
          return existing if existing

          create_server(name:, commercial_type:, image:, tags:, security_group_id:)
        end

        def create_server(name:, commercial_type:, image:, tags: [], security_group_id: nil)
          payload = { name:, commercial_type:, image:, project: @project_id, tags: tags || [] }
          payload[:security_group] = security_group_id if security_group_id

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

        def delete_server(id)
          server = get_server(id)
          return nil unless server

          if server.status == "running"
            power_off(id)
            wait_for_server_stopped(id)
          end

          full_server = get(instance_path("/servers/#{id}"))["server"]
          full_server["volumes"]&.each_value do |vol|
            delete_volume(vol["id"]) if vol["id"]
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

        # Security Groups
        def find_or_create_security_group(name:, inbound_default_policy: "drop", outbound_default_policy: "accept")
          existing = find_security_group(name)
          return existing if existing

          response = post(instance_path("/security_groups"), {
                            name:, project: @project_id,
                            inbound_default_policy:, outbound_default_policy:
                          })
          to_security_group(response["security_group"])
        end

        def find_security_group(name)
          response = get(instance_path("/security_groups"), name:, project: @project_id)
          sg = response["security_groups"]&.find { |g| g["name"] == name }
          sg ? to_security_group(sg) : nil
        end

        def list_security_groups
          response = get(instance_path("/security_groups"), project: @project_id)
          (response["security_groups"] || []).map { |g| to_security_group(g) }
        end

        def delete_security_group(id)
          delete(instance_path("/security_groups/#{id}"))
        rescue HttpErrors::ApiError => e
          raise unless e.not_found?

          nil
        end

        # Volumes
        def create_volume(name:, size_gb:, volume_type: "b_ssd")
          response = post(instance_path("/volumes"), {
                            name:, project: @project_id,
                            size: size_gb * 1_000_000_000, volume_type:
                          })
          to_volume(response["volume"])
        end

        def list_volumes
          response = get(instance_path("/volumes"), project: @project_id)
          (response["volumes"] || []).map { |v| to_volume(v) }
        end

        def find_volume(name)
          response = get(instance_path("/volumes"), name:, project: @project_id)
          vol = response["volumes"]&.find { |v| v["name"] == name }
          vol ? to_volume(vol) : nil
        end

        def delete_volume(id)
          delete(instance_path("/volumes/#{id}"))
        rescue HttpErrors::ApiError => e
          raise unless e.not_found?

          nil
        end

        def inventory
          {
            servers: list_servers,
            security_groups: list_security_groups,
            volumes: list_volumes
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

          def to_server(data)
            Types::Server.new(
              id: data["id"], name: data["name"], status: data["state"],
              public_ipv4: data.dig("public_ip", "address"),
              private_ipv4: data["private_ip"],
              instance_type: data["commercial_type"],
              image: data.dig("image", "name"),
              location: data["zone"], labels: (data["tags"] || []).to_h { |t| [ t, true ] },
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

          def to_security_group(data)
            Types::Firewall.new(
              id: data["id"], name: data["name"],
              rules: data["rules"] || [], created_at: data["creation_date"]
            )
          end

          def to_volume(data)
            Types::Volume.new(
              id: data["id"], name: data["name"],
              size_gb: data["size"].to_i / 1_000_000_000,
              volume_type: data["volume_type"], status: data["state"],
              server_id: data.dig("server", "id"),
              location: data["zone"], created_at: data["creation_date"]
            )
          end
      end
    end
  end
end
