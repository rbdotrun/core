# frozen_string_literal: true

module RbrunCore
  module Steps
    class SetupApplication
      WORKSPACE = "/home/deploy/workspace"
      COMPOSE_FILE = "docker-compose.generated.yml"

      def initialize(ctx, on_log: nil)
        @ctx = ctx
        @on_log = on_log
      end

      def run
        install_software!
        clone_repo!
        checkout_branch!
        write_environment!
        generate_compose!
        setup_docker_compose!
      end

      private

        def install_software!
          log("apt_packages", "Installing packages")
          ssh!("sudo apt-get update && sudo apt-get install -y curl git jq rsync docker.io docker-compose-v2 ca-certificates gnupg")

          log("docker", "Starting Docker")
          ssh!("sudo systemctl enable docker && sudo systemctl start docker")

          setup_git_auth!
        end

        def setup_git_auth!
          git_config = @ctx.config.git_config
          pat = git_config.pat

          if pat && !pat.empty?
            log("gh_auth", "Configuring git auth")
            ssh!("git config --global user.name '#{git_config.username}' && git config --global user.email '#{git_config.email}'")
          end
        end

        def clone_repo!
          log("clone", "Cloning repository")
          result = ssh!("test -d #{WORKSPACE}/.git", raise_on_error: false, timeout: 10)
          return if result[:exit_code] == 0

          clone_url = git_clone_url
          ssh!("git clone #{Shellwords.escape(clone_url)} #{WORKSPACE}", timeout: 120)
        end

        def checkout_branch!
          log("branch", "Checking out branch")
          ssh!("cd #{WORKSPACE} && git checkout -B #{Shellwords.escape(Naming.branch(@ctx.slug))}")
        end

        def write_environment!
          log("environment", "Writing environment file")
          env_content = build_env_content
          return if env_content.empty?

          ssh!("cat > #{WORKSPACE}/.env << 'ENVEOF'\n#{env_content}\nENVEOF")
          ssh!("grep -qxF '.env' #{WORKSPACE}/.gitignore 2>/dev/null || echo '.env' >> #{WORKSPACE}/.gitignore")
        end

        def generate_compose!
          log("compose_generate", "Generating docker-compose.yml")
          compose_content = Generators::Compose.new(@ctx.config).generate
          ssh!("cat > #{WORKSPACE}/#{COMPOSE_FILE} << 'COMPOSEEOF'\n#{compose_content}\nCOMPOSEEOF")
          ssh!("grep -qxF '#{COMPOSE_FILE}' #{WORKSPACE}/.gitignore 2>/dev/null || echo '#{COMPOSE_FILE}' >> #{WORKSPACE}/.gitignore")
        end

        def setup_docker_compose!
          log("compose_setup", "Setting up Docker Compose")
          config = @ctx.config

          docker_compose!("up -d postgres", raise_on_error: false) if config.database?(:postgres)
          docker_compose!("up -d redis", raise_on_error: false) if config.database?(:redis) || config.service?(:redis)

          config.setup_commands.each do |cmd|
            next if cmd.nil? || cmd.empty?
            docker_compose!("run --rm web sh -c #{Shellwords.escape(cmd)}")
          end

          docker_compose!("up -d")
        end

        def build_env_content
          lines = []
          @ctx.config.env_vars.each do |key, value|
            resolved = @ctx.config.resolve(value, target: @ctx.target)
            lines << "#{key}=#{resolved}" if resolved
          end
          lines.join("\n")
        end

        def git_clone_url
          pat = @ctx.config.git_config.pat
          repo = @ctx.config.git_config.repo
          pat && !pat.empty? ? "https://#{pat}@github.com/#{repo}.git" : "https://github.com/#{repo}.git"
        end

        def docker_compose!(args, raise_on_error: true, timeout: 300)
          ssh!("cd #{WORKSPACE} && docker compose -f #{COMPOSE_FILE} #{args}", raise_on_error:, timeout:)
        end

        def ssh!(command, **opts)
          @ctx.ssh_client.execute(command, **opts)
        end

        def log(category, message = nil)
          @on_log&.call(category, message)
        end
    end
  end
end
