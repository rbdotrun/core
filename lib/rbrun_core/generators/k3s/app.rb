# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module App
        private

          def app_manifests
            manifests = []
            @config.app_config.processes.each do |name, process|
              manifests.concat(process_manifests(name, process))
            end
            manifests
          end

          def process_manifests(name, process)
            deployment_name = Naming.deployment(@prefix, name)
            subdomain = process.subdomain
            manifests = []

            container = {
              name: name.to_s, image: @registry_tag,
              envFrom: [ { secretRef: { name: Naming.app_secret(@prefix) } } ]
            }
            if process.env&.any?
              container[:env] = process.env.map { |k, v| { name: k.to_s, value: v.to_s } }
            end
            container[:args] = Shellwords.split(process.command) if process.command
            container[:ports] = [ { containerPort: process.port } ] if process.port

            if process.port
              http_get = { path: "/up", port: process.port }
              http_get[:httpHeaders] = [ { name: "Host", value: Naming.fqdn(subdomain, @zone) } ] if subdomain && @zone
              container[:readinessProbe] = { httpGet: http_get, initialDelaySeconds: 10, periodSeconds: 10 }
            end

            init_containers = setup_init_containers(process)

            manifests << deployment(name: deployment_name, replicas: process.replicas,
                                    node_selector: node_selector_for_process(process.runs_on),
                                    containers: [ container ], init_containers:)
            manifests << service(name: deployment_name, port: process.port) if process.port
            if subdomain && process.port
              manifests << ingress(name: deployment_name, hostname: Naming.fqdn(subdomain, @zone),
                                   port: process.port)
            end

            manifests
          end

          def setup_init_containers(process)
            return [] if process.setup.empty?

            process.setup.each_with_index.map do |cmd, idx|
              {
                name: "setup-#{idx}",
                image: @registry_tag,
                command: [ "sh", "-c", cmd ],
                envFrom: [ { secretRef: { name: Naming.app_secret(@prefix) } } ]
              }
            end
          end
      end
    end
  end
end
