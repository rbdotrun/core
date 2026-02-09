# frozen_string_literal: true

module RbrunCore
  module InstanceTypes
    # Memory in MB for common instance types across providers
    HETZNER = {
      # Shared vCPU (CX line)
      "cx11" => 2048,
      "cx21" => 4096,
      "cx22" => 4096,
      "cx31" => 8192,
      "cx32" => 8192,
      "cx41" => 16_384,
      "cx42" => 16_384,
      "cx51" => 32_768,
      "cx52" => 32_768,
      # Dedicated vCPU (CCX line)
      "ccx13" => 8192,
      "ccx23" => 16_384,
      "ccx33" => 32_768,
      "ccx43" => 65_536,
      "ccx53" => 98_304,
      "ccx63" => 131_072,
      # Dedicated AMD (CPX line)
      "cpx11" => 2048,
      "cpx21" => 4096,
      "cpx31" => 8192,
      "cpx41" => 16_384,
      "cpx51" => 32_768,
      # Legacy names
      "cx23" => 4096
    }.freeze

    SCALEWAY = {
      "DEV1-S" => 2048,
      "DEV1-M" => 4096,
      "DEV1-L" => 8192,
      "DEV1-XL" => 12_288,
      "GP1-XS" => 16_384,
      "GP1-S" => 32_768,
      "GP1-M" => 65_536,
      "GP1-L" => 131_072,
      "GP1-XL" => 196_608
    }.freeze

    AWS = {
      "t3.micro" => 1024,
      "t3.small" => 2048,
      "t3.medium" => 4096,
      "t3.large" => 8192,
      "t3.xlarge" => 16_384,
      "t3.2xlarge" => 32_768,
      "m5.large" => 8192,
      "m5.xlarge" => 16_384,
      "m5.2xlarge" => 32_768,
      "m5.4xlarge" => 65_536
    }.freeze

    def self.memory_mb(provider, instance_type)
      registry = case provider.to_sym
      when :hetzner then HETZNER
      when :scaleway then SCALEWAY
      when :aws then AWS
      else {}
      end

      registry[instance_type] || raise(
        Error::Configuration,
        "Unknown instance type '#{instance_type}' for provider '#{provider}'"
      )
    end
  end
end
