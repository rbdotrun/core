# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Database
        private

          def database_manifests
            @config.database_configs.flat_map do |type, db_config|
              case type
              when :postgres
                postgres_manifests(db_config)
              else
                []
              end
            end
          end

          def postgres_manifests(db_config)
            [
              postgres_secret,
              postgres_statefulset(db_config),
              postgres_service
            ]
          end

          def postgres_secret
            secret(
              name: postgres_secret_name,
              data: { "DB_PASSWORD" => @db_password }
            )
          end

          def postgres_statefulset(db_config)
            statefulset(
              name: postgres_name,
              node_selector: postgres_node_selector(db_config),
              containers: [ postgres_container(db_config) ],
              volumes: [ postgres_volume ]
            )
          end

          def postgres_container(db_config)
            container = {
              name: "postgres",
              image: db_config.image,
              ports: [ { containerPort: 5432 } ],
              env: postgres_env(db_config),
              volumeMounts: [ { name: "data", mountPath: "/var/lib/postgresql/data" } ],
              readinessProbe: postgres_readiness_probe(db_config)
            }

            allocation = @allocations["postgres"]
            container[:resources] = allocation.to_kubernetes if allocation

            container
          end

          def postgres_env(db_config)
            [
              { name: "POSTGRES_USER", value: postgres_user(db_config) },
              { name: "POSTGRES_DB", value: postgres_database(db_config) },
              {
                name: "POSTGRES_PASSWORD",
                valueFrom: {
                  secretKeyRef: { name: postgres_secret_name, key: "DB_PASSWORD" }
                }
              },
              { name: "PGDATA", value: "/var/lib/postgresql/data/pgdata" }
            ]
          end

          def postgres_readiness_probe(db_config)
            {
              exec: {
                command: [ "pg_isready", "-U", postgres_user(db_config) ]
              },
              initialDelaySeconds: 5,
              periodSeconds: 5
            }
          end

          def postgres_volume
            host_path_volume("data", "/mnt/data/#{postgres_name}")
          end

          def postgres_service
            headless_service(name: postgres_name, port: 5432)
          end

          def postgres_node_selector(_db_config)
            master_node_selector
          end

          def postgres_name
            Naming.postgres(@prefix)
          end

          def postgres_secret_name
            Naming.secret_for(postgres_name)
          end

          def postgres_user(db_config)
            db_config.username || "app"
          end

          def postgres_database(db_config)
            db_config.database || "app"
          end

          def master_node_selector
            { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP }
          end
      end
    end
  end
end
