# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Tunnel
        private

          def tunnel_manifest
            name = "#{@prefix}-cloudflared"
            deployment(
              name:, replicas: 1, host_network: true,
              node_selector: { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP },
              containers: [ {
                name: "cloudflared", image: "cloudflare/cloudflared:latest",
                args: [ "tunnel", "--no-autoupdate", "run", "--token", @tunnel_token ]
              } ]
            )
          end
      end
    end
  end
end
