# frozen_string_literal: true

module RbrunCli
  class Kamal < Thor
    def self.exit_on_failure? = true

    class_option :config, type: :string, default: "rbrun.yaml", aliases: "-c",
                          desc: "Path to YAML config file"
    class_option :folder, type: :string, aliases: "-f",
                          desc: "Working directory for git detection"
    class_option :env_file, type: :string, default: ".env", aliases: "-e",
                             desc: "Path to .env file for variable interpolation"
    class_option :log_file, type: :string, aliases: "-l",
                             desc: "Log file path (default: {folder}/deploy.log)"

    desc "deploy", "Provision infrastructure and deploy with Kamal"
    def deploy
      with_error_handling do
        runner.execute(RbrunCore::Commands::Kamal::Deploy)
      end
    end

    desc "destroy", "Tear down Kamal infrastructure"
    def destroy
      with_error_handling do
        runner.execute(RbrunCore::Commands::Kamal::Destroy)
      end
    end

    desc "status", "Show Kamal infrastructure status"
    def status
      with_error_handling do
        config = runner.load_config
        compute_client = config.compute_config.client
        prefix = "#{config.name}-kamal"
        servers = compute_client.list_servers.select { |s| s.name.start_with?(prefix) }
        formatter.status_table(servers)
      end
    end

    desc "config", "Generate Kamal config files without deploying"
    def config
      with_error_handling do
        ctx = runner.build_context
        output_dir = ctx.source_folder || "."

        builder = RbrunCore::Commands::Kamal::ConfigBuilder.new(
          config: ctx.config,
          servers: {},
          domain: ctx.config.cloudflare_config&.domain
        )

        deploy_dir = File.join(output_dir, "config")
        FileUtils.mkdir_p(deploy_dir)
        File.write(File.join(deploy_dir, "deploy.yml"), builder.to_yaml)

        secrets_dir = File.join(output_dir, ".kamal")
        FileUtils.mkdir_p(secrets_dir)
        File.write(File.join(secrets_dir, "secrets"), builder.to_secrets)

        formatter.info("Generated config/deploy.yml and .kamal/secrets")
      end
    end

    private

      def runner
        @runner ||= Runner.new(
          config_path: options[:config],
          folder: options[:folder],
          env_file: options[:env_file],
          log_file: options[:log_file],
          formatter:
        )
      end

      def formatter
        @formatter ||= Formatter.new
      end

      def with_error_handling
        yield
      rescue RbrunCore::Error::Configuration => e
        formatter.error("Configuration error: #{e.message}")
        exit 1
      rescue RbrunCore::Error::Api => e
        formatter.error("API error: #{e.message}")
        exit 1
      rescue RbrunCore::Error::Standard => e
        formatter.error(e.message)
        exit 1
      rescue StandardError => e
        location = e.backtrace&.find { |l| l.include?("rbrun") }&.sub(/.*gems\//, "")
        formatter.error("#{e.class}: #{e.message}")
        formatter.error("  at #{location}") if location
        exit 1
      end
  end
end
