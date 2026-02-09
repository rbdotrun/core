# frozen_string_literal: true

module KamalContrib
  class Pipeline
    def initialize(ctx, on_step: nil, on_state_change: nil)
      @ctx = ctx
      @on_step = on_step
      @on_state_change = on_state_change
    end

    # Full pipeline: provision + configure + generate + deploy
    def setup(output_dir: ".", first_deploy: true)
      change_state(:provisioning)

      provision
      generate_config(output_dir:)

      change_state(:deploying)

      deploy_step = Steps::Deploy.new(@ctx, on_step: @on_step)
      deploy_step.run(
        config_file: File.join(output_dir, "config", "deploy.yml"),
        first_deploy:
      )

      change_state(:deployed)
      @ctx
    rescue StandardError
      change_state(:failed)
      raise
    end

    # Provision infrastructure only (steps 1-5)
    def provision
      Steps::ProvisionServers.new(@ctx, on_step: @on_step).run
      Steps::ProvisionLoadBalancer.new(@ctx, on_step: @on_step).run
      Steps::ConfigureFirewall.new(@ctx, on_step: @on_step).run
      Steps::ConfigureDns.new(@ctx, on_step: @on_step).run if @ctx.cloudflare_client
      Steps::GenerateCerts.new(@ctx, on_step: @on_step).run
      @ctx
    end

    # Generate Kamal config files only (steps 6-7)
    def generate_config(output_dir: ".")
      config_step = Steps::GenerateKamalConfig.new(@ctx, on_step: @on_step)
      config_step.run

      write_config_files!(output_dir, config_step)
      @ctx
    end

    # Tear down all infrastructure
    def destroy
      change_state(:destroying)

      delete_load_balancer!
      delete_certificates!
      delete_servers!
      delete_network!
      delete_firewall!

      change_state(:destroyed)
      @ctx
    rescue StandardError
      change_state(:failed)
      raise
    end

    # Query infrastructure status
    def status
      compute = @ctx.compute_client
      prefix = @ctx.prefix

      {
        servers: compute.list_servers.select { |s| s.name.start_with?(prefix) },
        load_balancers: (compute.list_load_balancers.select { |lb| lb.name.start_with?(prefix) } if compute.respond_to?(:list_load_balancers)),
        firewalls: compute.list_firewalls.select { |f| f.name.start_with?(prefix) },
        networks: compute.list_networks.select { |n| n.name.start_with?(prefix) }
      }.compact
    end

    private

      def write_config_files!(output_dir, config_step)
        deploy_dir = File.join(output_dir, "config")
        FileUtils.mkdir_p(deploy_dir)
        File.write(File.join(deploy_dir, "deploy.yml"), config_step.deploy_yml)

        secrets_dir = File.join(output_dir, ".kamal")
        FileUtils.mkdir_p(secrets_dir)
        File.write(File.join(secrets_dir, "secrets"), config_step.secrets)
      end

      def delete_load_balancer!
        @on_step&.call("Load Balancer", :in_progress)
        compute = @ctx.compute_client
        if compute.respond_to?(:list_load_balancers)
          compute.list_load_balancers.each do |lb|
            next unless lb.name.start_with?(@ctx.prefix)

            compute.delete_load_balancer(lb.id)
          end
        end
        @on_step&.call("Load Balancer", :done)
      end

      def delete_certificates!
        @on_step&.call("Certificates", :in_progress)
        compute = @ctx.compute_client
        if compute.respond_to?(:list_certificates)
          compute.list_certificates.each do |cert|
            next unless cert.name.start_with?(@ctx.prefix)

            compute.delete_certificate(cert.id)
          end
        end
        @on_step&.call("Certificates", :done)
      end

      def delete_servers!
        @on_step&.call("Servers", :in_progress)
        @ctx.compute_client.list_servers.each do |server|
          next unless server.name.start_with?(@ctx.prefix)

          @ctx.compute_client.delete_server(server.id)
        end
        @on_step&.call("Servers", :done)
      end

      def delete_network!
        @on_step&.call("Network", :in_progress)
        network = @ctx.compute_client.find_network(@ctx.prefix)
        @ctx.compute_client.delete_network(network.id) if network
        @on_step&.call("Network", :done)
      end

      def delete_firewall!
        @on_step&.call("Firewall", :in_progress)
        firewall = @ctx.compute_client.find_firewall(@ctx.prefix)
        @ctx.compute_client.delete_firewall(firewall.id) if firewall
        @on_step&.call("Firewall", :done)
      end

      def change_state(state)
        @ctx.state = state
        @on_state_change&.call(state)
      end
  end
end
