# frozen_string_literal: true

module RbrunCore
  module Step
    # Step states
    PENDING = :pending
    IN_PROGRESS = :in_progress
    DONE = :done
    ERROR = :error

    # All step identifiers (compile-time safety)
    module Id
      # Infrastructure
      CREATE_FIREWALL = :create_firewall
      CREATE_NETWORK = :create_network
      CREATE_SERVER = :create_server
      WAIT_SSH = :wait_ssh

      # K3s
      WAIT_CLOUD_INIT = :wait_cloud_init
      DISCOVER_NETWORK = :discover_network
      CONFIGURE_REGISTRIES = :configure_registries
      INSTALL_K3S = :install_k3s
      SETUP_KUBECONFIG = :setup_kubeconfig
      DEPLOY_INGRESS = :deploy_ingress
      LABEL_NODES = :label_nodes
      RETRIEVE_TOKEN = :retrieve_token
      SETUP_WORKERS = :setup_workers

      # Deploy
      SETUP_REGISTRY = :setup_registry
      PROVISION_VOLUMES = :provision_volumes
      BUILD_IMAGE = :build_image
      DEPLOY_MANIFESTS = :deploy_manifests
      WAIT_ROLLOUT = :wait_rollout
      CLEANUP_IMAGES = :cleanup_images

      # Tunnel
      SETUP_TUNNEL = :setup_tunnel
      CLEANUP_TUNNEL = :cleanup_tunnel

      # Destroy
      DETACH_VOLUMES = :detach_volumes
      DELETE_SERVERS = :delete_servers
      DELETE_VOLUMES = :delete_volumes
      DELETE_FIREWALL = :delete_firewall
      DELETE_NETWORK = :delete_network

      # Sandbox
      INSTALL_PACKAGES = :install_packages
      INSTALL_DOCKER = :install_docker
      INSTALL_NODE = :install_node
      INSTALL_CLAUDE_CODE = :install_claude_code
      INSTALL_GH_CLI = :install_gh_cli
      CONFIGURE_GIT_AUTH = :configure_git_auth
      CLONE_REPO = :clone_repo
      CHECKOUT_BRANCH = :checkout_branch
      WRITE_ENV = :write_env
      GENERATE_COMPOSE = :generate_compose
      START_COMPOSE = :start_compose
      STOP_CONTAINERS = :stop_containers

      ALL = constants.map { |c| const_get(c) }.freeze
    end
  end
end
