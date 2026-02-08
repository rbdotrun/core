# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Tunnel
        private

          def tunnel_manifest
            deployment(
              name: tunnel_name,
              replicas: 1,
              host_network: true,
              node_selector: master_node_selector,
              containers: [ tunnel_container ]
            )
          end

          def tunnel_name
            Naming.cloudflared(@prefix)
          end

          def tunnel_container
            {
              name: "cloudflared",
              image: "cloudflare/cloudflared:latest",
              args: tunnel_args
            }
          end

          def tunnel_args
            [
              "tunnel",
              "--no-autoupdate",
              "run",
              "--token",
              @tunnel_token
            ]
          end

          def master_node_selector
            { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP }
          end
      end
    end
  end
end
