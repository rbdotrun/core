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

      def test_generates_node_selector_for_process_runs_on
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.runs_on = %i[web]
          end
        end
        manifests = K3s.new(@config, prefix: "myapp", zone: "example.com",
                                     registry_tag: "localhost:5000/app:v1").generate

        assert_includes manifests, RbrunCore::Naming::LABEL_SERVER_GROUP
        assert_includes manifests, "web"
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

      def test_app_process_includes_resource_limits
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.subdomain = "www"
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com", registry_tag: "localhost:5000/app:v1")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }
        container = web_deploy["spec"]["template"]["spec"]["containers"].first

        assert container["resources"], "Container should have resources"
        assert container["resources"]["requests"]["memory"]
        assert container["resources"]["limits"]["memory"]
      end

      def test_database_includes_resource_limits
        @config.database(:postgres)
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com", db_password: "pw")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact
        pg_sts = parsed.find { |r| r["kind"] == "StatefulSet" && r["metadata"]["name"] == "myapp-postgres" }
        container = pg_sts["spec"]["template"]["spec"]["containers"].first

        assert container["resources"], "Postgres container should have resources"
        assert container["resources"]["requests"]["memory"]
        assert container["resources"]["limits"]["memory"]
      end

      def test_database_gets_larger_allocation_than_app
        @config.database(:postgres)
        @config.app do |a|
          a.process(:web) do |p|
            p.port = 3000
            p.subdomain = "www"
          end
        end
        gen = K3s.new(@config, prefix: "myapp", zone: "example.com",
                               registry_tag: "localhost:5000/app:v1", db_password: "pw")
        manifests = gen.generate
        parsed = YAML.load_stream(manifests).compact

        pg_sts = parsed.find { |r| r["kind"] == "StatefulSet" && r["metadata"]["name"] == "myapp-postgres" }
        web_deploy = parsed.find { |r| r["kind"] == "Deployment" && r["metadata"]["name"] == "myapp-web" }

        pg_mem = pg_sts["spec"]["template"]["spec"]["containers"].first["resources"]["limits"]["memory"]
        web_mem = web_deploy["spec"]["template"]["spec"]["containers"].first["resources"]["limits"]["memory"]

        pg_value = pg_mem.gsub("Mi", "").to_i
        web_value = web_mem.gsub("Mi", "").to_i

        assert_operator pg_value, :>, web_value, "Postgres should get more memory than web"
      end
    end
  end
end
