# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Generators
    class K3sTest < Minitest::Test
      def setup
        super
        @config = build_config
      end

      def test_generates_meilisearch_url
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
        end
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        assert_includes manifests, "MEILISEARCH_URL"
        assert_includes manifests, Base64.strict_encode64("http://test-meilisearch:7700")
      end

      def test_generates_redis_url
        @config.service(:redis) do |s|
          s.image = "redis:7-alpine"
          s.port = 6379
        end
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        assert_includes manifests, "REDIS_URL"
        assert_includes manifests, Base64.strict_encode64("redis://test-redis:6379")
      end

      def test_creates_per_service_secret
        @config.service(:meilisearch) do |m|
          m.image = "getmeili/meilisearch:latest"
          m.port = 7700
          m.env = { MEILI_MASTER_KEY: "secret123" }
        end
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        assert_includes manifests, "test-meilisearch-secret"
      end

      def test_no_service_secret_when_no_env
        @config.service(:redis) { |s| s.image = "redis:7-alpine" }
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        refute_includes manifests, "test-redis-secret"
      end

      def test_service_with_mount_path_gets_volume
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
          s.mount_path = "/meili_data"
        end
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        assert_includes manifests, "volumeMounts"
        assert_includes manifests, "/meili_data"
        assert_includes manifests, "/mnt/data/test-meilisearch"
      end

      def test_service_with_mount_path_uses_statefulset
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
          s.mount_path = "/meili_data"
        end
        gen = K3s.new(@config, prefix: "test", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        meili = parsed.find { |r| r["metadata"]["name"] == "test-meilisearch" && r["kind"] }

        assert_equal "StatefulSet", meili["kind"]
      end

      def test_service_with_mount_path_uses_headless_service
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
          s.mount_path = "/meili_data"
        end
        gen = K3s.new(@config, prefix: "test", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        svc = parsed.find { |r| r["kind"] == "Service" && r["metadata"]["name"] == "test-meilisearch" }

        assert_equal "None", svc["spec"]["clusterIP"]
      end

      def test_service_with_mount_path_and_instance_type_uses_dedicated_node
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
          s.mount_path = "/meili_data"
          s.instance_type = "cx22"
        end
        gen = K3s.new(@config, prefix: "test", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        meili = parsed.find { |r| r["metadata"]["name"] == "test-meilisearch" && r["kind"] == "StatefulSet" }

        assert_equal "StatefulSet", meili["kind"]
        assert_equal "meilisearch", meili.dig("spec", "template", "spec", "nodeSelector", "rb.run/server-group")
      end

      def test_service_with_mount_path_without_instance_type_uses_master
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:latest"
          s.port = 7700
          s.mount_path = "/meili_data"
        end
        gen = K3s.new(@config, prefix: "test", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        meili = parsed.find { |r| r["metadata"]["name"] == "test-meilisearch" && r["kind"] == "StatefulSet" }

        assert_equal "StatefulSet", meili["kind"]
        assert_equal "master", meili.dig("spec", "template", "spec", "nodeSelector", "rb.run/server-group")
      end

      def test_service_without_mount_path_uses_deployment
        @config.service(:redis) do |s|
          s.image = "redis:7-alpine"
          s.port = 6379
        end
        gen = K3s.new(@config, prefix: "test", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        redis = parsed.find { |r| r["metadata"]["name"] == "test-redis" && r["kind"] }

        assert_equal "Deployment", redis["kind"]
      end

      def test_service_without_mount_path_has_no_volume
        @config.service(:custom) { |s| s.image = "custom:latest" }
        manifests = K3s.new(@config, prefix: "test", zone: "example.com").generate

        refute_includes manifests, "volumeMounts"
        refute_includes manifests, "/mnt/data/test-custom"
      end

      def test_generates_database_url_for_postgres
        @config.database(:postgres)
        manifests = K3s.new(@config, prefix: "app", zone: "example.com",
                                     db_password: "testpw").generate

        assert_includes manifests, Base64.strict_encode64("postgresql://app:testpw@app-postgres:5432/app")
      end

      def test_uses_custom_username_and_database
        @config.database(:postgres) do |db|
          db.username = "insiti"
          db.database = "insiti_production"
        end
        manifests = K3s.new(@config, prefix: "app", zone: "example.com",
                                     db_password: "secret").generate

        assert_includes manifests,
                        Base64.strict_encode64("postgresql://insiti:secret@app-postgres:5432/insiti_production")
      end

      def test_generates_postgres_env_vars
        @config.database(:postgres)
        manifests = K3s.new(@config, prefix: "app", zone: "example.com",
                                     db_password: "pw").generate

        %w[POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB POSTGRES_PORT].each do |var|
          assert_includes manifests, var
        end
      end

      def test_generates_web_deployment
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com",
                                     registry_tag: "localhost:5000/app:v1").generate

        assert_includes manifests, "myapp-web"
        assert_includes manifests, "containerPort: 3000"
      end

      def test_generates_worker_deployment
        @config.app { |a| a.process(:worker) { |p| p.command = "bin/jobs" } }
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com",
                                     registry_tag: "localhost:5000/app:v1").generate

        assert_includes manifests, "myapp-worker"
        assert_includes manifests, "bin/jobs"
      end

      def test_generates_ingress
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.subdomain = "app"
          end
        end
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com",
                                     registry_tag: "localhost:5000/app:v1").generate

        assert_includes manifests, "kind: Ingress"
        assert_includes manifests, "host: app.example.com"
      end

      def test_generates_cloudflared_with_tunnel_token
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com",
                                     tunnel_token: "cf-token-123").generate

        assert_includes manifests, "myapp-cloudflared"
        assert_includes manifests, "hostNetwork: true"
      end

      def test_no_cloudflared_without_tunnel_token
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com").generate

        refute_includes manifests, "cloudflared"
      end

      def test_process_deployment_uses_custom_replicas
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.replicas = 3
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        assert_equal 3, web_deploy["spec"]["replicas"]
      end

      def test_database_statefulset_stays_at_one_replica
        @config.database(:postgres)
        gen = K3s.new(@config, prefix: "app", zone: "example.com", db_password: "pw")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        pg_sts = parsed.find { |r| r["kind"] == "StatefulSet" && r["metadata"]["name"] == "app-postgres" }

        assert_equal 1, pg_sts["spec"]["replicas"]
      end

      def test_database_uses_headless_service
        @config.database(:postgres)
        gen = K3s.new(@config, prefix: "app", zone: "example.com", db_password: "pw")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        pg_svc = parsed.find { |r| r["kind"] == "Service" && r["metadata"]["name"] == "app-postgres" }

        assert_equal "None", pg_svc["spec"]["clusterIP"]
      end

      def test_database_always_runs_on_master
        @config.database(:postgres)
        manifests = K3s.new(@config, prefix: "app", zone: "example.com",
                                     db_password: "pw").generate

        assert_includes manifests, RbrunCore::Naming::LABEL_SERVER_GROUP
        assert_includes manifests, RbrunCore::Naming::MASTER_GROUP
      end

      def test_generates_process_env
        @config.app do |a|
          a.process(:worker) do |p|
            p.command = "bin/jobs"
            p.env = { "QUEUE" => "critical", "THREADS" => "10" }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        worker_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-worker" }
        container = worker_deploy["spec"]["template"]["spec"]["containers"].first

        assert container["env"]
        env_names = container["env"].map { |e| e["name"] }

        assert_includes env_names, "QUEUE"
        assert_includes env_names, "THREADS"
      end

      # ─── Storage Credentials ───

      def test_injects_storage_credentials
        storage_credentials = {
          uploads: {
            bucket: "myapp-production-uploads",
            access_key_id: "AKID123",
            secret_access_key: "SECRET456",
            endpoint: "https://account.r2.cloudflarestorage.com",
            region: "auto"
          }
        }
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               storage_credentials:)
        manifests = gen.generate

        assert_includes manifests, Base64.strict_encode64("myapp-production-uploads")
        assert_includes manifests, "STORAGE_UPLOADS_BUCKET"
      end

      def test_injects_storage_access_key
        storage_credentials = {
          uploads: {
            bucket: "myapp-production-uploads",
            access_key_id: "AKID123",
            secret_access_key: "SECRET456",
            endpoint: "https://account.r2.cloudflarestorage.com",
            region: "auto"
          }
        }
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               storage_credentials:)
        manifests = gen.generate

        assert_includes manifests, "STORAGE_UPLOADS_ACCESS_KEY_ID"
        assert_includes manifests, Base64.strict_encode64("AKID123")
      end

      def test_injects_multiple_storage_buckets
        storage_credentials = {
          uploads: {
            bucket: "myapp-production-uploads",
            access_key_id: "AKID",
            secret_access_key: "SECRET",
            endpoint: "https://r2.com",
            region: "auto"
          },
          assets: {
            bucket: "myapp-production-assets",
            access_key_id: "AKID",
            secret_access_key: "SECRET",
            endpoint: "https://r2.com",
            region: "auto"
          }
        }
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               storage_credentials:)
        manifests = gen.generate

        assert_includes manifests, "STORAGE_UPLOADS_BUCKET"
        assert_includes manifests, "STORAGE_ASSETS_BUCKET"
      end

      def test_master_workloads_have_memory_limits
        @config.database(:postgres)
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com", db_password: "pw",
                               r2_credentials: { bucket: "b", access_key_id: "a", secret_access_key: "s", endpoint: "e" },
                               tunnel_token: "token")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        pg_sts = parsed.find { |r| r["kind"] == "StatefulSet" && r["metadata"]["name"] == "myapp-postgres" }
        registry = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "registry" }
        tunnel = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-cloudflared" }

        assert_equal "2Gi", pg_sts["spec"]["template"]["spec"]["containers"].first["resources"]["limits"]["memory"]
        assert_equal "512Mi", registry["spec"]["template"]["spec"]["containers"].first["resources"]["limits"]["memory"]
        assert_equal "256Mi", tunnel["spec"]["template"]["spec"]["containers"].first["resources"]["limits"]["memory"]
      end

      # ── Instance Type Node Selector ──

      def test_generates_node_selector_for_process_instance_type
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.instance_type = "cpx32"
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        node_selector = web_deploy["spec"]["template"]["spec"]["nodeSelector"]

        assert_equal "web", node_selector[RbrunCore::Naming::LABEL_SERVER_GROUP]
      end

      def test_generates_node_selector_for_service_instance_type
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:v1.6"
          s.port = 7700
          s.instance_type = "cx22"
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        meili_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-meilisearch" }

        node_selector = meili_deploy["spec"]["template"]["spec"]["nodeSelector"]

        assert_equal "meilisearch", node_selector[RbrunCore::Naming::LABEL_SERVER_GROUP]
      end

      def test_generates_anti_affinity_for_dedicated_nodes
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.instance_type = "cpx32"
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        affinity = web_deploy["spec"]["template"]["spec"]["affinity"]

        assert affinity, "Deployment with instance_type should have affinity"
        assert affinity["podAntiAffinity"], "Should have podAntiAffinity"
      end

      def test_service_uses_effective_replicas
        @config.service(:meilisearch) do |s|
          s.image = "getmeili/meilisearch:v1.6"
          s.port = 7700
          s.instance_type = "cx22"
          s.replicas = 2
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        meili_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-meilisearch" }

        assert_equal 2, meili_deploy["spec"]["replicas"]
      end

      def test_tunnel_has_no_anti_affinity
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com", tunnel_token: "token123")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        tunnel = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-cloudflared" }

        affinity = tunnel["spec"]["template"]["spec"]["affinity"]
        refute affinity, "Tunnel should not have anti-affinity"
      end

      def test_process_without_instance_type_has_no_anti_affinity
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com", registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        affinity = web_deploy["spec"]["template"]["spec"]["affinity"]
        refute affinity, "Process without instance_type should not have anti-affinity"
      end

      def test_service_without_instance_type_has_no_anti_affinity
        @config.service(:redis) do |s|
          s.image = "redis:7-alpine"
          s.port = 6379
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        redis_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-redis" }

        affinity = redis_deploy["spec"]["template"]["spec"]["affinity"]
        refute affinity, "Service without instance_type should not have anti-affinity"
      end

      # ── Image Prune CronJob ──

      def test_generates_image_prune_cronjob_when_app_configured
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        gen = K3s.new(@config, prefix: "myapp-staging", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        cronjob = parsed.find { |r| r["kind"] == "CronJob" && r["metadata"]["name"] == "myapp-staging-image-prune" }

        assert cronjob, "Should generate image prune CronJob"
        assert_equal "30 3 * * *", cronjob["spec"]["schedule"]
        assert_equal "Forbid", cronjob["spec"]["concurrencyPolicy"]
      end

      def test_image_prune_runs_on_master_node
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        gen = K3s.new(@config, prefix: "myapp-staging", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        cronjob = parsed.find { |r| r["kind"] == "CronJob" && r["metadata"]["name"] == "myapp-staging-image-prune" }

        pod_spec = cronjob.dig("spec", "jobTemplate", "spec", "template", "spec")

        assert_equal "master", pod_spec["nodeSelector"][RbrunCore::Naming::LABEL_SERVER_GROUP]
      end

      def test_image_prune_uses_host_pid_and_privileged
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        gen = K3s.new(@config, prefix: "myapp-staging", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        cronjob = parsed.find { |r| r["kind"] == "CronJob" && r["metadata"]["name"] == "myapp-staging-image-prune" }

        pod_spec = cronjob.dig("spec", "jobTemplate", "spec", "template", "spec")
        container = pod_spec["containers"].first

        assert pod_spec["hostPID"], "Pod should have hostPID enabled"
        assert container["securityContext"]["privileged"], "Container should be privileged"
      end

      def test_image_prune_uses_default_keep_count
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        gen = K3s.new(@config, prefix: "myapp-staging", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate

        assert_includes manifests, "KEEP=3"
        assert_includes manifests, "localhost:30500/myapp-staging"
      end

      def test_image_prune_respects_custom_keep_count
        @config.app do |a|
          a.keep_images = 5
          a.process(:web) { |p| p.port = 3000 }
        end
        gen = K3s.new(@config, prefix: "myapp-staging", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate

        assert_includes manifests, "KEEP=5"
      end

      def test_no_image_prune_without_app
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com")
        manifests = gen.generate

        refute_includes manifests, "image-prune"
      end

      # ── Process Resource Limits ──

      def test_process_with_resources_sets_limits_and_requests
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.resources = { "memory" => "1536Mi", "cpu" => "1" }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }
        container = web_deploy["spec"]["template"]["spec"]["containers"].first

        assert_equal "1536Mi", container["resources"]["limits"]["memory"]
        assert_equal "1", container["resources"]["limits"]["cpu"]
        assert_equal "1536Mi", container["resources"]["requests"]["memory"]
        assert_equal "1", container["resources"]["requests"]["cpu"]
      end

      def test_process_with_memory_only_resources
        @config.app do |a|
          a.process(:worker) do |p|
            p.command = "bin/jobs"
            p.resources = { "memory" => "512Mi" }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        worker_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-worker" }
        container = worker_deploy["spec"]["template"]["spec"]["containers"].first

        assert_equal "512Mi", container["resources"]["limits"]["memory"]
        refute container["resources"]["limits"].key?("cpu")
      end

      def test_process_without_resources_has_no_limits
        @config.app do |a|
          a.process(:web) { |p| p.port = 3000 }
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }
        container = web_deploy["spec"]["template"]["spec"]["containers"].first

        refute container.key?("resources")
      end

      # ── rolling_update strategy ─────────────────────────────────────

      def test_process_without_rolling_update_emits_default_strategy
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        parsed = YAML.load_stream(gen.generate).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }
        strategy = web_deploy["spec"]["strategy"]

        # Backward-compat: identical to pre-change manifest — type only, no rollingUpdate block.
        assert_equal "RollingUpdate", strategy["type"]
        refute strategy.key?("rollingUpdate"),
               "expected no rollingUpdate block when rolling_update is unset (K8s applies defaults)"
      end

      def test_process_with_rolling_update_sets_strategy_block
        @config.app do |a|
          a.process(:system) do |p|
            p.port = 3000
            p.rolling_update = { "max_surge" => 0, "max_unavailable" => 1 }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        parsed = YAML.load_stream(gen.generate).compact
        deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-system" }
        strategy = deploy["spec"]["strategy"]

        assert_equal "RollingUpdate", strategy["type"]
        assert_equal 0, strategy["rollingUpdate"]["maxSurge"]
        assert_equal 1, strategy["rollingUpdate"]["maxUnavailable"]
      end

      def test_process_rolling_update_accepts_symbol_keys
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.rolling_update = { max_surge: 2, max_unavailable: 0 }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        parsed = YAML.load_stream(gen.generate).compact
        deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        assert_equal 2, deploy["spec"]["strategy"]["rollingUpdate"]["maxSurge"]
        assert_equal 0, deploy["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"]
      end

      def test_process_rolling_update_accepts_percentage_strings
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.rolling_update = { "max_surge" => "50%", "max_unavailable" => "25%" }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        parsed = YAML.load_stream(gen.generate).compact
        deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        assert_equal "50%", deploy["spec"]["strategy"]["rollingUpdate"]["maxSurge"]
        assert_equal "25%", deploy["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"]
      end

      def test_process_rolling_update_partial_omits_missing_keys
        @config.app do |a|
          a.process(:worker) do |p|
            p.command = "bin/jobs"
            p.rolling_update = { "max_surge" => 0 }
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1")
        parsed = YAML.load_stream(gen.generate).compact
        deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-worker" }
        ru = deploy["spec"]["strategy"]["rollingUpdate"]

        assert_equal 0, ru["maxSurge"]
        refute ru.key?("maxUnavailable"), "expected K8s to apply its own default when key is omitted"
      end
    end
  end
end
