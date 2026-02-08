# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Database
        private

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
            node_selector = node_selector_for(db_config.runs_on) ||
                            { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP }

            [
              secret(name: secret_name, data: { "DB_PASSWORD" => @db_password }),
              statefulset(
                name:,
                node_selector:,
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
              headless_service(name:, port: 5432)
            ]
          end
      end
    end
  end
end
