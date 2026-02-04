#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone deployment script — no Rails, no database.
# Usage: ruby examples/deploy.rb

require_relative "../lib/rbrun_core"

config = RbrunCore::Configuration.new
config.compute(:hetzner) do |c|
  c.api_key = ENV.fetch("HETZNER_API_TOKEN")
  c.ssh_key_path = "~/.ssh/id_ed25519"
  c.server_type = "cpx21"
  c.location = "nbg1"
end

config.cloudflare do |cf|
  cf.api_token = ENV.fetch("CLOUDFLARE_API_TOKEN")
  cf.account_id = ENV.fetch("CLOUDFLARE_ACCOUNT_ID")
  cf.domain = "example.com"
end

config.git do |g|
  g.pat = ENV.fetch("GITHUB_PAT")
  g.repo = "myorg/myapp"
end

config.database(:postgres) { |db| db.volume_size = "20Gi" }
config.service(:redis) { |s| s.subdomain = "redis" }

config.app do |a|
  a.dockerfile = "Dockerfile"
  a.process(:web) { |p| p.command = "bin/rails server"; p.port = 3000 }
  a.process(:worker) { |p| p.command = "bin/jobs" }
end

config.env(
  SECRET_KEY_BASE: ENV.fetch("SECRET_KEY_BASE"),
  RAILS_ENV: "production"
)

ctx = RbrunCore::Context.new(config:, target: :production, branch: "main")

deploy = RbrunCore::Commands::Deploy.new(ctx,
  on_log: ->(category, output) { puts "[#{category}] #{output}" }
)

deploy.run
puts "Deployed to #{ctx.server_ip}"
