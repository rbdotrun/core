#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone deployment script — no Rails, no database.
# Usage: ruby examples/deploy.rb --config examples/production.yaml

require_relative "../lib/rbrun_core"

config_path = ARGV.find { |a| a.start_with?("--config") }&.split("=", 2)&.last ||
              ARGV[ARGV.index("--config") + 1] if ARGV.include?("--config")
config_path ||= "examples/production.yaml"

config = RbrunCore::Config::Loader.load(config_path)
ctx = RbrunCore::Context.new(config:)

deploy = RbrunCore::Commands::Deploy.new(ctx,
                                         on_log: ->(category, output) { puts "[#{category}] #{output}" })

deploy.run
puts "Deployed to #{ctx.server_ip}"
