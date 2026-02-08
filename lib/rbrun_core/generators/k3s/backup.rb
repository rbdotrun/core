# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module Backup
        private

          def backup_manifests
            return [] unless @r2_credentials

            [
              backup_secret,
              backup_cronjob
            ]
          end

          def backup_secret
            secret(name: backup_secret_name, data: backup_secret_data)
          end

          def backup_secret_data
            {
              "AWS_ACCESS_KEY_ID" => @r2_credentials[:access_key_id],
              "AWS_SECRET_ACCESS_KEY" => @r2_credentials[:secret_access_key],
              "R2_ENDPOINT_URL" => @r2_credentials[:endpoint],
              "BUCKET" => @r2_credentials[:bucket],
              "PGHOST" => postgres_name,
              "PGUSER" => backup_pg_user,
              "PGPASSWORD" => @db_password,
              "PGDATABASE" => backup_pg_database
            }
          end

          def backup_cronjob
            {
              apiVersion: "batch/v1",
              kind: "CronJob",
              metadata: { name: backup_name, namespace: NAMESPACE },
              spec: backup_cronjob_spec
            }
          end

          def backup_cronjob_spec
            {
              schedule: "0 */6 * * *",
              concurrencyPolicy: "Forbid",
              successfulJobsHistoryLimit: 1,
              failedJobsHistoryLimit: 1,
              jobTemplate: { spec: { template: { spec: backup_pod_spec } } }
            }
          end

          def backup_pod_spec
            {
              restartPolicy: "OnFailure",
              nodeSelector: master_node_selector,
              containers: [
                backup_container
              ]
            }
          end

          def backup_container
            {
              name: "backup",
              image: backup_pg_config.image,
              command: [ "/bin/sh", "-c" ],
              args: [ backup_script ],
              envFrom: [ { secretRef: { name: backup_secret_name } } ]
            }
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

          def backup_name
            Naming.postgres_backup(@prefix)
          end

          def backup_secret_name
            Naming.secret_for(backup_name)
          end

          def backup_pg_config
            @config.database_configs[:postgres]
          end

          def backup_pg_user
            backup_pg_config.username || "app"
          end

          def backup_pg_database
            backup_pg_config.database || "app"
          end
      end
    end
  end
end
