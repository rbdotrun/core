# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Kamal
      class ConfigBuilderTest < Minitest::Test
        def setup
          super
          @config = build_config(target: :production)
          @servers = {
            "myapp-kamal-web-1" => { id: 1, ip: "10.0.0.1", private_ip: "10.0.1.1", role: :web }
          }
        end

        def test_generates_valid_deploy_yml
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_equal "testapp", deploy["service"]
          assert_equal "testapp", deploy["image"]
          assert_equal({ "arch" => "amd64" }, deploy["builder"])
          assert_equal({ "user" => "root" }, deploy["ssh"])
        end

        def test_servers_section_uses_public_ips
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_equal({ "web" => { "hosts" => [ "10.0.0.1" ] } }, deploy["servers"])
        end

        def test_proxy_section_has_ssl_and_domain
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_equal true, deploy["proxy"]["ssl"]
          assert_equal "app.test.dev", deploy["proxy"]["host"]
          assert_equal 80, deploy["proxy"]["app_port"]
        end

        def test_registry_defaults_to_ghcr
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_equal "ghcr.io", deploy["registry"]["server"]
        end

        def test_env_section_includes_rails_env
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_equal "production", deploy["env"]["clear"]["RAILS_ENV"]
          assert_includes deploy["env"]["secret"], "RAILS_MASTER_KEY"
        end

        def test_accessories_section_when_postgres_configured
          @config.database(:postgres) do |db|
            db.username = "app"
            db.database = "app"
          end

          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert deploy["accessories"]
          assert deploy["accessories"]["db"]
          assert_equal "postgres:17", deploy["accessories"]["db"]["image"]
        end

        def test_no_accessories_when_no_postgres
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          deploy = builder.to_deploy_yml

          assert_nil deploy["accessories"]
        end

        def test_to_yaml_returns_string
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          yaml = builder.to_yaml

          assert_kind_of String, yaml
          assert_includes yaml, "service: testapp"
        end

        def test_to_secrets_contains_registry_password
          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          secrets = builder.to_secrets

          assert_includes secrets, "KAMAL_REGISTRY_PASSWORD"
          assert_includes secrets, "RAILS_MASTER_KEY"
        end

        def test_to_secrets_includes_database_password_when_postgres
          @config.database(:postgres)

          builder = ConfigBuilder.new(config: @config, servers: @servers, domain: "app.test.dev")

          secrets = builder.to_secrets

          assert_includes secrets, "DATABASE_PASSWORD="
        end

        def test_multiple_servers
          servers = {
            "web-1" => { id: 1, ip: "10.0.0.1", private_ip: "10.0.1.1", role: :web },
            "web-2" => { id: 2, ip: "10.0.0.2", private_ip: "10.0.1.2", role: :web }
          }

          builder = ConfigBuilder.new(config: @config, servers:, domain: "app.test.dev")

          deploy = builder.to_deploy_yml
          hosts = deploy["servers"]["web"]["hosts"]

          assert_equal 2, hosts.size
          assert_includes hosts, "10.0.0.1"
          assert_includes hosts, "10.0.0.2"
        end
      end
    end
end
