# frozen_string_literal: true

module RbrunCore
  module K3s
    class Generators
      module Services
        private

          def service_manifests
            @config.service_configs.flat_map do |name, svc_config|
              build_service_manifests(name, svc_config)
            end
          end

          def build_service_manifests(name, svc_config)
            deployment_name = Naming.deployment(@prefix, name)
            secret_name = Naming.secret_for(deployment_name)

            manifests = []
            manifests << service_secret(secret_name, svc_config)
            manifests << service_deployment(deployment_name, name, svc_config, secret_name)
            manifests << service_k8s_service(deployment_name, svc_config)
            manifests << service_ingress(deployment_name, svc_config)
            manifests.compact
          end

          def service_secret(secret_name, svc_config)
            return unless svc_config.env.any?

            secret(
              name: secret_name,
              data: svc_config.env.transform_keys(&:to_s)
            )
          end

          def service_deployment(deployment_name, name, svc_config, secret_name)
            container = build_service_container(name, svc_config, secret_name)
            volumes = build_service_volumes(deployment_name, svc_config, container)

            if svc_config.mount_path
              statefulset(
                name: deployment_name,
                node_selector: node_selector_for_instance_type(svc_config) || master_node_selector,
                containers: [ container.compact ],
                volumes:
              )
            else
              deployment(
                name: deployment_name,
                replicas: svc_config.effective_replicas,
                node_selector: node_selector_for_instance_type(svc_config),
                containers: [ container.compact ],
                volumes:,
                anti_affinity: !!svc_config.instance_type
              )
            end
          end

          def build_service_container(name, svc_config, secret_name)
            container = {
              name: name.to_s,
              image: svc_config.image,
              ports: build_service_ports(svc_config)
            }

            if svc_config.env.any?
              container[:envFrom] = [
                { secretRef: { name: secret_name } }
              ]
            end

            container
          end

          def build_service_ports(svc_config)
            return [] unless svc_config.port

            [
              { containerPort: svc_config.port }
            ]
          end

          def build_service_volumes(deployment_name, svc_config, container)
            return [] unless svc_config.mount_path

            container[:volumeMounts] = [ { name: "data", mountPath: svc_config.mount_path } ]

            [ host_path_volume("data", "/mnt/data/#{deployment_name}") ]
          end

          def service_k8s_service(deployment_name, svc_config)
            return unless svc_config.port

            if svc_config.mount_path
              headless_service(name: deployment_name, port: svc_config.port)
            else
              service(name: deployment_name, port: svc_config.port)
            end
          end

          def service_ingress(deployment_name, svc_config)
            return unless svc_config.subdomain && svc_config.port

            ingress(
              name: deployment_name,
              hostname: Naming.fqdn(svc_config.subdomain, @zone),
              port: svc_config.port
            )
          end
      end
    end
  end
end
