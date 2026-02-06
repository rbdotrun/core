# frozen_string_literal: true

module RbrunCore
  module Clients
    module Compute
      # Normalized resource types shared across all cloud providers.
      module Types
        Server = Struct.new(
          :id, :name, :status, :public_ipv4, :private_ipv4,
          :instance_type, :image, :location, :labels, :created_at,
          keyword_init: true
        )

        SshKey = Struct.new(
          :id, :name, :fingerprint, :public_key, :created_at,
          keyword_init: true
        )

        Firewall = Struct.new(
          :id, :name, :rules, :created_at,
          keyword_init: true
        )

        Network = Struct.new(
          :id, :name, :ip_range, :subnets, :location, :created_at,
          keyword_init: true
        )
      end
    end
  end
end
