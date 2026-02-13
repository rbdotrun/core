# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      class Scaleway < Base
        include Interface

        BASE_URL = "https://api.scaleway.com"

        DEFAULT_ROOT_VOLUME_SIZE = 20 # GB

        def initialize(api_key:, project_id:, zone: "fr-par-1", root_volume_size: nil)
          @api_key = api_key
          @project_id = project_id
          @zone = zone
          @root_volume_size = root_volume_size || DEFAULT_ROOT_VOLUME_SIZE
          raise Error::Standard, "Scaleway API key not configured" if @api_key.nil? || @api_key.empty?
          raise Error::Standard, "Scaleway project ID not configured" if @project_id.nil? || @project_id.empty?

          super(timeout: 300)
        end

        # Servers
        def find_or_create_server(name:, instance_type:, image:, location: nil, user_data: nil, labels: {},
                                  firewall_ids: [], network_ids: [], public_ip: true)
          existing = find_server(name)
          return existing if existing

          create_server(name:, instance_type:, image:, location:, user_data:, labels:,
                        firewall_ids:, network_ids:, public_ip:)
        end

        def create_server(name:, instance_type:, image:, location: nil, user_data: nil, labels: {},
                          firewall_ids: [], network_ids: [], public_ip: true)
          tags = labels_to_tags(labels)
          image_id = resolve_image_id(image, instance_type)
          payload = {
            name:, commercial_type: instance_type, image: image_id, project: @project_id, tags:,
            volumes: { "0" => { size: @root_volume_size * 1_000_000_000, volume_type: "l_ssd" } }
          }
          payload[:security_group] = firewall_ids.first if firewall_ids&.any?
          payload[:dynamic_ip_required] = public_ip

          response = post(instance_path("/servers"), payload)
          server = to_server(response["server"])

          # Set cloud-init user data via separate endpoint
          if user_data && !user_data.empty?
            set_user_data(server.id, user_data)
          end

          # Power on immediately (don't wait for stopped state)
          power_on(server.id)

          # Wait for server to be running (with public IP if requested)
          server = wait_for_server(server.id, max_attempts: 60, interval: 3, require_public_ip: public_ip)

          # Attach to private network if provided
          if network_ids&.any?
            network_ids.each { |net_id| create_private_nic(server.id, net_id) }
          end

          server
        end

        def get_server(id)
          response = get(instance_path("/servers/#{id}"))
          to_server(response["server"])
        rescue Error::Api => e
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

        def wait_for_server(id, max_attempts: 60, interval: 5, require_public_ip: true)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not become running after #{max_attempts} attempts") do
            server = get_server(id)
            if require_public_ip
              server if server&.status == "running" && server&.public_ipv4
            else
              server if server&.status == "running"
            end
          end
        end

        def wait_for_server_deletion(id, max_attempts: 30, interval: 2)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} was not deleted after #{max_attempts} attempts") do
            get_server(id).nil?
          end
        end

        def delete_server(id)
          # Delete private NICs first
          list_private_nics(id).each do |nic|
            delete_private_nic(id, nic["id"])
          rescue StandardError
            # Ignore cleanup errors
          end

          server = get_server(id)
          return if server.nil?

          if server.status == "stopped"
            # Stopped servers can't be terminated, delete directly
            delete(instance_path("/servers/#{id}"))
          else
            # Running servers: terminate (stops + deletes)
            server_action(id, "terminate")
          end

          # Wait for server to be fully deleted before returning
          wait_for_server_deletion(id)
        rescue Error::Api => e
          raise unless e.not_found?
        end

        def list_private_nics(server_id)
          response = get(instance_path("/servers/#{server_id}/private_nics"))
          response["private_nics"] || []
        end

        def delete_private_nic(server_id, nic_id)
          delete(instance_path("/servers/#{server_id}/private_nics/#{nic_id}"))
        end

        def server_action(id, action)
          post(instance_path("/servers/#{id}/action"), { action: })
        end

        def power_on(id) = post(instance_path("/servers/#{id}/action"), { action: "poweron" })
        def power_off(id) = post(instance_path("/servers/#{id}/action"), { action: "poweroff" })

        def create_private_nic(server_id, private_network_id)
          post(instance_path("/servers/#{server_id}/private_nics"), { private_network_id: })
        end
        def reboot(id) = post(instance_path("/servers/#{id}/action"), { action: "reboot" })

        def set_user_data(server_id, content)
          patch(instance_path("/servers/#{server_id}/user_data/cloud-init"), content,
                content_type: "text/plain")
        end

        # Firewalls (Security Groups)
        def find_or_create_firewall(name, rules: nil)
          existing = find_firewall(name)
          return existing if existing

          response = post(
            instance_path("/security_groups"),
            { name:, project: @project_id, stateful: true, inbound_default_policy: "drop", outbound_default_policy: "accept" }
          )
          sg = to_firewall(response["security_group"])

          add_ssh_rule(sg.id)
          rules.each { |rule| add_security_group_rule(sg.id, rule) } if rules
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
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        # Networks (VPC Private Networks)
        def find_or_create_network(name, location:)
          existing = find_network(name)
          return existing if existing

          response = post(
            vpc_path("/private-networks"),
            { name:, project_id: @project_id }
          )
          to_network(response)
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
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        # Volume Management (Block Storage)
        def find_or_create_volume(name:, size:, location: nil, labels: {})
          existing = find_volume(name)
          return existing if existing

          create_volume(name:, size:)
        end

        def create_volume(name:, size:, labels: {})
          response = post(
            block_path("/volumes"),
            { name:, perf_iops: 5000, from_empty: { size: size * 1_000_000_000 }, project_id: @project_id }
          )
          to_volume(response)
        end

        def get_volume(id)
          response = get(block_path("/volumes/#{id}"))
          to_volume(response)
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def find_volume(name)
          list_volumes.find { |v| v.name == name }
        end

        def list_volumes(label_selector: nil)
          response = get(block_path("/volumes"))
          (response["volumes"] || []).map { |v| to_volume(v) }
        end

        def attach_volume(volume_id:, server_id:)
          response = get(instance_path("/servers/#{server_id}"))
          server = response["server"]
          raise Error::Standard, "Server not found: #{server_id}" unless server

          wait_for_volume_available(volume_id)

          current_volumes = server["volumes"] || {}
          next_index = current_volumes.keys.map(&:to_i).max.to_i + 1

          new_volumes = current_volumes.dup
          new_volumes[next_index.to_s] = { id: volume_id, volume_type: "sbs_volume" }

          patch(instance_path("/servers/#{server_id}"), { volumes: new_volumes })
          get_volume(volume_id)
        end

        def detach_volume(volume_id:)
          response = get(instance_path("/servers"), project: @project_id)
          servers = response["servers"]
          return unless servers

          servers.each do |server|
            volumes = server["volumes"] || {}
            volumes.each do |idx, vol|
              next unless vol["id"] == volume_id

              new_volumes = volumes.reject { |k, _| k == idx }
              patch(instance_path("/servers/#{server["id"]}"), { volumes: new_volumes })
              wait_for_volume_available(volume_id)
              return
            end
          end
        end

        def delete_volume(id)
          delete(block_path("/volumes/#{id}"))
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def wait_for_device_path(volume_id, ssh_client)
          Waiter.poll(max_attempts: 30, interval: 2, message: "Volume device not found") do
            result = ssh_client.execute("ls /dev/disk/by-id/ 2>/dev/null | grep -i '#{volume_id}' || true",
                                        raise_on_error: false)
            output = result[:output].strip
            next nil if output.empty?

            device_name = output.lines.first.strip
            "/dev/disk/by-id/#{device_name}"
          end
        end

        def inventory
          {
            servers: list_servers,
            firewalls: list_firewalls,
            networks: list_networks
          }
        end

        # Image Management
        def create_image_from_server(server_id:, name:, description: nil, labels: {})
          # Power off server before creating image
          power_off(server_id)
          wait_for_server_stopped(server_id)

          # Get server's root volume
          response = get(instance_path("/servers/#{server_id}"))
          server_data = response["server"]
          root_volume_id = server_data.dig("volumes", "0", "id")
          raise Error::Standard, "Server has no root volume" unless root_volume_id

          # Create image from root volume
          tags = labels_to_tags(labels.merge(Naming::LABEL_BUILDER => "true"))
          payload = {
            name:,
            root_volume: root_volume_id,
            arch: server_data["arch"] || "x86_64",
            project: @project_id,
            tags:
          }

          response = post(instance_path("/images"), payload)
          image_id = response.dig("image", "id")
          wait_for_scaleway_image(image_id)
          get_scaleway_image(image_id)
        end

        def get_scaleway_image(id)
          response = get(instance_path("/images/#{id}"))
          to_scaleway_image(response["image"])
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def find_image(name)
          response = get(instance_path("/images"), project: @project_id)
          image = response["images"]&.find { |i| i["name"] == name }
          image ? to_scaleway_image(image) : nil
        end

        def list_scaleway_images
          response = get(instance_path("/images"), project: @project_id)
          (response["images"] || []).map { |i| to_scaleway_image(i) }
        end

        def delete_image(id)
          delete(instance_path("/images/#{id}"))
        rescue Error::Api => e
          raise unless e.not_found?

          nil
        end

        def wait_for_image(id, max_attempts: 120, interval: 5)
          wait_for_scaleway_image(id, max_attempts:, interval:)
        end

        # Validation
        def validate_credentials
          get(instance_path("/servers"), project: @project_id)
          true
        rescue Error::Api => e
          raise Error::Standard, "Scaleway credentials invalid: #{e.message}" if e.unauthorized?

          raise
        end

        def server_type_memory_mb(instance_type)
          @server_type_cache ||= {}
          return @server_type_cache[instance_type] if @server_type_cache.key?(instance_type)

          response = get(instance_path("/products/servers"))
          servers = response["servers"] || {}

          server_info = servers[instance_type]
          raise Error::Configuration, "Unknown instance type '#{instance_type}'" unless server_info

          memory_bytes = server_info["ram"]
          @server_type_cache[instance_type] = (memory_bytes / (1024 * 1024)).to_i
        end

        private

          def instance_path(path) = "/instance/v1/zones/#{@zone}#{path}"
          def iam_path(path) = "/iam/v1alpha1#{path}"
          def block_path(path) = "/block/v1alpha1/zones/#{@zone}#{path}"

          def vpc_path(path)
            region = zone_to_region(@zone)
            "/vpc/v2/regions/#{region}#{path}"
          end

          def zone_to_region(zone) = zone.sub(/-\d+$/, "")

          def auth_headers
            { "X-Auth-Token" => @api_key }
          end

          def wait_for_scaleway_image(id, max_attempts: 120, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Image #{id} did not become available") do
              image = get_scaleway_image(id)
              image if image&.status == "available"
            end
          end

          def resolve_image_id(image, instance_type)
            # If it's a UUID (our custom image), use it directly
            return image if image =~ /^[a-f0-9-]{36}$/i

            resolve_image(image, instance_type)
          end

          def resolve_image(image, instance_type)
            # If it looks like a UUID, use it directly
            return image if image =~ /^[a-f0-9-]{36}$/i

            # Otherwise, look up by label (e.g., "ubuntu_jammy")
            arch = instance_type_arch(instance_type)
            # Use query params like working implementation
            response = get("#{instance_path("/images")}?arch=#{arch}&name=#{image}")
            found = response["images"]&.first
            raise Error::Standard, "Image '#{image}' not found for arch #{arch}" unless found

            found["id"]
          end

          def instance_type_arch(instance_type)
            # DEV1, GP1, PLAY2 are x86_64; AMP2, COPARM1 are arm64
            instance_type.upcase.start_with?("AMP", "COPARM") ? "arm64" : "x86_64"
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

          def add_ssh_rule(sg_id)
            post(
              instance_path("/security_groups/#{sg_id}/rules"),
              { protocol: "TCP", direction: "inbound", action: "accept", ip_range: "0.0.0.0/0", dest_port_from: 22, dest_port_to: 22 }
            )
          end

          def add_security_group_rule(sg_id, rule)
            direction = rule[:direction] == "in" ? "inbound" : "outbound"
            protocol = rule[:protocol]&.upcase || "TCP"
            port = rule[:port]
            source_ips = rule[:source_ips]
            raise Error::Standard, "source_ips required for firewall rule" if source_ips.nil? || source_ips.empty?

            source_ips.each do |ip_range|
              post(
                instance_path("/security_groups/#{sg_id}/rules"),
                { direction:, protocol:, dest_port_from: port.to_i, dest_port_to: port.to_i, action: "accept", ip_range: }
              )
            end
          end

          def delete_volume_internal(id)
            delete(instance_path("/volumes/#{id}"))
          rescue Error::Api => e
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

          def to_firewall(data)
            Types::Firewall.new(
              id: data["id"], name: data["name"],
              rules: data["rules"] || [], created_at: data["creation_date"]
            )
          end

          def to_network(data)
            raw_subnets = data["subnets"] || []
            subnets = raw_subnets.map { |s| s.is_a?(Hash) ? s["subnet"] : s }.compact
            Types::Network.new(
              id: data["id"], name: data["name"],
              ip_range: subnets.first || data.dig("subnets", 0, "subnet"),
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

          def wait_for_volume_available(volume_id, timeout: 60)
            Waiter.poll(max_attempts: 30, interval: 2, message: "Volume #{volume_id} did not become available") do
              vol = get(block_path("/volumes/#{volume_id}"))
              vol["status"] == "available"
            end
          end

          def to_volume(data)
            server_id = data["references"]&.find { |r|
              r["product_resource_type"] == "instance_server"
            }&.dig("product_resource_id")

            Types::Volume.new(
              id: data["id"],
              name: data["name"],
              size: (data["size"] || 0) / 1_000_000_000,
              server_id:,
              location: data["zone"],
              status: data["status"],
              labels: {},
              created_at: data["created_at"]
            )
          end

          def to_scaleway_image(data)
            Types::Image.new(
              id: data["id"],
              name: data["name"],
              status: data["state"],
              description: data["name"],
              size_gb: (data.dig("root_volume", "size") || 0) / 1_000_000_000,
              labels: tags_to_labels(data["tags"]),
              created_at: data["creation_date"]
            )
          end
      end
    end
  end
end
