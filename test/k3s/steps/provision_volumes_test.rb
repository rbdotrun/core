# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module K3s
    module Steps
      class ProvisionVolumesTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @ctx = build_context(target: :production)
          @ctx.server_ip = "1.2.3.4"
          @ctx.ssh_private_key = TEST_SSH_KEY.private_key
        end

        def test_needs_volumes_false_when_no_databases_or_mount_paths
          refute provision_volumes.send(:needs_volumes?)
        end

        def test_needs_volumes_true_when_database_configured
          @ctx.config.database(:postgres)

          assert provision_volumes.send(:needs_volumes?)
        end

        def test_needs_volumes_true_when_service_has_mount_path
          @ctx.config.service(:meilisearch) do |s|
            s.image = "getmeili/meilisearch:latest"
            s.mount_path = "/meili_data"
          end

          assert provision_volumes.send(:needs_volumes?)
        end

        def test_needs_volumes_false_when_service_without_mount_path
          @ctx.config.service(:redis) do |s|
            s.image = "redis:7-alpine"
          end

          refute provision_volumes.send(:needs_volumes?)
        end

        def test_services_with_mount_path_returns_true
          @ctx.config.service(:meilisearch) do |s|
            s.image = "getmeili/meilisearch:latest"
            s.mount_path = "/meili_data"
          end

          assert provision_volumes.send(:services_with_mount_path?)
        end

        def test_services_with_mount_path_returns_false
          @ctx.config.service(:redis) do |s|
            s.image = "redis:7-alpine"
          end

          refute provision_volumes.send(:services_with_mount_path?)
        end

        def test_find_service_server_returns_master_when_no_instance_type
          stub_server_lookup("testapp-production-master-1", id: 1)

          svc_config = Config::Service.new(:meilisearch)
          svc_config.mount_path = "/meili_data"

          server = provision_volumes.send(:find_service_server, :meilisearch, svc_config)

          assert_equal "1", server.id
        end

        def test_find_service_server_returns_dedicated_when_instance_type
          stub_server_lookup("testapp-production-meilisearch-1", id: 2)

          svc_config = Config::Service.new(:meilisearch)
          svc_config.mount_path = "/meili_data"
          svc_config.instance_type = "cx22"

          server = provision_volumes.send(:find_service_server, :meilisearch, svc_config)

          assert_equal "2", server.id
        end

        def test_find_service_server_raises_when_dedicated_not_found
          stub_server_not_found("testapp-production-meilisearch-1")

          svc_config = Config::Service.new(:meilisearch)
          svc_config.mount_path = "/meili_data"
          svc_config.instance_type = "cx22"

          error = assert_raises(Error::Standard) do
            provision_volumes.send(:find_service_server, :meilisearch, svc_config)
          end

          assert_match(/testapp-production-meilisearch-1 not found/, error.message)
        end

        private

          def provision_volumes
            ProvisionVolumes.new(@ctx)
          end

          def stub_server_lookup(name, id:)
            stub_request(:get, "https://api.hetzner.cloud/v1/servers?name=#{name}")
              .to_return(
                status: 200,
                body: {
                  servers: [{
                    id: id,
                    name: name,
                    public_net: { ipv4: { ip: "1.2.3.4" } },
                    datacenter: { location: { name: "hel1" } },
                    server_type: { name: "cx22" }
                  }]
                }.to_json,
                headers: { "Content-Type" => "application/json" }
              )
          end

          def stub_server_not_found(name)
            stub_request(:get, "https://api.hetzner.cloud/v1/servers?name=#{name}")
              .to_return(
                status: 200,
                body: { servers: [] }.to_json,
                headers: { "Content-Type" => "application/json" }
              )
          end
      end
    end
  end
end
