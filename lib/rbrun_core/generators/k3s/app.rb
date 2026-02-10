# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module App
        private

          def app_manifests
            @config.app_config.processes.flat_map do |name, process|
              process_manifests(name, process)
            end
          end

          def process_manifests(name, process)
            deployment_name = Naming.deployment(@prefix, name)
            container = build_process_container(name, process)

            manifests = []
            manifests << process_deployment(deployment_name, process, container)
            manifests << process_service(deployment_name, process)
            manifests << process_ingress(deployment_name, process)
            manifests.compact
          end

          def build_process_container(name, process)
            container = {
              name: name.to_s,
              image: @registry_tag,
              envFrom: [
                { secretRef: { name: Naming.app_secret(@prefix) } }
              ]
            }

            if process.env&.any?
              container[:env] = process.env.map do |k, v|
                { name: k.to_s, value: v.to_s }
              end
            end

            if process.command
              container[:args] = Shellwords.split(process.command)
            end

            if process.port
              container[:ports] = [
                { containerPort: process.port }
              ]
              container[:readinessProbe] = build_readiness_probe(process)
            end

            allocation = @allocations[name.to_s]
            container[:resources] = allocation.to_kubernetes if allocation

            container
          end

          def build_readiness_probe(process)
            http_get = {
              path: "/up",
              port: process.port
            }

            if process.subdomain && @zone
              http_get[:httpHeaders] = [
                { name: "Host", value: Naming.fqdn(process.subdomain, @zone) }
              ]
            end

            {
              httpGet: http_get,
              initialDelaySeconds: 10,
              periodSeconds: 10
            }
          end

          def process_deployment(deployment_name, process, container)
            deployment(
              name: deployment_name,
              replicas: process.effective_replicas,
              node_selector: node_selector_for_instance_type(process),
              containers: [ container ],
              init_containers: build_init_containers(process)
            )
          end

          def process_service(deployment_name, process)
            return unless process.port

            service(name: deployment_name, port: process.port)
          end

          def process_ingress(deployment_name, process)
            return unless process.subdomain && process.port

            ingress(
              name: deployment_name,
              hostname: Naming.fqdn(process.subdomain, @zone),
              port: process.port
            )
          end

          def build_init_containers(process)
            return [] if process.setup.empty?

            process.setup.each_with_index.map do |cmd, idx|
              {
                name: "setup-#{idx}",
                image: @registry_tag,
                command: [ "sh", "-c", cmd ],
                envFrom: [
                  { secretRef: { name: Naming.app_secret(@prefix) } }
                ]
              }
            end
          end
      end
    end
  end
end
