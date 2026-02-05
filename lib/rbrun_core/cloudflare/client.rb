# frozen_string_literal: true

require "securerandom"

module RbrunCore
  module Cloudflare
    class Client < RbrunCore::BaseClient
      BASE_URL = "https://api.cloudflare.com/client/v4"

      attr_reader :account_id

      def initialize(api_token:, account_id:)
        @api_token = api_token
        @account_id = account_id
        raise RbrunCore::Error, "Cloudflare API token not configured" if @api_token.nil? || @api_token.empty?
        raise RbrunCore::Error, "Cloudflare account ID not configured" if @account_id.nil? || @account_id.empty?

        super(timeout: 60, open_timeout: 10)
      end

      def token_id
        @token_id ||= get("/user/tokens/verify").dig("result", "id")
      end

      # Zones
      def find_zone(domain)
        response = get("/zones", name: domain)
        response.dig("result", 0)
      end

      def get_zone_id(domain)
        zone = find_zone(domain)
        raise RbrunCore::Error, "Zone not found for domain: #{domain}" unless zone

        zone["id"]
      end

      def list_zones
        response = get("/zones")
        (response["result"] || []).map { |z| { id: z["id"], name: z["name"], status: z["status"] } }
      end

      # Tunnels
      def find_or_create_tunnel(name)
        existing = find_tunnel(name)
        return existing if existing

        secret = SecureRandom.base64(32)
        response = post("/accounts/#{@account_id}/cfd_tunnel", {
                          name:, tunnel_secret: secret, config_src: "cloudflare"
                        })
        result = response["result"]
        { id: result["id"], name: result["name"], token: result["token"] }
      end

      def find_tunnel(name)
        response = get("/accounts/#{@account_id}/cfd_tunnel", name:, is_deleted: "false")
        result = response.dig("result", 0)
        return nil unless result

        { id: result["id"], name: result["name"], token: result["token"] }
      end

      def get_tunnel(tunnel_id)
        response = get("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}")
        result = response["result"]
        return nil unless result

        { id: result["id"], name: result["name"], status: result["status"] }
      rescue HttpErrors::ApiError => e
        raise unless e.not_found?

        nil
      end

      def list_tunnels
        response = get("/accounts/#{@account_id}/cfd_tunnel", is_deleted: "false")
        (response["result"] || []).map { |t| { id: t["id"], name: t["name"], status: t["status"] } }
      end

      def get_tunnel_token(tunnel_id)
        response = get("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/token")
        response["result"]
      end

      def configure_tunnel_ingress(tunnel_id, rules)
        put("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/configurations", {
              config: { ingress: rules }
            })
      end

      def get_tunnel_configuration(tunnel_id)
        response = get("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/configurations")
        response.dig("result", "config") || {}
      end

      def delete_tunnel(tunnel_id)
        begin
          delete("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}/connections")
        rescue StandardError
          nil
        end
        delete("/accounts/#{@account_id}/cfd_tunnel/#{tunnel_id}")
      end

      # DNS Records
      def ensure_dns_record(zone_id, hostname, tunnel_id)
        content = "#{tunnel_id}.cfargotunnel.com"
        existing = find_dns_record(zone_id, hostname)

        if existing
          return existing if existing["content"] == content

          return update_dns_record(zone_id, existing["id"], hostname, content)
        end

        create_dns_record(zone_id, hostname, content)
      end

      def find_dns_record(zone_id, hostname, type: "CNAME")
        response = get("/zones/#{zone_id}/dns_records", name: hostname, type:)
        response.dig("result", 0)
      end

      def list_dns_records(zone_id)
        response = get("/zones/#{zone_id}/dns_records")
        (response["result"] || []).map { |r| { id: r["id"], type: r["type"], name: r["name"], content: r["content"] } }
      end

      def delete_dns_record(zone_id, record_id)
        delete("/zones/#{zone_id}/dns_records/#{record_id}")
      end

      # High-Level Setup
      def setup_tunnel(tunnel_name:, hostname:, service_url:, zone_domain:)
        tunnel = find_or_create_tunnel(tunnel_name)
        configure_tunnel_ingress(tunnel[:id], [
                                   { hostname:, service: service_url },
                                   { service: "http_status:404" }
                                 ])

        zone_id = get_zone_id(zone_domain)
        ensure_dns_record(zone_id, hostname, tunnel[:id])
        token = get_tunnel_token(tunnel[:id])

        { id: tunnel[:id], name: tunnel[:name], token:, hostname: }
      end

      def cleanup_tunnel(tunnel_name:, hostname:, zone_domain:)
        tunnel = find_tunnel(tunnel_name)
        return unless tunnel

        zone_id = begin
          get_zone_id(zone_domain)
        rescue StandardError
          nil
        end
        if zone_id
          record = find_dns_record(zone_id, hostname)
          delete_dns_record(zone_id, record["id"]) if record
        end

        delete_tunnel(tunnel[:id])
      end

      # Workers
      def worker_name(slug)
        Naming.worker(slug)
      end

      def deploy_worker(slug, access_token:, ws_url: nil, api_url: nil)
        name = worker_name(slug)
        path = "/accounts/#{@account_id}/workers/scripts/#{name}"

        boundary = "----RbrunBoundary#{SecureRandom.hex(8)}"
        metadata = {
          main_module: "worker.js",
          compatibility_date: "2024-01-01",
          bindings: Worker.bindings(slug, access_token, ws_url:, api_url:)
        }
        body = Worker.build_multipart(boundary, metadata, Worker.script)

        put_multipart(path, body, boundary)
      end

      def create_worker_route(zone_id, slug, domain)
        pattern = Naming.worker_route(slug, domain)
        name = worker_name(slug)

        existing = find_worker_route(zone_id, pattern)
        return existing if existing

        response = post("/zones/#{zone_id}/workers/routes", { pattern:, script: name })
        response["result"]
      end

      def find_worker_route(zone_id, pattern)
        response = get("/zones/#{zone_id}/workers/routes")
        routes = response["result"] || []
        routes.find { |r| r["pattern"] == pattern }
      end

      def delete_worker(slug)
        name = worker_name(slug)
        delete("/accounts/#{@account_id}/workers/scripts/#{name}")
      end

      # Validate
      def validate_credentials
        get("/user/tokens/verify")
        true
      rescue HttpErrors::ApiError => e
        raise RbrunCore::Error, "Cloudflare credentials invalid: #{e.message}" if e.unauthorized?

        raise
      end

      private

        def find_phase_ruleset(zone_id, phase)
          response = get("/zones/#{zone_id}/rulesets")
          rulesets = response["result"] || []
          rulesets.find { |r| r["phase"] == phase }
        end

        def auth_headers
          { "Authorization" => "Bearer #{@api_token}" }
        end

        def create_dns_record(zone_id, hostname, content)
          response = post("/zones/#{zone_id}/dns_records", {
                            type: "CNAME", name: hostname, content:, proxied: true, ttl: 1
                          })
          response["result"]
        end

        def update_dns_record(zone_id, record_id, hostname, content)
          response = put("/zones/#{zone_id}/dns_records/#{record_id}", {
                           type: "CNAME", name: hostname, content:, proxied: true, ttl: 1
                         })
          response["result"]
        end

        def put_multipart(path, body, boundary)
          normalized_path = path.sub(%r{^/}, "")
          conn = Faraday.new(url: BASE_URL, ssl: { verify: false }) do |f|
            f.headers["Authorization"] = "Bearer #{@api_token}"
            f.headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
            f.options.timeout = @timeout
            f.options.open_timeout = @open_timeout
            f.adapter Faraday.default_adapter
          end

          response = conn.put(normalized_path, body)
          result = JSON.parse(response.body)

          unless result["success"]
            errors = result["errors"]&.map { |e| e["message"] }&.join(", ") || "unknown error"
            raise RbrunCore::Error, "Worker deploy failed: #{errors}"
          end

          result
        end
    end
  end
end
