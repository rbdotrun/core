# frozen_string_literal: true

require "aws-sdk-ec2"
require "aws-sdk-elasticloadbalancingv2"

module RbrunCore
  module Clients
    module Compute
      class Aws
        include Interface

        CANONICAL_OWNER_ID = "099720109477"
        VPC_CIDR = "10.0.0.0/16"
        SUBNET_CIDRS = [ "10.0.1.0/24", "10.0.2.0/24" ].freeze

        def initialize(access_key_id:, secret_access_key:, region:)
          raise Error::Standard, "AWS access_key_id not configured" if access_key_id.nil? || access_key_id.empty?

          if secret_access_key.nil? || secret_access_key.empty?
            raise Error::Standard, "AWS secret_access_key not configured"
          end

          @region = region
          credentials = ::Aws::Credentials.new(access_key_id, secret_access_key)
          @ec2 = ::Aws::EC2::Client.new(region:, credentials:, ssl_verify_peer: false)
          @elbv2 = ::Aws::ElasticLoadBalancingV2::Client.new(region:, credentials:, ssl_verify_peer: false)
        end

        # Server methods
        def find_or_create_server(name:, instance_type:, location:, image:, user_data: nil, labels: {},
                                  firewall_ids: [], network_ids: [])
          existing = find_server(name)
          return existing if existing

          create_server(name:, instance_type:, location:, image:, user_data:, labels:,
                        firewall_ids:, network_ids:)
        end

        def create_server(name:, instance_type:, location:, image:, user_data: nil, labels: {},
                          firewall_ids: [], network_ids: [])
          ami_id = resolve_ubuntu_ami(image)

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
            params[:subnet_id] = subnet_id if subnet_id
          end

          response = @ec2.run_instances(params)
          instance = response.instances.first

          # Wait for instance to be running with public IP
          wait_for_server(instance.instance_id)
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

        def wait_for_server(id, max_attempts: 60, interval: 5)
          Waiter.poll(max_attempts:, interval:, message: "Server #{id} did not become running after #{max_attempts} attempts") do
            server = get_server(id)
            server if server&.status == "running" && server&.public_ipv4
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

        # Network methods (VPC + Subnets + IGW + Route Table)
        # Creates subnets in 2 AZs for ALB compatibility
        def find_or_create_network(name, location:)
          existing = find_network(name)
          return existing if existing

          vpc_id = create_vpc(name)
          subnet_ids = create_subnets(vpc_id, name)
          igw_id = create_internet_gateway(vpc_id, name)
          setup_route_table(vpc_id, subnet_ids, igw_id, name)

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

        # Load Balancer Management (ELBv2 - Application Load Balancer)
        # AWS ALB requires subnets in 2+ AZs, uses target groups + listeners

        def find_or_create_load_balancer(name:, type: "application", location: nil, network_id: nil,
                                         firewall_ids: [], labels: {})
          existing = find_load_balancer(name)
          return existing if existing

          subnet_ids = network_id ? find_subnets_for_network(network_id) : []
          raise Error::Standard, "ALB requires at least 2 subnets in different AZs" if subnet_ids.length < 2

          params = {
            name:, subnets: subnet_ids,
            scheme: "internet-facing",
            type:, ip_address_type: "ipv4"
          }
          params[:security_groups] = firewall_ids if firewall_ids&.any?
          params[:tags] = labels.map { |k, v| { key: k.to_s, value: v.to_s } } if labels&.any?

          response = @elbv2.create_load_balancer(params)
          lb = response.load_balancers.first

          @elbv2.wait_until(:load_balancer_available, load_balancer_arns: [ lb.load_balancer_arn ])
          to_load_balancer(lb)
        end

        def find_load_balancer(name)
          response = @elbv2.describe_load_balancers(names: [ name ])
          lb = response.load_balancers.first
          lb ? to_load_balancer(lb) : nil
        rescue ::Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
          nil
        end

        def list_load_balancers(**filters)
          response = @elbv2.describe_load_balancers
          response.load_balancers.map { |lb| to_load_balancer(lb) }
        end

        def delete_load_balancer(id)
          # id is the ARN for AWS
          @elbv2.delete_load_balancer(load_balancer_arn: id)

          # Clean up associated target groups
          cleanup_target_groups(id)
        rescue ::Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
          nil
        end

        def attach_load_balancer_to_network(load_balancer_id:, network_id:)
          # AWS ALBs are associated with VPC via subnets at creation time.
          # No-op: the VPC/subnet association is set in find_or_create_load_balancer.
        end

        def add_load_balancer_target(load_balancer_id:, server_id:, use_private_ip: false)
          tg = find_or_create_default_target_group(load_balancer_id)

          @elbv2.register_targets(
            target_group_arn: tg.target_group_arn,
            targets: [ { id: server_id } ]
          )
        rescue ::Aws::ElasticLoadBalancingV2::Errors::InvalidTarget
          raise Error::Standard, "Cannot register target #{server_id}"
        end

        def add_load_balancer_service(load_balancer_id:, protocol: "tcp", listen_port: 443,
                                      destination_port: 443, health_check: {})
          tg = find_or_create_default_target_group(load_balancer_id, port: destination_port,
                                                   health_check: health_check)

          # Check if listener already exists
          existing = @elbv2.describe_listeners(load_balancer_arn: load_balancer_id)
          return if existing.listeners.any? { |l| l.port == listen_port }

          # ALB uses HTTP/HTTPS, not raw TCP
          alb_protocol = listen_port == 443 ? "HTTPS" : "HTTP"

          params = {
            load_balancer_arn: load_balancer_id,
            protocol: alb_protocol,
            port: listen_port,
            default_actions: [ { type: "forward", target_group_arn: tg.target_group_arn } ]
          }

          @elbv2.create_listener(params)
        rescue ::Aws::ElasticLoadBalancingV2::Errors::DuplicateListener
          # Already exists
        end

        # Validation
        def validate_credentials
          @ec2.describe_regions
          true
        rescue ::Aws::EC2::Errors::AuthFailure => e
          raise Error::Standard, "AWS credentials invalid: #{e.message}"
        end

        def inventory
          {
            servers: list_servers,
            firewalls: list_firewalls,
            networks: list_networks,
            load_balancers: list_load_balancers
          }
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

          def create_subnets(vpc_id, name)
            azs = available_azs
            SUBNET_CIDRS.each_with_index.map do |cidr, i|
              az = azs[i] || "#{@region}#{("a".ord + i).chr}"
              subnet = @ec2.create_subnet(vpc_id:, cidr_block: cidr, availability_zone: az)
              subnet_id = subnet.subnet.subnet_id
              tag_resource(subnet_id, "#{name}-subnet-#{az}")

              @ec2.modify_subnet_attribute(subnet_id:, map_public_ip_on_launch: { value: true })

              subnet_id
            end
          end

          def available_azs
            response = @ec2.describe_availability_zones(
              filters: [ { name: "state", values: [ "available" ] } ]
            )
            response.availability_zones.map(&:zone_name).sort.first(2)
          rescue ::Aws::EC2::Errors::ServiceError
            [ "#{@region}a", "#{@region}b" ]
          end

          def create_internet_gateway(vpc_id, name)
            igw = @ec2.create_internet_gateway
            igw_id = igw.internet_gateway.internet_gateway_id
            tag_resource(igw_id, "#{name}-igw")
            @ec2.attach_internet_gateway(internet_gateway_id: igw_id, vpc_id:)

            igw_id
          end

          def setup_route_table(vpc_id, subnet_ids, igw_id, name)
            route_tables = @ec2.describe_route_tables(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            rtb_id = route_tables.route_tables.first.route_table_id
            tag_resource(rtb_id, "#{name}-rtb")

            @ec2.create_route(route_table_id: rtb_id, destination_cidr_block: "0.0.0.0/0", gateway_id: igw_id)
            subnet_ids.each do |subnet_id|
              @ec2.associate_route_table(route_table_id: rtb_id, subnet_id:)
            end
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

          # AMI helpers
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

          def find_subnets_for_network(vpc_id)
            response = @ec2.describe_subnets(filters: [ { name: "vpc-id", values: [ vpc_id ] } ])
            response.subnets.map(&:subnet_id)
          end

          def tag_resource(resource_id, name)
            @ec2.create_tags(resources: [ resource_id ], tags: [ { key: "Name", value: name } ])
          end

          # Load balancer helpers

          def find_or_create_default_target_group(lb_arn, port: 443, health_check: {})
            # Derive target group name from LB name
            lb = @elbv2.describe_load_balancers(load_balancer_arns: [ lb_arn ]).load_balancers.first
            tg_name = "#{lb.load_balancer_name}-tg"[0, 32]

            existing = find_target_group(tg_name)
            return existing if existing

            params = {
              name: tg_name,
              protocol: "HTTP",
              port:,
              vpc_id: lb.vpc_id,
              target_type: "instance",
              health_check_protocol: "HTTP",
              health_check_path: health_check[:path] || "/",
              health_check_interval_seconds: health_check[:interval] || 30,
              health_check_timeout_seconds: health_check[:timeout] || 5,
              healthy_threshold_count: 3,
              unhealthy_threshold_count: 2
            }

            response = @elbv2.create_target_group(params)
            response.target_groups.first
          end

          def find_target_group(name)
            response = @elbv2.describe_target_groups(names: [ name ])
            response.target_groups.first
          rescue ::Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
            nil
          end

          def cleanup_target_groups(lb_arn)
            response = @elbv2.describe_target_groups
            response.target_groups.each do |tg|
              next unless tg.load_balancer_arns.include?(lb_arn)

              @elbv2.delete_target_group(target_group_arn: tg.target_group_arn)
            rescue ::Aws::ElasticLoadBalancingV2::Errors::ResourceInUse
              # LB still draining, skip
            end
          rescue ::Aws::ElasticLoadBalancingV2::Errors::ServiceError
            # Best effort
          end

          def to_load_balancer(lb)
            Types::LoadBalancer.new(
              id: lb.load_balancer_arn,
              name: lb.load_balancer_name,
              public_ipv4: lb.dns_name,
              type: lb.type,
              location: lb.availability_zones&.map { |az| az.zone_name }&.join(","),
              targets: [],
              services: [],
              labels: {},
              created_at: lb.created_time&.iso8601
            )
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
      end
    end
  end
end
