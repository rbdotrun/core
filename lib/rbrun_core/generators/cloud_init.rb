# frozen_string_literal: true

module RbrunCore
  module Generators
    # Generates cloud-init YAML for VM provisioning.
    class CloudInit
      MIN_SWAP_MB = 512
      MAX_SWAP_MB = 2048

      def self.generate(ssh_public_key:, user: Naming.default_user, root_volume_size: 20)
        new(ssh_public_key:, user:, root_volume_size:).to_yaml
      end

      def initialize(ssh_public_key:, user: Naming.default_user, root_volume_size: 20)
        @ssh_public_key = ssh_public_key
        @user = user
        @root_volume_size = root_volume_size
      end

      def to_yaml
        <<~CLOUD_INIT
          #cloud-config
          users:
            - name: #{@user}
              groups: sudo,docker
              shell: /bin/bash
              sudo: ALL=(ALL) NOPASSWD:ALL
              ssh_authorized_keys:
                - #{@ssh_public_key}
          disable_root: true
          ssh_pwauth: false
          swap:
            filename: /swapfile
            size: #{swap_size}
            maxsize: #{swap_size}
        CLOUD_INIT
      end

      private

        # ~5% of disk, clamped between 512MB and 2GB.
        def swap_size
          mb = [[@root_volume_size * 1024 / 20, MIN_SWAP_MB].max, MAX_SWAP_MB].min
          "#{mb}M"
        end
    end
  end
end
