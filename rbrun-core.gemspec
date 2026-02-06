# frozen_string_literal: true

require_relative 'lib/rbrun_core/version'

Gem::Specification.new do |s|
  s.name        = 'rbrun-core'
  s.version     = RbrunCore::VERSION
  s.authors     = [ 'rbrun' ]
  s.summary     = 'Idempotent cloud deployment core'
  s.description = 'Standalone library for provisioning cloud infrastructure and deploying applications. No database or Rails dependencies.'
  s.license     = 'MIT'

  s.required_ruby_version = '>= 3.2'

  s.files = Dir['lib/**/*', 'LICENSE', 'README.md']
  s.require_paths = [ 'lib' ]

  s.add_dependency 'base64'
  s.add_dependency 'bcrypt_pbkdf', '>= 1.0'
  s.add_dependency 'ed25519', '>= 1.2'
  s.add_dependency 'faraday', '~> 2.0'
  s.add_dependency 'faraday-multipart', '~> 1.0'
  s.add_dependency 'sshkey', '~> 3.0'
  s.add_dependency 'aws-sdk-ec2', '~> 1.0'
  s.add_dependency 'sshkit', '~> 1.23'
  s.add_dependency 'zeitwerk', '~> 2.6'
  s.metadata['rubygems_mfa_required'] = 'true'
end
