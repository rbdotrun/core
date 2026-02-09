# frozen_string_literal: true

require_relative "lib/kamal_contrib/version"
require_relative "lib/rbrun_core/version"

Gem::Specification.new do |s|
  s.name        = "kamal-contrib"
  s.version     = KamalContrib::VERSION
  s.authors     = [ "rbrun" ]
  s.summary     = "Kamal deployment pipeline for Hetzner + Cloudflare"
  s.description = "Single-command deployment pipeline: provision infrastructure, configure " \
                  "load balancing, DNS, TLS, generate Kamal config, and deploy. Built on rbrun-core."
  s.license     = "MIT"
  s.homepage    = "https://rb.run"

  s.required_ruby_version = ">= 3.2"

  s.files       = Dir["lib/kamal_contrib.rb", "lib/kamal_contrib/**/*"]
  s.require_paths = [ "lib" ]

  s.add_dependency "rbrun-core", RbrunCore::VERSION
  s.add_dependency "zeitwerk", "~> 2.6"
  s.metadata["rubygems_mfa_required"] = "true"
end
