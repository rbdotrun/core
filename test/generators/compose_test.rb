# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Generators
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

      def test_includes_redis
        @config.database(:redis)
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
        @config.service(:meilisearch)
        compose = Compose.new(@config).generate

        assert_includes compose, "meilisearch"
      end

      def test_resolves_env_vars_for_sandbox
        @config.env(RAILS_ENV: { sandbox: "development", production: "production" })
        @config.app { |a| a.process(:web) { |p| p.port = 3000 } }
        compose = Compose.new(@config).generate

        assert_includes compose, "development"
      end
    end
  end
end
