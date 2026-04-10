# frozen_string_literal: true

module RbrunCore
  module Generators
    class K3s
      module ImagePrune
        private

          def image_prune_manifests
            [
              image_prune_cronjob
            ]
          end

          def image_prune_cronjob
            {
              apiVersion: "batch/v1",
              kind: "CronJob",
              metadata: { name: image_prune_name, namespace: NAMESPACE },
              spec: image_prune_cronjob_spec
            }
          end

          def image_prune_cronjob_spec
            {
              schedule: "30 3 * * *",
              concurrencyPolicy: "Forbid",
              successfulJobsHistoryLimit: 1,
              failedJobsHistoryLimit: 1,
              jobTemplate: { spec: { template: { spec: image_prune_pod_spec } } }
            }
          end

          def image_prune_pod_spec
            {
              hostPID: true,
              restartPolicy: "OnFailure",
              nodeSelector: master_node_selector,
              containers: [
                image_prune_container
              ]
            }
          end

          def image_prune_container
            {
              name: "prune",
              image: "alpine:3.20",
              command: [ "/bin/sh", "-c" ],
              args: [ image_prune_script ],
              securityContext: { privileged: true },
              resources: { limits: { memory: "64Mi" } }
            }
          end

          def image_prune_script
            keep = @config.app? ? @config.app_config.keep_images : Config::App::DEFAULT_KEEP_IMAGES
            image_prefix = "localhost:30500/#{@prefix}"
            <<~SH.strip
              nsenter -t 1 -m -u -i -n -- /bin/sh -c '
                PREFIX="#{image_prefix}"
                KEEP=#{keep}
                TAGS=$(k3s crictl images 2>/dev/null | grep "$PREFIX" | awk "{print \\$2}" | grep -v "^<none>$" | sort -r)
                COUNT=$(echo "$TAGS" | grep -c . || true)
                if [ "$COUNT" -le "$KEEP" ]; then
                  echo "Only $COUNT images, keeping all (threshold: $KEEP)"
                  exit 0
                fi
                REMOVE=$(echo "$TAGS" | tail -n +$((KEEP + 1)))
                for TAG in $REMOVE; do
                  echo "Removing ${PREFIX}:${TAG}"
                  k3s crictl rmi "${PREFIX}:${TAG}" 2>/dev/null || true
                done
                echo "Done. Kept $KEEP most recent, removed $((COUNT - KEEP))"
              '
            SH
          end

          def image_prune_name
            Naming.image_prune(@prefix)
          end
      end
    end
  end
end
