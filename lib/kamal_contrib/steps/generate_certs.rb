# frozen_string_literal: true

require "openssl"

module KamalContrib
  module Steps
    class GenerateCerts
      def initialize(ctx, on_step: nil)
        @ctx = ctx
        @on_step = on_step
      end

      def run
        @on_step&.call("Certificates", :in_progress)

        # Try Hetzner managed certificate first, fall back to self-signed
        cert = provision_managed_certificate || generate_self_signed
        @ctx.certificates << cert if cert

        @on_step&.call("Certificates", :done)
      end

      private

        def provision_managed_certificate
          compute_client.find_or_create_managed_certificate(
            name: "#{@ctx.prefix}-cert",
            domain_names: [ @ctx.config.domain ]
          )
        rescue RbrunCore::Error::Api
          nil
        end

        def generate_self_signed
          key = OpenSSL::PKey::RSA.new(2048)
          cert = OpenSSL::X509::Certificate.new
          cert.version = 2
          cert.serial = rand(2**64)
          cert.subject = OpenSSL::X509::Name.parse("/CN=#{@ctx.config.domain}")
          cert.issuer = cert.subject
          cert.public_key = key.public_key
          cert.not_before = Time.now
          cert.not_after = Time.now + (365 * 24 * 60 * 60)

          ef = OpenSSL::X509::ExtensionFactory.new
          ef.subject_certificate = cert
          ef.issuer_certificate = cert
          cert.add_extension(ef.create_extension("subjectAltName", "DNS:#{@ctx.config.domain}"))

          cert.sign(key, OpenSSL::Digest.new("SHA256"))

          { key: key.to_pem, cert: cert.to_pem, type: :self_signed }
        end

        def compute_client
          @ctx.compute_client
        end
    end
  end
end
