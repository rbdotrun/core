# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module RbrunCore
  module Config
    class LoaderTest < Minitest::Test
      def setup
        super
        @tmpdir = Dir.mktmpdir("loader-test")
      end

      def teardown
        FileUtils.rm_rf(@tmpdir)
        super
      end

      def test_loads_minimal_yaml
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml)

        assert_equal :production, config.target
        assert_equal "testapp", config.name
        assert_equal :hetzner, config.compute_config.provider_name
      end

      # ─── Target Configuration ───

      def test_raises_when_target_not_specified
        yaml = <<~YAML
          name: testapp
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        error = assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }

        assert_match(/target is required/, error.message)
      end

      def test_target_respects_staging_from_yaml
        yaml = <<~YAML
          name: testapp
          target: staging
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml)

        assert_equal :staging, config.target
      end

      def test_target_respects_custom_value_from_yaml
        yaml = <<~YAML
          name: testapp
          target: canary
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml)

        assert_equal :canary, config.target
      end

      def test_target_is_always_a_symbol
        yaml = <<~YAML
          name: testapp
          target: preview
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml)

        assert_kind_of Symbol, config.target
      end

      def test_interpolates_env_vars
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: ${HETZNER_TOKEN}
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml, env: { "HETZNER_TOKEN" => "interpolated-key" })

        assert_equal "interpolated-key", config.compute_config.api_key
      end

      def test_raises_for_missing_env_var
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: ${MISSING_VAR}
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
        YAML

        assert_raises(KeyError) { load_yaml(yaml, env: {}) }
      end

      def test_loads_master_with_count
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx21
              count: 3
        YAML

        config = load_yaml(yaml)

        assert_equal "cpx21", config.compute_config.master.instance_type
        assert_equal 3, config.compute_config.master.count
      end

      def test_loads_multi_server_config_enables_multi_server
        config = load_yaml(multi_server_yaml)

        assert_predicate config.compute_config, :multi_server?
      end

      def test_loads_multi_server_config_web_group
        config = load_yaml(multi_server_yaml)

        assert_equal 2, config.compute_config.servers[:web].count
        assert_equal "cpx21", config.compute_config.servers[:web].type
      end

      def test_loads_multi_server_config_worker_group
        config = load_yaml(multi_server_yaml)

        assert_equal 1, config.compute_config.servers[:worker].count
      end

      def test_raises_when_no_master
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
        YAML

        assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
      end

      def test_loads_databases
        config = load_yaml(database_yaml)

        assert config.database?(:postgres)
        assert_equal "pgvector/pgvector:pg17", config.database_configs[:postgres].image
      end

      def test_loads_database_credentials
        config = load_yaml(database_yaml)
        pg = config.database_configs[:postgres]

        assert_equal "myuser", pg.username
        assert_equal "mypassword", pg.password
        assert_equal "mydb", pg.database
      end

      def database_yaml
        <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          databases:
            postgres:
              image: pgvector/pgvector:pg17
              username: myuser
              password: mypassword
              database: mydb
        YAML
      end

      def test_database_requires_username
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          databases:
            postgres:
              password: mypassword
              database: mydb
        YAML

        err = assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
        assert_match(/username is required/, err.message)
      end

      def test_database_requires_password
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          databases:
            postgres:
              username: myuser
              database: mydb
        YAML

        err = assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
        assert_match(/password is required/, err.message)
      end

      def test_database_requires_database
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          databases:
            postgres:
              username: myuser
              password: mypassword
        YAML

        err = assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
        assert_match(/database is required/, err.message)
      end

      def test_rejects_redis_as_database
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          databases:
            redis: {}
        YAML

        assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
      end

      def test_loads_services_with_image
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          services:
            redis:
              image: redis:7-alpine
            meilisearch:
              image: getmeili/meilisearch:v1.6
              subdomain: search
              env:
                MEILI_MASTER_KEY: secret
        YAML

        config = load_yaml(yaml)

        assert config.service?(:redis)
        assert_equal "redis:7-alpine", config.service_configs[:redis].image
      end

      def test_loads_services_with_subdomain_and_env
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          services:
            meilisearch:
              image: getmeili/meilisearch:v1.6
              subdomain: search
              env:
                MEILI_MASTER_KEY: secret
        YAML

        config = load_yaml(yaml)

        assert_equal "search", config.service_configs[:meilisearch].subdomain
        assert_equal({ MEILI_MASTER_KEY: "secret" }, config.service_configs[:meilisearch].env)
      end

      def test_service_requires_image
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          services:
            redis: {}
        YAML

        assert_raises(RbrunCore::Error::Configuration) { load_yaml(yaml) }
      end

      def test_loads_app_dockerfile
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            dockerfile: Dockerfile.prod
            processes:
              web:
                port: 3000
        YAML

        config = load_yaml(yaml)

        assert_predicate config, :app?
        assert_equal "Dockerfile.prod", config.app_config.dockerfile
      end

      def test_loads_app_web_process
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                command: bin/rails server
                port: 3000
                subdomain: www
        YAML

        config = load_yaml(yaml)

        assert_equal 3000, config.app_config.processes[:web].port
        assert_equal "www", config.app_config.processes[:web].subdomain
      end

      def test_loads_app_worker_process
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              worker:
                command: bin/jobs
        YAML

        config = load_yaml(yaml)

        assert_equal "bin/jobs", config.app_config.processes[:worker].command
      end

      def test_loads_process_instance_type
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                command: bin/rails server
                port: 3000
                instance_type: cpx32
                replicas: 2
              worker:
                command: bin/jobs
                instance_type: cx23
        YAML

        config = load_yaml(yaml)

        assert_equal "cpx32", config.app_config.processes[:web].instance_type
        assert_equal 2, config.app_config.processes[:web].replicas
        assert_equal "cx23", config.app_config.processes[:worker].instance_type
      end

      def test_loads_service_instance_type
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          services:
            meilisearch:
              image: getmeili/meilisearch:v1.6
              port: 7700
              instance_type: cx22
              replicas: 2
        YAML

        config = load_yaml(yaml)

        assert_equal "cx22", config.service_configs[:meilisearch].instance_type
        assert_equal 2, config.service_configs[:meilisearch].replicas
      end

      def test_loads_process_setup
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                port: 80
                setup:
                  - rails db:prepare
                  - bundle exec rake imports:all
        YAML

        config = load_yaml(yaml)

        assert_equal [ "rails db:prepare", "bundle exec rake imports:all" ], config.app_config.processes[:web].setup
      end

      def test_raises_when_process_has_mount_path
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                port: 80
                mount_path: /data
        YAML

        error = assert_raises(Error::Configuration) { load_yaml(yaml) }
        assert_match(/cannot have mount_path/, error.message)
        assert_match(/web/, error.message)
      end

      def test_loads_env
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          env:
            RAILS_ENV: production
            SECRET_KEY_BASE: abc123
        YAML

        config = load_yaml(yaml)

        assert_equal "production", config.env_vars[:RAILS_ENV]
        assert_equal "abc123", config.env_vars[:SECRET_KEY_BASE]
      end

      def test_loads_cloudflare_config
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          cloudflare:
            api_token: cf-token
            account_id: cf-account
            domain: example.com
        YAML

        config = load_yaml(yaml)

        assert_predicate config, :cloudflare_configured?
        assert_equal "cf-token", config.cloudflare_config.api_token
        assert_equal "example.com", config.cloudflare_config.domain
      end

      def test_loads_claude_config
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          claude:
            auth_token: anthropic-key
        YAML

        config = load_yaml(yaml)

        assert_predicate config, :claude_configured?
        assert_equal "anthropic-key", config.claude_config.auth_token
      end

      def test_loads_process_replicas
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                command: bin/rails server
                port: 3000
                subdomain: www
                replicas: 3
              worker:
                command: bin/jobs
        YAML

        config = load_yaml(yaml)

        assert_equal 3, config.app_config.processes[:web].replicas
      end

      def test_process_effective_replicas_defaults_based_on_subdomain
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          app:
            processes:
              web:
                command: bin/rails server
                port: 3000
                subdomain: www
              worker:
                command: bin/jobs
        YAML

        config = load_yaml(yaml)

        assert_equal 2, config.app_config.processes[:web].effective_replicas
        assert_equal 1, config.app_config.processes[:worker].effective_replicas
      end

      def test_loads_aws_provider
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: aws
            access_key_id: AKIAIOSFODNN7EXAMPLE
            secret_access_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: t3.micro
        YAML

        config = load_yaml(yaml)

        assert_equal :aws, config.compute_config.provider_name
        assert_equal "t3.micro", config.compute_config.master.instance_type
      end

      def test_master_type_alias
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              type: cpx11
        YAML

        config = load_yaml(yaml)

        assert_equal "cpx11", config.compute_config.master.instance_type
      end

      # ─── Root Volume Size ───

      def test_scaleway_root_volume_size_defaults_to_20
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: scaleway
            api_key: test-key
            project_id: test-project
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: DEV1-S
        YAML

        config = load_yaml(yaml)

        assert_equal 20, config.compute_config.root_volume_size
      end

      def test_scaleway_root_volume_size_can_be_configured
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: scaleway
            api_key: test-key
            project_id: test-project
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            root_volume_size: 50
            master:
              instance_type: DEV1-S
        YAML

        config = load_yaml(yaml)

        assert_equal 50, config.compute_config.root_volume_size
      end

      def test_hetzner_raises_when_root_volume_size_specified
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            root_volume_size: 50
            master:
              instance_type: cpx11
        YAML

        config = load_yaml(yaml)
        err = assert_raises(RbrunCore::Error::Configuration) { config.compute_config.validate! }

        assert_match(/root_volume_size is not supported for Hetzner/, err.message)
      end

      # ─── Storage Configuration ───

      def test_loads_storage_buckets
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              public: true
            assets:
              public: false
        YAML

        config = load_yaml(yaml)

        assert_predicate config, :storage?
        assert_equal 2, config.storage_config.buckets.size
      end

      def test_loads_storage_bucket_public_option
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              public: true
        YAML

        config = load_yaml(yaml)

        assert config.storage_config.buckets[:uploads].public
      end

      def test_loads_storage_bucket_cors_config
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              cors:
                origins:
                  - https://example.com
                methods:
                  - GET
                  - PUT
        YAML

        config = load_yaml(yaml)

        bucket = config.storage_config.buckets[:uploads]

        assert_predicate bucket, :cors?
      end

      def test_loads_storage_bucket_cors_origins
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              cors:
                origins:
                  - https://example.com
                methods:
                  - GET
                  - PUT
        YAML

        config = load_yaml(yaml)

        cors = config.storage_config.buckets[:uploads].cors_config

        assert_equal [ "https://example.com" ], cors[:allowed_origins]
      end

      def test_loads_storage_bucket_cors_methods
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              cors:
                origins:
                  - https://example.com
                methods:
                  - GET
                  - PUT
        YAML

        config = load_yaml(yaml)

        cors = config.storage_config.buckets[:uploads].cors_config

        assert_equal %w[GET PUT], cors[:allowed_methods]
      end

      def test_loads_storage_bucket_cors_true_inferred
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              cors: true
        YAML

        config = load_yaml(yaml)

        bucket = config.storage_config.buckets[:uploads]

        assert_predicate bucket, :cors?
        assert_predicate bucket, :cors_inferred?
      end

      def test_loads_storage_bucket_no_cors
        yaml = <<~YAML
          name: testapp
          target: production
          compute:
            provider: hetzner
            api_key: test-key
            ssh_key_path: #{TEST_SSH_KEY_PATH}
            master:
              instance_type: cpx11
          storage:
            uploads:
              public: true
        YAML

        config = load_yaml(yaml)

        refute_predicate config.storage_config.buckets[:uploads], :cors?
      end

      private

        def load_yaml(yaml, env: {})
          path = File.join(@tmpdir, "config.yml")
          File.write(path, yaml)
          Loader.load(path, env:)
        end

        def multi_server_yaml
          <<~YAML
            target: production
            compute:
              provider: hetzner
              api_key: test-key
              ssh_key_path: #{TEST_SSH_KEY_PATH}
              master:
                instance_type: cpx21
              servers:
                web:
                  type: cpx21
                  count: 2
                worker:
                  type: cpx11
                  count: 1
          YAML
        end
    end
  end
end
