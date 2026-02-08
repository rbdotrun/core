# frozen_string_literal: true

module RbrunCore
  module Commands
    class Deploy
      class ProvisionVolumes
        include Stepable

        DEFAULT_VOLUME_SIZE = 10 # GB, not configurable yet

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
        end

        def run
          return unless needs_volumes?

          report_step(Step::Id::PROVISION_VOLUMES, Step::IN_PROGRESS)

          @ctx.config.database_configs.each do |type, db_config|
            provision_database_volume(type, db_config)
          end

          report_step(Step::Id::PROVISION_VOLUMES, Step::DONE)
        end

        private

          def needs_volumes?
            @ctx.config.database?
          end

          def provision_database_volume(type, db_config)
            volume_name = Naming.database_volume(@ctx.prefix, type)
            server = find_target_server(db_config)

            # Create volume if not exists
            volume = compute_client.find_or_create_volume(
              name: volume_name,
              size: DEFAULT_VOLUME_SIZE,
              location: server.location,
              labels: { Naming::LABEL_INSTANCE => @ctx.prefix, Naming::LABEL_APP => "#{@ctx.prefix}-#{type}" }
            )

            # Attach to server if not attached
            if volume.server_id.nil? || volume.server_id.to_s != server.id.to_s
              volume = compute_client.attach_volume(volume_id: volume.id, server_id: server.id)
            end

            # Mount volume on server
            mount_volume(server, volume, type)
          end

          def find_target_server(db_config)
            if db_config.runs_on
              # Find server in specific group
              server_name = "#{@ctx.prefix}-#{db_config.runs_on}-1"
              compute_client.find_server(server_name) ||
                raise(Error::Standard, "Server #{server_name} not found for database")
            else
              # Use master server
              master_name = "#{@ctx.prefix}-master-1"
              compute_client.find_server(master_name) ||
                raise(Error::Standard, "Master server not found")
            end
          end

          def mount_volume(server, volume, type)
            ssh = Clients::Ssh.new(host: server.public_ipv4, private_key: @ctx.ssh_private_key,
                                   user: Naming.default_user)
            device_path = compute_client.wait_for_device_path(volume.id, ssh)

            raise Error::Standard, "Volume #{volume.id} has no device path after attachment" unless device_path

            path = mount_path(type)

            # Check if already mounted
            result = ssh.execute("mountpoint -q #{path} && echo 'mounted' || echo 'not'", raise_on_error: false)
            return if result[:output].strip == "mounted"

            # Wait for device to be available
            wait_for_device(ssh, device_path)

            # Create mount point
            ssh.execute("sudo mkdir -p #{path}")

            # Check if device has filesystem
            result = ssh.execute("sudo blkid #{device_path} || true", raise_on_error: false)
            if result[:output].empty? || !result[:output].include?("TYPE=")
              ssh.execute("sudo mkfs.xfs #{device_path}")
            end

            # Mount
            ssh.execute("sudo mount #{device_path} #{path}")

            # Add to fstab for persistence
            result = ssh.execute("grep '#{path}' /etc/fstab || true", raise_on_error: false)
            if result[:output].empty?
              ssh.execute(
                "UUID=$(sudo blkid -s UUID -o value #{device_path}) && " \
                "echo \"UUID=$UUID #{path} xfs defaults,nofail 0 2\" | sudo tee -a /etc/fstab"
              )
            end

            # Verify mount
            result = ssh.execute("mountpoint -q #{path} && echo 'mounted' || echo 'not'", raise_on_error: false)
            raise Error::Standard, "Volume not mounted at #{path}" unless result[:output].strip == "mounted"
          end

          def wait_for_device(ssh, device_path)
            Waiter.poll(max_attempts: 30, interval: 2, message: "Device #{device_path} not available") do
              result = ssh.execute("test -b #{device_path} && echo 'ready' || true", raise_on_error: false)
              result[:output].strip == "ready"
            end
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
