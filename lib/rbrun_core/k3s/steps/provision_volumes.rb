# frozen_string_literal: true

module RbrunCore
  module K3s
    module Steps
      class ProvisionVolumes
        DEFAULT_VOLUME_SIZE = 10

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          return unless needs_volumes?

          @on_step&.call("Volumes", :in_progress)

          @ctx.config.database_configs.each do |type, _db_config|
            provision_volume(type, find_master_server)
          end

          @ctx.config.service_configs.each do |name, svc_config|
            next unless svc_config.mount_path

            server = find_service_server(name, svc_config)
            provision_volume(name, server)
          end

          @on_step&.call("Volumes", :done)
        end

        private

          def needs_volumes?
            @ctx.config.database? || services_with_mount_path?
          end

          def services_with_mount_path?
            @ctx.config.service_configs.any? { |_, svc| svc.mount_path }
          end

          def provision_volume(name, server)
            volume_name = Naming.volume(@ctx.prefix, name)

            volume = compute_client.find_or_create_volume(
              name: volume_name,
              size: DEFAULT_VOLUME_SIZE,
              location: server.location,
              labels: { Naming::LABEL_INSTANCE => @ctx.prefix, Naming::LABEL_APP => "#{@ctx.prefix}-#{name}" }
            )

            if volume.server_id.nil? || volume.server_id.to_s != server.id.to_s
              volume = compute_client.attach_volume(volume_id: volume.id, server_id: server.id)
            end

            # Mount volume on server
            mount_volume(server, volume, name)
          end

          def find_master_server
            master_name = "#{@ctx.prefix}-master-1"
            compute_client.find_server(master_name) ||
              raise(Error::Standard, "Master server not found")
          end

          def find_service_server(name, svc_config)
            if svc_config.instance_type
              server_name = "#{@ctx.prefix}-#{name}-1"
              compute_client.find_server(server_name) ||
                raise(Error::Standard, "Service server #{server_name} not found")
            else
              find_master_server
            end
          end

          def mount_volume(server, volume, type)
            ssh = Clients::Ssh.new(
              host: server.public_ipv4,
              private_key: @ctx.ssh_private_key,
              user: RbrunCore::Naming.default_user
            )
            device_path = compute_client.wait_for_device_path(volume.id, ssh)

            raise Error::Standard, "Volume #{volume.id} has no device path after attachment" unless device_path

            path = mount_path(type)
            return if already_mounted?(ssh, path)

            wait_for_device(ssh, device_path)
            create_mount_point(ssh, path)
            format_device_if_needed(ssh, device_path)
            mount_device(ssh, device_path, path)
            add_to_fstab(ssh, device_path, path)
            verify_mount(ssh, path)
          end

          def already_mounted?(ssh, path)
            cmd = [ "mountpoint", "-q", path, "&&", "echo", "'mounted'", "||", "echo", "'not'" ].join(" ")
            result = ssh.execute(cmd, raise_on_error: false)
            result[:output].strip == "mounted"
          end

          def wait_for_device(ssh, device_path)
            Waiter.poll(max_attempts: 30, interval: 2, message: "Device #{device_path} not available") do
              cmd = [ "test", "-b", device_path, "&&", "echo", "'ready'", "||", "true" ].join(" ")
              result = ssh.execute(cmd, raise_on_error: false)
              result[:output].strip == "ready"
            end
          end

          def create_mount_point(ssh, path)
            cmd = [ "sudo", "mkdir", "-p", path ].join(" ")
            ssh.execute(cmd)
          end

          def format_device_if_needed(ssh, device_path)
            cmd = [ "sudo", "blkid", device_path, "||", "true" ].join(" ")
            result = ssh.execute(cmd, raise_on_error: false)

            return if result[:output].include?("TYPE=")

            format_cmd = [ "sudo", "mkfs.xfs", device_path ].join(" ")
            ssh.execute(format_cmd)
          end

          def mount_device(ssh, device_path, path)
            cmd = [ "sudo", "mount", device_path, path ].join(" ")
            ssh.execute(cmd)
          end

          def add_to_fstab(ssh, device_path, path)
            check_cmd = [ "grep", "'#{path}'", "/etc/fstab", "||", "true" ].join(" ")
            result = ssh.execute(check_cmd, raise_on_error: false)
            return unless result[:output].empty?

            fstab_cmd = [
              "UUID=$(sudo blkid -s UUID -o value #{device_path})",
              "&&",
              "echo \"UUID=$UUID #{path} xfs defaults,nofail 0 2\"",
              "|",
              "sudo tee -a /etc/fstab"
            ].join(" ")
            ssh.execute(fstab_cmd)
          end

          def verify_mount(ssh, path)
            cmd = [ "mountpoint", "-q", path, "&&", "echo", "'mounted'", "||", "echo", "'not'" ].join(" ")
            result = ssh.execute(cmd, raise_on_error: false)
            raise Error::Standard, "Volume not mounted at #{path}" unless result[:output].strip == "mounted"
          end

          def mount_path(type)
            "/mnt/data/#{@ctx.prefix}-#{type}"
          end

          def compute_client
            @ctx.compute_client
          end
      end
    end
  end
end
