# frozen_string_literal: true

module RbrunCore
  module Commands
    class DeploySandbox
      class SetupApplication
        WORKSPACE = "/home/deploy/workspace"
        COMPOSE_FILE = "docker-compose.generated.yml"

        def initialize(ctx, on_step: nil)
          @ctx = ctx
          @on_step = on_step
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
            @on_step&.call("Packages", :in_progress)
            @ctx.ssh_client.execute("sudo apt-get update && sudo apt-get install -y curl git jq rsync docker.io docker-compose-v2 ca-certificates gnupg")
            @on_step&.call("Packages", :done)

            unless command_exists?("docker")
              @on_step&.call("Docker", :in_progress)
              @ctx.ssh_client.execute("sudo systemctl enable docker && sudo systemctl start docker")
              @on_step&.call("Docker", :done)
            end

            install_node!
            install_claude_code!
            install_gh_cli!
            setup_git_auth!
          end

          def install_node!
            return if command_exists?("node")

            @on_step&.call("Node", :in_progress)
            @ctx.ssh_client.execute(<<~BASH)
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && \
            sudo apt-get install -y nodejs
          BASH
            @on_step&.call("Node", :done)
          end

          def install_claude_code!
            return if command_exists?("claude")

            @on_step&.call("Claude Code", :in_progress)
            @ctx.ssh_client.execute("sudo npm install -g @anthropic-ai/claude-code")
            @on_step&.call("Claude Code", :done)
          end

          def install_gh_cli!
            return if command_exists?("gh")

            @on_step&.call("GitHub CLI", :in_progress)
            @ctx.ssh_client.execute(<<~BASH)
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
            sudo apt-get update && sudo apt-get install -y gh
          BASH
            @on_step&.call("GitHub CLI", :done)
          end

          def setup_git_auth!
            pat = local_git_pat
            return unless pat && !pat.empty?

            @on_step&.call("Git auth", :in_progress)
            @ctx.ssh_client.execute("git config --global user.name 'rbrun' && git config --global user.email 'sandbox@rbrun.dev'")
            @ctx.ssh_client.execute("echo #{Shellwords.escape(pat)} | gh auth login --with-token", raise_on_error: false)
            @on_step&.call("Git auth", :done)
          end

          def command_exists?(cmd)
            @ctx.ssh_client.execute("command -v #{cmd}", raise_on_error: false)[:exit_code].zero?
          end

          def clone_repo!
            @on_step&.call("Repo", :in_progress)
            result = @ctx.ssh_client.execute("test -d #{WORKSPACE}/.git", raise_on_error: false, timeout: 10)
            if result[:exit_code].zero?
              @on_step&.call("Repo", :done)
              return
            end

            clone_url = git_clone_url
            @ctx.ssh_client.execute("git clone #{Shellwords.escape(clone_url)} #{WORKSPACE}", timeout: 120)
            @on_step&.call("Repo", :done)
          end

          def checkout_branch!
            @on_step&.call("Branch", :in_progress)
            @ctx.ssh_client.execute("cd #{WORKSPACE} && git checkout -B #{Shellwords.escape(Naming.branch(@ctx.slug))}")
            @on_step&.call("Branch", :done)
          end

          def write_environment!
            @on_step&.call("Environment", :in_progress)
            env_content = build_env_content
            if env_content.empty?
              @on_step&.call("Environment", :done)
              return
            end

            @ctx.ssh_client.execute("cat > #{WORKSPACE}/.env << 'ENVEOF'\n#{env_content}\nENVEOF")
            @ctx.ssh_client.execute("grep -qxF '.env' #{WORKSPACE}/.gitignore 2>/dev/null || echo '.env' >> #{WORKSPACE}/.gitignore")
            @on_step&.call("Environment", :done)
          end

          def generate_compose!
            @on_step&.call("Compose", :in_progress)
            compose_content = Generators::Compose.new(@ctx.config).generate
            @ctx.ssh_client.execute("cat > #{WORKSPACE}/#{COMPOSE_FILE} << 'COMPOSEEOF'\n#{compose_content}\nCOMPOSEEOF")
            @ctx.ssh_client.execute("grep -qxF '#{COMPOSE_FILE}' #{WORKSPACE}/.gitignore 2>/dev/null || echo '#{COMPOSE_FILE}' >> #{WORKSPACE}/.gitignore")
            @on_step&.call("Compose", :done)
          end

          def setup_docker_compose!
            @on_step&.call("Compose", :in_progress)
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
            @on_step&.call("Compose", :done)
          end

          def build_env_content
            lines = []
            @ctx.config.env_vars.each do |key, value|
              lines << "#{key}=#{value}" if value
            end
            lines.join("\n")
          end

          def git_clone_url
            repo = local_git_repo
            pat = local_git_pat
            pat && !pat.empty? ? "https://#{pat}@github.com/#{repo}.git" : "https://github.com/#{repo}.git"
          end

          def local_git_repo
            @local_git_repo ||= begin
              LocalGit.repo_from_remote
            rescue Error::Standard
              raise Error::Configuration, "sandbox mode requires running from a git repository"
            end
          end

          def local_git_pat
            @local_git_pat ||= LocalGit.gh_auth_token
          rescue Error::Standard
            nil
          end

          def docker_compose!(args, raise_on_error: true, timeout: 300)
            @ctx.ssh_client.execute("cd #{WORKSPACE} && docker compose -f #{COMPOSE_FILE} #{args}", raise_on_error:, timeout:)
          end
      end
    end
  end
end
