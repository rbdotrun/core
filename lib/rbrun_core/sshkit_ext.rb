# frozen_string_literal: true

module RbrunCore
  module SshkitExt
    class << self
      def configure
        SSHKit::Backend::Netssh.configure do |ssh|
          ssh.connection_timeout = 30
          ssh.ssh_options = {
            verify_host_key: :never,
            logger: ::Logger.new(IO::NULL)
          }
        end

        # Connection pool idle timeout (15 minutes, like Kamal)
        SSHKit::Backend::Netssh.pool.idle_timeout = 900
      end
    end
  end
end
