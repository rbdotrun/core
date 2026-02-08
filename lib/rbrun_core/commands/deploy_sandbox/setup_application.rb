# frozen_string_literal: true

module RbrunCore
  module Commands
    class DeploySandbox
      class SetupApplication
        WORKSPACE = "/home/deploy/workspace"
        COMPOSE_FILE = "docker-compose.generated.yml"
        PACKAGES = %w[curl git jq rsync docker.io docker-compose-v2 ca-certificates gnupg].freeze

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
            ssh!("sudo apt-get update && sudo apt-get install -y #{PACKAGES.join(' ')}")
            @on_step&.call("Packages", :done)

            unless command_exists?("docker")
              @on_step&.call("Docker", :in_progress)
              ssh!("sudo systemctl enable docker && sudo systemctl start docker")
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
            ssh!(node_install_script)
            @on_step&.call("Node", :done)
          end

          def install_claude_code!
            return if command_exists?("claude")

            @on_step&.call("Claude Code", :in_progress)
            ssh!("sudo npm install -g @anthropic-ai/claude-code")
            @on_step&.call("Claude Code", :done)
          end

          def install_gh_cli!
            return if command_exists?("gh")

            @on_step&.call("GitHub CLI", :in_progress)
            ssh!(gh_cli_install_script)
            @on_step&.call("GitHub CLI", :done)
          end

          def setup_git_auth!
            pat = local_git_pat
            return unless pat && !pat.empty?

            @on_step&.call("Git auth", :in_progress)
            ssh!("git config --global user.name 'rbrun' && git config --global user.email 'sandbox@rbrun.dev'")
            ssh!("echo #{Shellwords.escape(pat)} | gh auth login --with-token", raise_on_error: false)
            @on_step&.call("Git auth", :done)
          end

          def command_exists?(cmd)
            ssh!("command -v #{cmd}", raise_on_error: false, timeout: 10)[:exit_code].zero?
          end

          def clone_repo!
            @on_step&.call("Repo", :in_progress)

            if repo_exists?
              @on_step&.call("Repo", :done)
              return
            end

            ssh!("git clone #{Shellwords.escape(git_clone_url)} #{WORKSPACE}", timeout: 120)
            @on_step&.call("Repo", :done)
          end

          def repo_exists?
            ssh!("test -d #{WORKSPACE}/.git", raise_on_error: false, timeout: 10)[:exit_code].zero?
          end

          def checkout_branch!
            @on_step&.call("Branch", :in_progress)
            branch = Naming.branch(@ctx.slug)
            ssh!("cd #{WORKSPACE} && git checkout -B #{Shellwords.escape(branch)}")
            @on_step&.call("Branch", :done)
          end

          def write_environment!
            @on_step&.call("Environment", :in_progress)
            env_content = build_env_content

            if env_content.empty?
              @on_step&.call("Environment", :done)
              return
            end

            write_file(".env", env_content)
            append_to_gitignore(".env")
            @on_step&.call("Environment", :done)
          end

          def generate_compose!
            @on_step&.call("Compose", :in_progress)
            compose_content = Generators::Compose.new(@ctx.config).generate
            write_file(COMPOSE_FILE, compose_content)
            append_to_gitignore(COMPOSE_FILE)
            @on_step&.call("Compose", :done)
          end

          def setup_docker_compose!
            @on_step&.call("Compose", :in_progress)
            config = @ctx.config

            docker_compose!("up -d postgres", raise_on_error: false) if config.database?(:postgres)
            docker_compose!("up -d redis", raise_on_error: false) if config.service?(:redis)

            run_setup_commands!

            docker_compose!("up -d")
            @on_step&.call("Compose", :done)
          end

          def run_setup_commands!
            processes = @ctx.config.app_config&.processes
            return unless processes

            processes.each do |name, process|
              process.setup.each do |cmd|
                next if cmd.nil? || cmd.empty?

                docker_compose!("run --rm #{name} sh -c #{Shellwords.escape(cmd)}")
              end
            end
          end

          def build_env_content
            @ctx.config.env_vars
              .select { |_, value| value }
              .map { |key, value| "#{key}=#{value}" }
              .join("\n")
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

          def ssh!(command, raise_on_error: true, timeout: 300)
            @ctx.ssh_client.execute(command, raise_on_error:, timeout:)
          end

          def docker_compose!(args, raise_on_error: true, timeout: 300)
            cmd = [ "cd", WORKSPACE, "&&", "docker", "compose", "-f", COMPOSE_FILE, *args.split ].join(" ")
            ssh!(cmd, raise_on_error:, timeout:)
          end

          def write_file(filename, content)
            ssh!("cat > #{WORKSPACE}/#{filename} << 'EOF'\n#{content}\nEOF")
          end

          def append_to_gitignore(entry)
            ssh!("grep -qxF '#{entry}' #{WORKSPACE}/.gitignore 2>/dev/null || echo '#{entry}' >> #{WORKSPACE}/.gitignore")
          end

          def node_install_script
            [
              download_nodesource_script,
              install_nodejs
            ].join(" && ")
          end

          def download_nodesource_script
            "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
          end

          def install_nodejs
            "sudo apt-get install -y nodejs"
          end

          def gh_cli_install_script
            [
              download_gh_keyring,
              add_gh_apt_source,
              install_gh
            ].join(" && ")
          end

          def download_gh_keyring
            "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg"
          end

          def add_gh_apt_source
            'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null'
          end

          def install_gh
            "sudo apt-get update && sudo apt-get install -y gh"
          end
      end
    end
  end
end
