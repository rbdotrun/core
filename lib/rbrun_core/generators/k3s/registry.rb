# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Registry
        private

          # Registry with S3 storage driver for R2.
          # Uses registry:3.0 which fixes R2 multipart upload error:
          # "InvalidPart: All non-trailing parts must have the same length"
          # See: https://github.com/distribution/distribution/pull/3940
          def registry_manifest
            return nil unless @r2_credentials

            secret_data = {
              "REGISTRY_STORAGE" => "s3",
              "REGISTRY_STORAGE_S3_ACCESSKEY" => @r2_credentials[:access_key_id],
              "REGISTRY_STORAGE_S3_SECRETKEY" => @r2_credentials[:secret_access_key],
              "REGISTRY_STORAGE_S3_REGION" => "auto",
              "REGISTRY_STORAGE_S3_BUCKET" => @r2_credentials[:bucket],
              "REGISTRY_STORAGE_S3_REGIONENDPOINT" => @r2_credentials[:endpoint],
              "REGISTRY_STORAGE_S3_ROOTDIRECTORY" => "/#{Naming::DOCKER_REGISTRY_PREFIX}",
              "REGISTRY_STORAGE_S3_FORCEPATHSTYLE" => "true",
              "REGISTRY_STORAGE_S3_CHUNKSIZE" => "33554432",
              "REGISTRY_HEALTH_STORAGEDRIVER_ENABLED" => "false",
              "REGISTRY_STORAGE_DELETE_ENABLED" => "true"
            }

            [
              secret(name: "registry-s3-secret", data: secret_data),
              {
                apiVersion: "apps/v1", kind: "Deployment",
                metadata: { name: "registry", namespace: NAMESPACE },
                spec: {
                  replicas: 1,
                  selector: { matchLabels: { app: "registry" } },
                  template: {
                    metadata: { labels: { app: "registry" } },
                    spec: {
                      nodeSelector: { Naming::LABEL_SERVER_GROUP => Naming::MASTER_GROUP },
                      containers: [ {
                        name: "registry",
                        image: "registry:3.0",
                        ports: [ { containerPort: 5000 } ],
                        envFrom: [ { secretRef: { name: "registry-s3-secret" } } ],
                        resources: {
                          requests: { memory: "128Mi", cpu: "50m" },
                          limits: { memory: "512Mi" }
                        }
                      } ]
                    }
                  }
                }
              },
              {
                apiVersion: "v1", kind: "Service",
                metadata: { name: "registry", namespace: NAMESPACE },
                spec: {
                  type: "NodePort",
                  selector: { app: "registry" },
                  ports: [ { port: 5000, targetPort: 5000, nodePort: 30_500 } ]
                }
              }
            ]
          end
      end
    end
  end
end
