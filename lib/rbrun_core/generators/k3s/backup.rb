# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Backup
        private

          def backup_manifests
            return [] unless @r2_credentials

            name = Naming.postgres_backup(@prefix)
            secret_name = Naming.secret_for(name)
            pg = @config.database_configs[:postgres]
            pg_user = pg.username || "app"
            pg_db = pg.database || "app"

            [
              secret(name: secret_name, data: {
                "AWS_ACCESS_KEY_ID" => @r2_credentials[:access_key_id],
                "AWS_SECRET_ACCESS_KEY" => @r2_credentials[:secret_access_key],
                "R2_ENDPOINT_URL" => @r2_credentials[:endpoint],
                "BUCKET" => @r2_credentials[:bucket],
                "PGHOST" => Naming.postgres(@prefix),
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
                            image: pg.image,
                            command: [ "/bin/sh", "-c" ],
                            args: [ backup_script ],
                            envFrom: [ { secretRef: { name: secret_name } } ]
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
            prefix = Naming::POSTGRES_BACKUPS_PREFIX
            <<~SH.strip
              apt-get update && apt-get install -y curl unzip &&
              curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip &&
              unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install &&
              TIMESTAMP=$(date +%Y%m%d-%H%M%S) &&
              pg_dump -h $PGHOST -U $PGUSER -d $PGDATABASE --no-owner --no-acl |
              gzip |
              aws s3 cp - s3://$BUCKET/#{prefix}backup-$TIMESTAMP.sql.gz --endpoint-url $R2_ENDPOINT_URL &&
              aws s3 ls s3://$BUCKET/#{prefix} --endpoint-url $R2_ENDPOINT_URL |
              sort -r |
              tail -n +8 |
              awk '{print $4}' |
              xargs -I {} aws s3 rm s3://$BUCKET/#{prefix}{} --endpoint-url $R2_ENDPOINT_URL
            SH
          end
      end
    end
  end
end
