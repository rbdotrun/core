# frozen_string_literal: true

module RbrunCore
  module Steps
    class ProvisionVolume
      VOLUME_MOUNT_BASE = "/mnt/data"

      def initialize(ctx, on_log: nil)
        @ctx = ctx
        @on_log = on_log
      end

      def run
        return unless @ctx.config.database?

        @ctx.config.database_configs.each do |type, db_config|
          volume_size = @ctx.config.resolve(db_config.volume_size, target: @ctx.target)
          next unless volume_size

          log("volume_#{type}", "Provisioning volume for #{type}")
          provision_volume!(
            name: "#{@ctx.prefix}-#{type}",
            size: volume_size.to_i,
            mount_path: "#{VOLUME_MOUNT_BASE}/#{@ctx.prefix}-#{type}"
          )
        end
      end

      private

        def provision_volume!(name:, size:, mount_path:)
          server = compute_client.find_server(@ctx.prefix)
          location = server.location.split("-").first

          volume = compute_client.find_or_create_volume(
            name:, size:, location:, labels: { purpose: @ctx.target.to_s }
          )

          if volume.server_id.to_s != server.id.to_s
            compute_client.attach_volume(volume_id: volume.id, server_id: server.id)
          end

          device_path = wait_for_device_path!(volume.id)
          wait_for_device!(device_path)
          mount_volume!(device_path, mount_path)
        end

        def wait_for_device_path!(volume_id)
          30.times do
            volume = compute_client.get_volume(volume_id)
            return volume.device_path if volume.device_path && !volume.device_path.empty?
            sleep 2
          end
          raise RbrunCore::Error, "Volume #{volume_id} has no device path after attachment"
        end

        def wait_for_device!(device_path)
          30.times do
            result = ssh!("test -b #{device_path} && echo 'ready' || true", raise_on_error: false)
            return if result[:output].include?("ready")
            sleep 2
          end
          raise RbrunCore::Error, "Device #{device_path} not available on server"
        end

        def mount_volume!(device_path, mount_path)
          result = ssh!("mountpoint -q #{mount_path} && echo 'mounted' || echo 'not'", raise_on_error: false)
          return if result[:output].include?("mounted")

          ssh!("sudo mkdir -p #{mount_path}")

          fs_check = ssh!("sudo blkid #{device_path} || true", raise_on_error: false)
          unless fs_check[:output].include?("TYPE=")
            ssh!("sudo mkfs.xfs #{device_path}")
          end

          ssh!("sudo mount #{device_path} #{mount_path}")

          fstab_check = ssh!("grep '#{mount_path}' /etc/fstab || true", raise_on_error: false)
          unless fstab_check[:output].include?(mount_path)
            ssh!("UUID=$(sudo blkid -s UUID -o value #{device_path}) && echo \"UUID=$UUID #{mount_path} xfs defaults,nofail 0 2\" | sudo tee -a /etc/fstab")
          end

          verify = ssh!("mountpoint -q #{mount_path} && echo 'ok' || echo 'fail'", raise_on_error: false)
          raise RbrunCore::Error, "Volume not mounted at #{mount_path}" unless verify[:output].include?("ok")
        end

        def compute_client = @ctx.compute_client
        def ssh!(command, **opts) = @ctx.ssh_client.execute(command, **opts)

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
