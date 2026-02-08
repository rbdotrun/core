# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Services
        private

          def service_manifests
            manifests = []
            @config.service_configs.each do |name, svc_config|
              manifests.concat(generic_service_manifests(name, svc_config))
            end
            manifests
          end

          def generic_service_manifests(name, svc_config)
            deployment_name = "#{@prefix}-#{name}"
            secret_name = "#{deployment_name}-secret"
            manifests = []

            manifests << secret(name: secret_name, data: svc_config.env.transform_keys(&:to_s)) if svc_config.env.any?

            container = {
              name: name.to_s, image: svc_config.image,
              ports: svc_config.port ? [ { containerPort: svc_config.port } ] : []
            }
            container[:envFrom] = [ { secretRef: { name: secret_name } } ] if svc_config.env.any?

            volumes = []
            if svc_config.mount_path
              container[:volumeMounts] = [ { name: "data", mountPath: svc_config.mount_path } ]
              volumes = [ host_path_volume("data", "/mnt/data/#{deployment_name}") ]
            end

            manifests << deployment(
              name: deployment_name, replicas: 1,
              node_selector: node_selector_for(svc_config.runs_on),
              containers: [ container.compact ],
              volumes:
            )

            manifests << service(name: deployment_name, port: svc_config.port) if svc_config.port

            subdomain = svc_config.subdomain
            if subdomain && svc_config.port
              manifests << ingress(name: deployment_name, hostname: "#{subdomain}.#{@zone}", port: svc_config.port)
            end

            manifests
          end
      end
    end
  end
end
