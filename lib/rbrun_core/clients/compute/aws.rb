# frozen_string_literal: true

require "aws-sdk-ec2"

module RbrunCore
  module Clients
    module Compute
      class Aws
        include Interface

        CANONICAL_OWNER_ID = "099720109477"
        VPC_CIDR = "10.0.0.0/16"
        SUBNET_CIDR = "10.0.1.0/24"

        def initialize(access_key_id:, secret_access_key:, region:)
          raise Error::Standard, "AWS access_key_id not configured" if access_key_id.nil? || access_key_id.empty?

          if secret_access_key.nil? || secret_access_key.empty?
            raise Error::Standard, "AWS secret_access_key not configured"
          end

          @region = region
          @ec2 = ::Aws::EC2::Client.new(
            region:,
            credentials: ::Aws::Credentials.new(access_key_id, secret_access_key),
            ssl_verify_peer: false
          )
        end

        # Server methods
        def find_or_create_server(name:, instance_type:, location:, image:, user_data: nil, labels: {},
                                  firewall_ids: [], network_ids: [], public_ip: true)
          existing = find_server(name)
          return existing if existing

          create_server(name:, instance_type:, location:, image:, user_data:, labels:,
                        firewall_ids:, network_ids:, public_ip:)
        end

        def create_server(name:, instance_type:, location:, image:, user_data: nil, labels: {},
                          firewall_ids: [], network_ids: [], public_ip: true)
          ami_id = resolve_ami(image)

          tags = labels.map { |k, v| { key: k.to_s, value: v.to_s } }
          tags << { key: "Name", value: name }

          params = {
            image_id: ami_id,
            instance_type:,
            min_count: 1,
            max_count: 1,
            tag_specifications: [
              { resource_type: "instance", tags: }
            ]
          }

          params[:user_data] = Base64.strict_encode64(user_data) if user_data && !user_data.empty?
          params[:security_group_ids] = firewall_ids if firewall_ids&.any?

          if network_ids&.any?
            subnet_id = find_subnet_for_network(network_ids.first)
            if subnet_id
              # Use network interface for fine-grained control over public IP
              params[:network_interfaces] = [ {
                device_index: 0,
                subnet_id:,
                associate_public_ip_address: public_ip,
                groups: firewall_ids || []
              } ]
              params.delete(:security_group_ids) # Can't use both
            end
          end

          response = @ec2.run_instances(params)
          instance = response.instances.first

          # Wait for instance to be running (with public IP if requested)
          wait_for_server(instance.instance_id, require_public_ip: public_ip)
        end

        def find_server(name)
          response = @ec2.describe_instances(filters: server_name_filter(name))
          instance = response.reservations.flat_map(&:instances).first
          instance ? to_server(instance) : nil
        end

        def get_server(id)
          response = @ec2.describe_instances(instance_ids: [ id ])
          instance = response.reservations.flat_map(&:instances).first
          instance ? to_server(instance) : nil
        rescue ::Aws::EC2::Errors::InvalidInstanceIDNotFound
          nil
        end

        def list_servers(label_selector: nil)
          filters = build_server_list_filters(label_selector)
          response = @ec2.describe_instances(filters:)
          response.reservations.flat_map(&:instances).map { |i| to_server(i) }
        end

        def wait_for_server(id, max_attempts: 60, interval: 5, require_public_ip: true)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not become running after #{max_attempts} attempts") do
            server = get_server(id)
            if require_public_ip
              server if server&.status == "running" && server&.public_ipv4
            else
              server if server&.status == "running"
            end
          end
        end

        def wait_for_server_deletion(id, max_attempts: 30, interval: 2)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} was not deleted after #{max_attempts} attempts") do
            server = get_server(id)
            server.nil? || server.status == "terminated"
          end
        end

        def delete_server(id)
          @ec2.terminate_instances(instance_ids: [ id ])
          wait_for_server_deletion(id)
        rescue ::Aws::EC2::Errors::InvalidInstanceIDNotFound
          nil
        end

        # Firewall methods (Security Groups)
        def find_or_create_firewall(name, rules: nil)
          vpc = find_or_create_network(name, location: @region)
          existing = find_firewall(name, vpc_id: vpc.id)
          return existing if existing

          create_security_group(name, vpc.id, rules || default_firewall_rules)
        end

        def find_firewall(name, vpc_id: nil)
          vpc_id ||= find_network(name)&.id
          return nil unless vpc_id

          response = @ec2.describe_security_groups(filters: firewall_filters(name, vpc_id))
          sg = response.security_groups.first
          sg ? to_firewall(sg) : nil
        end

        def find_firewall_by_id(id)
          response = @ec2.describe_security_groups(group_ids: [ id ])
          sg = response.security_groups.first
          sg ? to_firewall(sg) : nil
        rescue ::Aws::EC2::Errors::InvalidGroupNotFound
          nil
        end

        def delete_firewall(id)
          @ec2.delete_security_group(group_id: id)
        rescue ::Aws::EC2::Errors::InvalidGroupNotFound
          nil
        end

        # Network methods (VPC + Subnet + IGW + Route Table)
        def find_or_create_network(name, location:)
          existing = find_network(name)
          return existing if existing

          vpc_id = create_vpc(name)
          subnet_id = create_subnet(vpc_id, name)
          igw_id = create_internet_gateway(vpc_id, name)
          setup_route_table(vpc_id, subnet_id, igw_id, name)

          find_network(name)
        end

        def find_network(name)
          response = @ec2.describe_vpcs(filters: [ { name: "tag:Name", values: [ name ] } ])
          vpc = response.vpcs.first
          vpc ? to_network(vpc, name) : nil
        end

        def delete_network(id)
          delete_subnets(id)
          delete_internet_gateways(id)
          delete_route_tables(id)
          @ec2.delete_vpc(vpc_id: id)
        rescue ::Aws::EC2::Errors::InvalidVpcIDNotFound
          nil
        end

        # Validation
        def validate_credentials
          @ec2.describe_regions
          true
        rescue ::Aws::EC2::Errors::AuthFailure => e
          raise Error::Standard, "AWS credentials invalid: #{e.message}"
        end

        def server_type_memory_mb(instance_type)
          @server_type_cache ||= {}
          return @server_type_cache[instance_type] if @server_type_cache.key?(instance_type)

          response = @ec2.describe_instance_types(instance_types: [ instance_type ])
          info = response.instance_types.first
          raise Error::Configuration, "Unknown instance type '#{instance_type}'" unless info

          @server_type_cache[instance_type] = info.memory_info.size_in_mi_b
        end

        def inventory
          {
            servers: list_servers,
            firewalls: list_firewalls,
            networks: list_networks
          }
        end

        # Image Management (AMIs)
        def create_image_from_server(server_id:, name:, description: nil, labels: {})
          # Stop instance before creating AMI for consistency
          @ec2.stop_instances(instance_ids: [ server_id ])
          wait_for_server_stopped(server_id)

          tags = labels.map { |k, v| { key: k.to_s, value: v.to_s } }
          tags << { key: "Name", value: name }
          tags << { key: Naming::LABEL_BUILDER, value: "true" }

          response = @ec2.create_image(
            instance_id: server_id,
            name:,
            description: description || "Builder image for #{name}",
            tag_specifications: [
              { resource_type: "image", tags: }
            ]
          )

          image_id = response.image_id
          wait_for_image(image_id)
          get_image(image_id)
        end

        def get_image(id)
          response = @ec2.describe_images(image_ids: [ id ])
          image = response.images.first
          image ? to_image(image) : nil
        rescue ::Aws::EC2::Errors::InvalidAMIIDNotFound
          nil
        end

        def find_image(name)
          response = @ec2.describe_images(
            owners: [ "self" ],
            filters: [
              { name: "tag:#{Naming::LABEL_BUILDER}", values: [ "true" ] },
              { name: "tag:Name", values: [ name ] }
            ]
          )
          image = response.images.first
          image ? to_image(image) : nil
        end

        def list_images(label_selector: nil)
          filters = [ { name: "tag:#{Naming::LABEL_BUILDER}", values: [ "true" ] } ]
          response = @ec2.describe_images(owners: [ "self" ], filters:)
          response.images.map { |i| to_image(i) }
        end

        def delete_image(id)
          # Get image to find associated snapshots
          image = get_image(id)
          return nil unless image

          # Deregister AMI
          @ec2.deregister_image(image_id: id)

          # Delete associated snapshots
          response = @ec2.describe_images(image_ids: [ id ])
          image_data = response.images.first
          image_data&.block_device_mappings&.each do |mapping|
            next unless mapping.ebs&.snapshot_id

            @ec2.delete_snapshot(snapshot_id: mapping.ebs.snapshot_id)
          rescue ::Aws::EC2::Errors::InvalidSnapshotNotFound
            # Already deleted
          end
        rescue ::Aws::EC2::Errors::InvalidAMIIDNotFound
          nil
        end

        def wait_for_image(id, max_attempts: 120, interval: 5)
          Waiter.poll(max_attempts:, interval:, message: "Image #{id} did not become available") do
            image = get_image(id)
            image if image&.status == "available"
          end
        end

        def list_firewalls
          vpc = find_vpc_by_name_tag
          return [] unless vpc

          response = @ec2.describe_security_groups(filters: [ { name: "vpc-id", values: [ vpc.id ] } ])
          response.security_groups.map { |sg| to_firewall(sg) }
        end

        def list_networks
          response = @ec2.describe_vpcs
          response.vpcs.map do |vpc|
            name_tag = vpc.tags&.find { |t| t.key == "Name" }&.value
            to_network(vpc, name_tag || vpc.vpc_id)
          end
        end

        private

          # Server helpers
          def server_name_filter(name)
            [
              { name: "tag:Name", values: [ name ] },
              { name: "instance-state-name", values: %w[pending running stopping stopped] }
            ]
          end

          def build_server_list_filters(label_selector)
            filters = [ { name: "instance-state-name", values: %w[pending running stopping stopped] } ]
            return filters unless label_selector

            key, value = label_selector.split("=")
            filters << { name: "tag:#{key}", values: [ value ] }
            filters
          end

          # Firewall helpers
          def create_security_group(name, vpc_id, rules)
            response = @ec2.create_security_group(
              group_name: name,
              description: "Security group for #{name}",
              vpc_id:
            )
            sg_id = response.group_id

            rules.each { |rule| add_ingress_rule(sg_id, rule) }

            find_firewall_by_id(sg_id)
          end

          def default_firewall_rules
            [ { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0" ] } ]
          end

          def firewall_filters(name, vpc_id)
            [
              { name: "group-name", values: [ name ] },
              { name: "vpc-id", values: [ vpc_id ] }
            ]
          end

          def add_ingress_rule(sg_id, rule)
            ip_permissions = build_ip_permissions(rule)
            return if ip_permissions.empty?

            @ec2.authorize_security_group_ingress(group_id: sg_id, ip_permissions:)
          rescue ::Aws::EC2::Errors::InvalidPermissionDuplicate
            # Rule already exists
          end

          def build_ip_permissions(rule)
            port = rule[:port].to_i
            protocol = rule[:protocol] || "tcp"
            source_ips = rule[:source_ips] || [ "0.0.0.0/0" ]

            source_ips.reject { |ip| ip.include?(":") }.map do |cidr|
              {
                ip_protocol: protocol,
                from_port: port,
                to_port: port,
                ip_ranges: [ { cidr_ip: cidr } ]
              }
            end
          end

          # Network helpers
          def create_vpc(name)
            vpc = @ec2.create_vpc(cidr_block: VPC_CIDR)
            vpc_id = vpc.vpc.vpc_id
            tag_resource(vpc_id, name)

            @ec2.modify_vpc_attribute(vpc_id:, enable_dns_hostnames: { value: true })
            @ec2.modify_vpc_attribute(vpc_id:, enable_dns_support: { value: true })

            vpc_id
          end

          def create_subnet(vpc_id, name)
            az = "#{@region}a"
            subnet = @ec2.create_subnet(vpc_id:, cidr_block: SUBNET_CIDR, availability_zone: az)
            subnet_id = subnet.subnet.subnet_id
            tag_resource(subnet_id, "#{name}-subnet")

            @ec2.modify_subnet_attribute(subnet_id:, map_public_ip_on_launch: { value: true })

            subnet_id
          end

          def create_internet_gateway(vpc_id, name)
            igw = @ec2.create_internet_gateway
            igw_id = igw.internet_gateway.internet_gateway_id
            tag_resource(igw_id, "#{name}-igw")
            @ec2.attach_internet_gateway(internet_gateway_id: igw_id, vpc_id:)

            igw_id
          end

          def setup_route_table(vpc_id, subnet_id, igw_id, name)
            route_tables = @ec2.describe_route_tables(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            rtb_id = route_tables.route_tables.first.route_table_id
            tag_resource(rtb_id, "#{name}-rtb")

            @ec2.create_route(route_table_id: rtb_id, destination_cidr_block: "0.0.0.0/0", gateway_id: igw_id)
            @ec2.associate_route_table(route_table_id: rtb_id, subnet_id:)
          end

          def delete_subnets(vpc_id)
            subnets = @ec2.describe_subnets(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            subnets.subnets.each do |subnet|
              @ec2.delete_subnet(subnet_id: subnet.subnet_id)
            rescue ::Aws::EC2::Errors::ServiceError
              # Best effort
            end
          end

          def delete_internet_gateways(vpc_id)
            igws = @ec2.describe_internet_gateways(filters: [ { name: "attachment.vpc-id", values: [ vpc_id ] } ])
            igws.internet_gateways.each do |igw|
              @ec2.detach_internet_gateway(internet_gateway_id: igw.internet_gateway_id, vpc_id:)
              @ec2.delete_internet_gateway(internet_gateway_id: igw.internet_gateway_id)
            rescue ::Aws::EC2::Errors::ServiceError
              # Best effort
            end
          end

          def delete_route_tables(vpc_id)
            route_tables = @ec2.describe_route_tables(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            route_tables.route_tables.each do |rtb|
              next if rtb.associations.any?(&:main)

              disassociate_route_table(rtb)
              @ec2.delete_route_table(route_table_id: rtb.route_table_id)
            rescue ::Aws::EC2::Errors::ServiceError
              # Best effort
            end
          end

          def disassociate_route_table(rtb)
            rtb.associations.each do |assoc|
              @ec2.disassociate_route_table(association_id: assoc.route_table_association_id)
            rescue ::Aws::EC2::Errors::ServiceError
              # Best effort
            end
          end

          def wait_for_server_stopped(id, max_attempts: 30, interval: 5)
            Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not stop") do
              server = get_server(id)
              server if server&.status == "stopped"
            end
          end

          # AMI helpers
          def resolve_ami(image_hint)
            # If it's an AMI ID, use it directly
            return image_hint if image_hint.to_s.start_with?("ami-")

            # Otherwise resolve Ubuntu AMI
            resolve_ubuntu_ami(image_hint)
          end

          def resolve_ubuntu_ami(image_hint)
            return image_hint if image_hint.start_with?("ami-")

            version = ubuntu_version(image_hint)
            response = @ec2.describe_images(owners: [ CANONICAL_OWNER_ID ], filters: ubuntu_ami_filters(version))

            images = response.images.sort_by(&:creation_date).reverse
            raise Error::Standard, "No Ubuntu AMI found for #{image_hint}" if images.empty?

            images.first.image_id
          end

          def ubuntu_version(image_hint)
            case image_hint
            when /22\.04/, /jammy/i then "22.04"
            when /20\.04/, /focal/i then "20.04"
            when /24\.04/, /noble/i then "24.04"
            else "22.04"
            end
          end

          def ubuntu_ami_filters(version)
            [
              { name: "name", values: [ "ubuntu/images/hvm-ssd/ubuntu-*-#{version}-amd64-server-*" ] },
              { name: "state", values: [ "available" ] },
              { name: "architecture", values: [ "x86_64" ] }
            ]
          end

          # VPC helpers
          def find_or_ensure_vpc
            existing = find_vpc_by_name_tag
            return existing if existing

            find_or_create_network("rbrun-vpc", location: @region)
          end

          def find_vpc_by_name_tag
            response = @ec2.describe_vpcs(filters: [ { name: "tag:Name", values: [ "*" ] } ])

            vpc = response.vpcs.find { |v| v.tags&.any? { |t| t.key == "Name" } }
            return nil unless vpc

            name_tag = vpc.tags.find { |t| t.key == "Name" }&.value
            to_network(vpc, name_tag || vpc.vpc_id)
          end

          def find_subnet_for_network(vpc_id)
            response = @ec2.describe_subnets(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            response.subnets.first&.subnet_id
          end

          def tag_resource(resource_id, name)
            @ec2.create_tags(resources: [ resource_id ], tags: [ { key: "Name", value: name } ])
          end

          # Type converters
          def to_server(instance)
            name_tag = instance.tags&.find { |t| t.key == "Name" }&.value
            labels = extract_instance_labels(instance)

            Types::Server.new(
              id: instance.instance_id,
              name: name_tag || instance.instance_id,
              status: instance.state.name,
              public_ipv4: instance.public_ip_address,
              private_ipv4: instance.private_ip_address,
              instance_type: instance.instance_type,
              image: instance.image_id,
              location: instance.placement&.availability_zone,
              labels:,
              created_at: instance.launch_time&.iso8601
            )
          end

          def extract_instance_labels(instance)
            instance.tags&.reject { |t| t.key == "Name" }&.to_h { |t| [ t.key, t.value ] } || {}
          end

          def to_firewall(sg)
            rules = sg.ip_permissions.flat_map do |perm|
              perm.ip_ranges.map do |range|
                {
                  direction: "in",
                  protocol: perm.ip_protocol,
                  port: perm.from_port.to_s,
                  source_ips: [ range.cidr_ip ]
                }
              end
            end

            Types::Firewall.new(id: sg.group_id, name: sg.group_name, rules:, created_at: nil)
          end

          def to_network(vpc, name)
            Types::Network.new(
              id: vpc.vpc_id,
              name:,
              ip_range: vpc.cidr_block,
              subnets: [],
              location: nil,
              created_at: nil
            )
          end

          def to_image(image)
            name_tag = image.tags&.find { |t| t.key == "Name" }&.value
            labels = image.tags&.reject { |t| t.key == "Name" }&.to_h { |t| [ t.key, t.value ] } || {}

            Types::Image.new(
              id: image.image_id,
              name: name_tag || image.name,
              status: image.state,
              description: image.description,
              size_gb: nil, # AWS doesn't expose this directly
              labels:,
              created_at: image.creation_date
            )
          end
      end
    end
  end
end
