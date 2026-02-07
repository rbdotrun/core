# frozen_string_literal: true

module RbrunCore
  module Commands
    class DeploySandbox
      class SetupApplication
        WORKSPACE = "/home/deploy/workspace"
        COMPOSE_FILE = "docker-compose.generated.yml"

        def initialize(ctx, logger: nil)
          @ctx = ctx
          @logger = logger
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

            unless command_exists?("docker")
              log("docker", "Starting Docker")
              ssh!("sudo systemctl enable docker && sudo systemctl start docker")
            end

            install_node!
            install_claude_code!
            install_gh_cli!
            setup_git_auth!
          end

          def install_node!
            return if command_exists?("node")

            log("node", "Installing Node.js 20.x")
            ssh!(<<~BASH)
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && \
            sudo apt-get install -y nodejs
          BASH
          end

          def install_claude_code!
            return if command_exists?("claude")

            log("claude_code", "Installing Claude Code")
            ssh!("sudo npm install -g @anthropic-ai/claude-code")
          end

          def install_gh_cli!
            return if command_exists?("gh")

            log("gh_cli", "Installing GitHub CLI")
            ssh!(<<~BASH)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
            sudo apt-get update && sudo apt-get install -y gh
          BASH
          end

          def setup_git_auth!
            git_config = @ctx.config.git_config
            pat = git_config.pat

            return unless pat && !pat.empty?

            log("gh_auth", "Configuring git auth")
            ssh!("git config --global user.name '#{git_config.username}' && git config --global user.email '#{git_config.email}'")
            ssh!("echo #{Shellwords.escape(pat)} | gh auth login --with-token", raise_on_error: false)
          end

          def command_exists?(cmd)
            ssh!("command -v #{cmd}", raise_on_error: false)[:exit_code].zero?
          end

          def clone_repo!
            log("clone", "Cloning repository")
            result = ssh!("test -d #{WORKSPACE}/.git", raise_on_error: false, timeout: 10)
            return if result[:exit_code].zero?

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
            docker_compose!("up -d redis", raise_on_error: false) if config.service?(:redis)

            config.app_config&.processes&.each do |name, process|
              process.setup.each do |cmd|
                next if cmd.nil? || cmd.empty?

                docker_compose!("run --rm #{name} sh -c #{Shellwords.escape(cmd)}")
              end
            end

            docker_compose!("up -d")
          end

          def build_env_content
            lines = []
            @ctx.config.env_vars.each do |key, value|
              lines << "#{key}=#{value}" if value
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

          def ssh!(command, **)
            @ctx.ssh_client.execute(command, **)
          end

          def log(category, message = nil)
            @logger&.log(category, message)
          end
      end
    end
  end
end
