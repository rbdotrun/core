# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Sandbox
    class ComposeTest < Minitest::Test
      def setup
        super
        @config = build_config
      end

      def test_generates_valid_yaml
        compose = Compose.new(@config).generate
        parsed = YAML.safe_load(compose)

        assert_kind_of Hash, parsed
      end

      def test_includes_postgres
        @config.database(:postgres)
        compose = Compose.new(@config).generate

        assert_includes compose, "postgres"
      end

      def test_includes_redis_as_service
        @config.service(:redis) { |s| s.image = "redis:7-alpine" }
        compose = Compose.new(@config).generate

        assert_includes compose, "redis"
      end

      def test_includes_app_processes
        @config.app do |a|
          a.process(:web) do |p|
            p.command = "bin/rails server"
            p.port = 3000
          end
          a.process(:worker) { |p| p.command = "bin/jobs" }
        end
        compose = Compose.new(@config).generate

        assert_includes compose, "web"
        assert_includes compose, "worker"
      end

      def test_includes_platform_services
        @config.service(:meilisearch) { |s| s.image = "getmeili/meilisearch:latest" }
        compose = Compose.new(@config).generate

        assert_includes compose, "meilisearch"
      end

      def test_scalar_env_vars
        @config.env(RAILS_ENV: "development")
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        compose = Compose.new(@config).generate

        assert_includes compose, "development"
      end

      def test_process_env_merges_with_global
        @config.env(RAILS_ENV: "development")
        @config.app do |a|
          a.process(:worker) do |p|
            p.command = "bin/jobs"
            p.env = { "QUEUE" => "critical" }
          end
        end
        compose = Compose.new(@config).generate
        parsed = YAML.safe_load(compose)

        worker_env = parsed["services"]["worker"]["environment"]

        assert_equal "critical", worker_env["QUEUE"]
        assert_equal "development", worker_env["RAILS_ENV"]
      end
    end
  end
end
