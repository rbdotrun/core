# frozen_string_literal: true

require "yaml"
require "base64"
require "shellwords"

module RbrunCore
  module Generators
    class K3s
      NAMESPACE = "default"

      def initialize(config, prefix:, zone:, db_password: nil, registry_tag: nil, tunnel_token: nil, r2_credentials: nil)
        @config = config
        @prefix = prefix
        @zone = zone
        @db_password = db_password || SecureRandom.hex(16)
        @registry_tag = registry_tag
        @tunnel_token = tunnel_token
        @r2_credentials = r2_credentials
      end

      def generate
        manifests = []
        manifests << app_secret
        manifests.concat(database_manifests) if @config.database?
        manifests.concat(service_manifests) if @config.service?
        manifests.concat(app_manifests) if @config.app? && @registry_tag
        manifests << tunnel_manifest if @tunnel_token
        manifests.concat(backup_manifests) if @config.database?(:postgres) && @r2_credentials
        to_yaml(manifests)
      end

      private

        def to_yaml(resources)
          Array(resources).compact.map { |r| YAML.dump(deep_stringify_keys(r)) }.join("\n---\n")
        end

        def deep_stringify_keys(obj)
          case obj
          when Hash
            obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify_keys(v) }
          when Array
            obj.map { |v| deep_stringify_keys(v) }
          else
            obj
          end
        end

        def app_secret
          env_data = {}

          @config.env_vars.each do |key, value|
            env_data[key.to_s] = value.to_s
          end

          if @config.database?(:postgres)
            pg = @config.database_configs[:postgres]
            pg_user = pg.username || "app"
            pg_db = pg.database || "app"
            env_data["DATABASE_URL"] = "postgresql://#{pg_user}:#{@db_password}@#{@prefix}-postgres:5432/#{pg_db}"
            env_data["POSTGRES_HOST"] = "#{@prefix}-postgres"
            env_data["POSTGRES_USER"] = pg_user
            env_data["POSTGRES_PASSWORD"] = @db_password
            env_data["POSTGRES_DB"] = pg_db
            env_data["POSTGRES_PORT"] = "5432"
          end

          @config.service_configs.each do |name, svc_config|
            next unless svc_config.port

            env_var = "#{name.to_s.upcase}_URL"
            protocol = name == :redis ? "redis" : "http"
            env_data[env_var] = "#{protocol}://#{@prefix}-#{name}:#{svc_config.port}"
          end

          secret(name: "#{@prefix}-app-secret", data: env_data)
        end

        def database_manifests
          manifests = []
          @config.database_configs.each do |type, db_config|
            case type
            when :postgres then manifests.concat(postgres_manifests(db_config))
            end
          end
          manifests
        end

        def postgres_manifests(db_config)
          name = "#{@prefix}-postgres"
          secret_name = "#{name}-secret"
          pg_user = db_config.username || "app"
          pg_db = db_config.database || "app"

          [
            secret(name: secret_name, data: { "DB_PASSWORD" => @db_password }),
            deployment(
              name:, replicas: 1,
              node_selector: { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP },
              containers: [ {
                name: "postgres", image: db_config.image,
                ports: [ { containerPort: 5432 } ],
                env: [
                  { name: "POSTGRES_USER", value: pg_user },
                  { name: "POSTGRES_DB", value: pg_db },
                  { name: "POSTGRES_PASSWORD", valueFrom: { secretKeyRef: { name: secret_name, key: "DB_PASSWORD" } } },
                  { name: "PGDATA", value: "/var/lib/postgresql/data/pgdata" }
                ],
                volumeMounts: [ { name: "data", mountPath: "/var/lib/postgresql/data" } ],
                readinessProbe: { exec: { command: [ "pg_isready", "-U", pg_user ] }, initialDelaySeconds: 5, periodSeconds: 5 }
              } ],
              volumes: [ host_path_volume("data", "/mnt/data/#{name}") ]
            ),
            service(name:, port: 5432)
          ]
        end

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

          # Add volume mount if service has mount_path
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

        def app_manifests
          manifests = []
          @config.app_config.processes.each do |name, process|
            manifests.concat(process_manifests(name, process))
          end
          manifests
        end

        def process_manifests(name, process)
          deployment_name = "#{@prefix}-#{name}"
          subdomain = process.subdomain
          manifests = []

          container = {
            name: name.to_s, image: @registry_tag,
            envFrom: [ { secretRef: { name: "#{@prefix}-app-secret" } } ]
          }
          if process.env&.any?
            container[:env] = process.env.map { |k, v| { name: k.to_s, value: v.to_s } }
          end
          container[:args] = Shellwords.split(process.command) if process.command
          container[:ports] = [ { containerPort: process.port } ] if process.port

          if process.port
            http_get = { path: "/up", port: process.port }
            http_get[:httpHeaders] = [ { name: "Host", value: "#{subdomain}.#{@zone}" } ] if subdomain && @zone
            container[:readinessProbe] = { httpGet: http_get, initialDelaySeconds: 10, periodSeconds: 10 }
          end

          init_containers = setup_init_containers(process)

          manifests << deployment(name: deployment_name, replicas: process.replicas,
                                  node_selector: node_selector_for_process(process.runs_on),
                                  containers: [ container ], init_containers:)
          manifests << service(name: deployment_name, port: process.port) if process.port
          if subdomain && process.port
            manifests << ingress(name: deployment_name, hostname: "#{subdomain}.#{@zone}",
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
              envFrom: [ { secretRef: { name: "#{@prefix}-app-secret" } } ]
            }
          end
        end

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

        def node_selector_for(runs_on)
          return nil unless runs_on

          { Naming::LABEL_SERVER_GROUP => runs_on.to_s }
        end

        def node_selector_for_process(runs_on)
          return nil unless runs_on

          if runs_on.is_a?(Array) && runs_on.length > 1
            # Use nodeAffinity for multiple groups
            :affinity
          elsif runs_on.is_a?(Array)
            { Naming::LABEL_SERVER_GROUP => runs_on.first.to_s }
          else
            { Naming::LABEL_SERVER_GROUP => runs_on.to_s }
          end
        end

        def labels(name)
          { Naming::LABEL_APP => name, Naming::LABEL_INSTANCE => @prefix,
            Naming::LABEL_MANAGED_BY => "rbrun" }
        end

        def deployment(name:, containers:, volumes: [], replicas: 1, host_network: false, node_selector: nil,
                       init_containers: [])
          spec = { containers: }
          spec[:initContainers] = init_containers if init_containers.any?
          spec[:volumes] = volumes if volumes.any?
          spec[:hostNetwork] = true if host_network
          if node_selector == :affinity
            # Process with multiple runs_on groups — handled via find the process runs_on
            process = @config.app_config&.processes&.values&.find { |p| p.runs_on.is_a?(Array) && p.runs_on.length > 1 }
            if process
              spec[:affinity] = {
                nodeAffinity: {
                  requiredDuringSchedulingIgnoredDuringExecution: {
                    nodeSelectorTerms: [ {
                      matchExpressions: [ {
                        key: Naming::LABEL_SERVER_GROUP,
                        operator: "In",
                        values: process.runs_on.map(&:to_s)
                      } ]
                    } ]
                  }
                }
              }
            end
          elsif node_selector
            spec[:nodeSelector] = node_selector
          end

          {
            apiVersion: "apps/v1", kind: "Deployment",
            metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
            spec: {
              replicas:,
              selector: { matchLabels: { Naming::LABEL_APP => name } },
              template: { metadata: { labels: labels(name) }, spec: }
            }
          }
        end

        def service(name:, port:)
          {
            apiVersion: "v1", kind: "Service",
            metadata: { name:, namespace: NAMESPACE, labels: labels(name) },
            spec: { selector: { Naming::LABEL_APP => name }, ports: [ { port:, targetPort: port } ] }
          }
        end

        def secret(name:, data:)
          {
            apiVersion: "v1", kind: "Secret",
            metadata: { name:, namespace: NAMESPACE },
            type: "Opaque",
            data: data.transform_values { |v| Base64.strict_encode64(v.to_s) }
          }
        end

        def ingress(name:, hostname:, port:)
          {
            apiVersion: "networking.k8s.io/v1", kind: "Ingress",
            metadata: { name:, namespace: NAMESPACE, annotations: { "nginx.ingress.kubernetes.io/proxy-body-size" => "50m" } },
            spec: {
              ingressClassName: "nginx",
              rules: [ { host: hostname,
                        http: { paths: [ { path: "/", pathType: "Prefix",
                                          backend: { service: { name:, port: { number: port } } } } ] } } ]
            }
          }
        end

        def host_path_volume(name, path)
          { name:, hostPath: { path:, type: "DirectoryOrCreate" } }
        end

        def backup_manifests
          return [] unless @r2_credentials

          name = "#{@prefix}-postgres-backup"
          pg = @config.database_configs[:postgres]
          pg_user = pg.username || "app"
          pg_db = pg.database || "app"

          [
            secret(name: "#{name}-secret", data: {
              "AWS_ACCESS_KEY_ID" => @r2_credentials[:access_key_id],
              "AWS_SECRET_ACCESS_KEY" => @r2_credentials[:secret_access_key],
              "R2_ENDPOINT_URL" => @r2_credentials[:endpoint],
              "BUCKET" => @r2_credentials[:bucket],
              "PGHOST" => "#{@prefix}-postgres",
              "PGUSER" => pg_user,
              "PGPASSWORD" => @db_password,
              "PGDATABASE" => pg_db
            }),
            {
              apiVersion: "batch/v1", kind: "CronJob",
              metadata: { name:, namespace: NAMESPACE },
              spec: {
                schedule: "0 */6 * * *",
                concurrencyPolicy: "Forbid",
                successfulJobsHistoryLimit: 1,
                failedJobsHistoryLimit: 1,
                jobTemplate: {
                  spec: {
                    template: {
                      spec: {
                        restartPolicy: "OnFailure",
                        nodeSelector: { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP },
                        containers: [ {
                          name: "backup",
                          image: "postgres:16-alpine",
                          command: [ "/bin/sh", "-c" ],
                          args: [ backup_script ],
                          envFrom: [ { secretRef: { name: "#{name}-secret" } } ]
                        } ]
                      }
                    }
                  }
                }
              }
            }
          ]
        end

        def backup_script
          <<~SH.strip
            apk add --no-cache aws-cli &&
            TIMESTAMP=$(date +%Y%m%d-%H%M%S) &&
            pg_dump -h $PGHOST -U $PGUSER -d $PGDATABASE --no-owner --no-acl |
            gzip |
            aws s3 cp - s3://$BUCKET/backup-$TIMESTAMP.sql.gz --endpoint-url $R2_ENDPOINT_URL &&
            aws s3 ls s3://$BUCKET/ --endpoint-url $R2_ENDPOINT_URL |
            sort -r |
            tail -n +8 |
            awk '{print $4}' |
            xargs -I {} aws s3 rm s3://$BUCKET/{} --endpoint-url $R2_ENDPOINT_URL
          SH
        end
    end
  end
end
