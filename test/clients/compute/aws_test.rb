# frozen_string_literal: true

require "test_helper"

module RbrunCore
  module Clients
    module Compute
      class AwsTest < Minitest::Test
        def setup
          super
          WebMock.reset!
          @access_key_id = "AKIAIOSFODNN7EXAMPLE"
          @secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
          @region = "us-east-1"
        end

        def test_raises_without_access_key
          assert_raises(RbrunCore::Error) do
            Aws.new(access_key_id: nil, secret_access_key: @secret_access_key, region: @region)
          end
        end

        def test_raises_without_secret_access_key
          assert_raises(RbrunCore::Error) do
            Aws.new(access_key_id: @access_key_id, secret_access_key: nil, region: @region)
          end
        end

        def test_find_server_returns_nil
          stub_describe_instances([])
          client = build_client

          assert_nil client.find_server("nonexistent")
        end

        def test_find_server_returns_server
          stub_describe_instances([ aws_instance_data ])
          client = build_client
          server = client.find_server("test-server")

          assert_equal "i-1234567890abcdef0", server.id
          assert_equal "54.123.45.67", server.public_ipv4
        end

        def test_find_or_create_server_returns_existing
          stub_describe_instances([ aws_instance_data ])
          client = build_client
          server = client.find_or_create_server(
            name: "test-server", instance_type: "t3.micro", location: "us-east-1a",
            image: "ubuntu-22.04"
          )

          assert_equal "i-1234567890abcdef0", server.id
        end

        def test_find_or_create_server_creates_when_not_found
          stub_describe_instances([])
          stub_describe_images
          stub_run_instances
          client = build_client
          server = client.find_or_create_server(
            name: "new-server", instance_type: "t3.micro", location: "us-east-1a",
            image: "ubuntu-22.04"
          )

          assert_equal "i-1234567890abcdef0", server.id
        end

        def test_find_or_create_firewall_returns_existing
          stub_describe_vpcs([ aws_vpc_data ])
          stub_describe_security_groups([ aws_security_group_data ])
          client = build_client
          fw = client.find_firewall("test-sg")

          assert_equal "sg-123456", fw.id
        end

        def test_find_or_create_firewall_creates_when_not_found
          stub_describe_vpcs([ aws_vpc_data ])
          stub_describe_security_groups([])
          stub_create_security_group
          stub_authorize_security_group_ingress
          stub_describe_security_groups_by_id([ aws_security_group_data ])
          client = build_client

          rules = [ { direction: "in", protocol: "tcp", port: "22", source_ips: [ "0.0.0.0/0" ] } ]
          fw = client.find_or_create_firewall("new-sg", rules:)

          assert_equal "sg-123456", fw.id
        end

        def test_find_or_create_network_returns_existing
          stub_describe_vpcs([ aws_vpc_data ])
          client = build_client
          network = client.find_network("test-vpc")

          assert_equal "vpc-123456", network.id
        end

        def test_find_or_create_network_creates_when_not_found
          stub_describe_vpcs([])
          stub_create_vpc
          stub_create_tags
          stub_modify_vpc_attribute
          stub_create_subnet
          stub_modify_subnet_attribute
          stub_create_internet_gateway
          stub_attach_internet_gateway
          stub_describe_route_tables
          stub_create_route
          stub_associate_route_table
          stub_describe_vpcs_after_create([ aws_vpc_data ])
          client = build_client
          network = client.find_or_create_network("new-vpc", location: "us-east-1")

          assert_equal "vpc-123456", network.id
        end

        def test_find_or_create_ssh_key_returns_existing
          stub_describe_key_pairs([ aws_key_pair_data ])
          client = build_client
          key = client.find_ssh_key("test-key")

          assert_equal "key-123456", key.id
        end

        def test_find_or_create_ssh_key_creates_when_not_found
          stub_describe_key_pairs_not_found
          stub_import_key_pair
          client = build_client
          key = client.find_or_create_ssh_key(name: "new-key", public_key: "ssh-rsa AAAA...")

          assert_equal "key-123456", key.id
        end

        def test_validate_credentials_returns_true
          stub_describe_regions
          client = build_client

          assert client.validate_credentials
        end

        def test_validate_credentials_raises_on_unauthorized
          stub_describe_regions_unauthorized
          client = build_client

          assert_raises(RbrunCore::Error) { client.validate_credentials }
        end

        private

          def build_client
            Aws.new(access_key_id: @access_key_id, secret_access_key: @secret_access_key, region: @region)
          end

          def stub_describe_instances(instances)
            reservations = instances.empty? ? [] : [ { instances: } ]
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeInstances/)
              .to_return(status: 200, body: describe_instances_response(reservations))
          end

          def stub_describe_images
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeImages/)
              .to_return(status: 200, body: describe_images_response)
          end

          def stub_run_instances
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=RunInstances/)
              .to_return(status: 200, body: run_instances_response)
          end

          def stub_describe_vpcs(vpcs)
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeVpcs/)
              .to_return(status: 200, body: describe_vpcs_response(vpcs))
          end

          def stub_describe_vpcs_after_create(vpcs)
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeVpcs/)
              .to_return(status: 200, body: describe_vpcs_response(vpcs))
          end

          def stub_describe_security_groups(groups)
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeSecurityGroups/)
              .to_return(status: 200, body: describe_security_groups_response(groups))
          end

          def stub_describe_security_groups_by_id(groups)
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeSecurityGroups.*GroupId/)
              .to_return(status: 200, body: describe_security_groups_response(groups))
          end

          def stub_create_security_group
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateSecurityGroup/)
              .to_return(status: 200, body: create_security_group_response)
          end

          def stub_authorize_security_group_ingress
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=AuthorizeSecurityGroupIngress/)
              .to_return(status: 200, body: "<AuthorizeSecurityGroupIngressResponse><return>true</return></AuthorizeSecurityGroupIngressResponse>")
          end

          def stub_create_vpc
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateVpc/)
              .to_return(status: 200, body: create_vpc_response)
          end

          def stub_create_tags
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateTags/)
              .to_return(status: 200, body: "<CreateTagsResponse><return>true</return></CreateTagsResponse>")
          end

          def stub_modify_vpc_attribute
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=ModifyVpcAttribute/)
              .to_return(status: 200, body: "<ModifyVpcAttributeResponse><return>true</return></ModifyVpcAttributeResponse>")
          end

          def stub_create_subnet
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateSubnet/)
              .to_return(status: 200, body: create_subnet_response)
          end

          def stub_modify_subnet_attribute
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=ModifySubnetAttribute/)
              .to_return(status: 200, body: "<ModifySubnetAttributeResponse><return>true</return></ModifySubnetAttributeResponse>")
          end

          def stub_create_internet_gateway
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateInternetGateway/)
              .to_return(status: 200, body: create_internet_gateway_response)
          end

          def stub_attach_internet_gateway
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=AttachInternetGateway/)
              .to_return(status: 200, body: "<AttachInternetGatewayResponse><return>true</return></AttachInternetGatewayResponse>")
          end

          def stub_describe_route_tables
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeRouteTables/)
              .to_return(status: 200, body: describe_route_tables_response)
          end

          def stub_create_route
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=CreateRoute/)
              .to_return(status: 200, body: "<CreateRouteResponse><return>true</return></CreateRouteResponse>")
          end

          def stub_associate_route_table
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=AssociateRouteTable/)
              .to_return(status: 200, body: "<AssociateRouteTableResponse><associationId>rtbassoc-123</associationId></AssociateRouteTableResponse>")
          end

          def stub_describe_key_pairs(keys)
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeKeyPairs/)
              .to_return(status: 200, body: describe_key_pairs_response(keys))
          end

          def stub_describe_key_pairs_not_found
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeKeyPairs/)
              .to_return(status: 400, body: key_pair_not_found_response)
          end

          def stub_import_key_pair
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=ImportKeyPair/)
              .to_return(status: 200, body: import_key_pair_response)
          end

          def stub_describe_regions
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeRegions/)
              .to_return(status: 200, body: describe_regions_response)
          end

          def stub_describe_regions_unauthorized
            stub_request(:post, "https://ec2.us-east-1.amazonaws.com/")
              .with(body: /Action=DescribeRegions/)
              .to_return(status: 401, body: auth_failure_response)
          end

          def aws_instance_data
            {
              instance_id: "i-1234567890abcdef0",
              instance_type: "t3.micro",
              image_id: "ami-12345678",
              state: { name: "running" },
              public_ip_address: "54.123.45.67",
              private_ip_address: "10.0.1.100",
              placement: { availability_zone: "us-east-1a" },
              launch_time: Time.now,
              tags: [ { key: "Name", value: "test-server" } ]
            }
          end

          def aws_vpc_data
            {
              vpc_id: "vpc-123456",
              cidr_block: "10.0.0.0/16",
              tags: [ { key: "Name", value: "test-vpc" } ]
            }
          end

          def aws_security_group_data
            {
              group_id: "sg-123456",
              group_name: "test-sg",
              ip_permissions: [
                { ip_protocol: "tcp", from_port: 22, to_port: 22,
                  ip_ranges: [ { cidr_ip: "0.0.0.0/0" } ] }
              ]
            }
          end

          def aws_key_pair_data
            {
              key_pair_id: "key-123456",
              key_name: "test-key",
              key_fingerprint: "aa:bb:cc:dd",
              create_time: Time.now
            }
          end

          def describe_instances_response(reservations)
            instances_xml = reservations.flat_map { |r| r[:instances] }.map do |i|
              tags_xml = (i[:tags] || []).map { |t| "<item><key>#{t[:key]}</key><value>#{t[:value]}</value></item>" }.join
              <<~XML
                <item>
                  <instanceId>#{i[:instance_id]}</instanceId>
                  <instanceType>#{i[:instance_type]}</instanceType>
                  <imageId>#{i[:image_id]}</imageId>
                  <instanceState><name>#{i[:state][:name]}</name></instanceState>
                  <ipAddress>#{i[:public_ip_address]}</ipAddress>
                  <privateIpAddress>#{i[:private_ip_address]}</privateIpAddress>
                  <placement><availabilityZone>#{i.dig(:placement, :availability_zone)}</availabilityZone></placement>
                  <launchTime>#{i[:launch_time]&.iso8601}</launchTime>
                  <tagSet>#{tags_xml}</tagSet>
                </item>
              XML
            end.join

            reservations_xml = reservations.empty? ? "" : "<item><instancesSet>#{instances_xml}</instancesSet></item>"

            <<~XML
              <DescribeInstancesResponse>
                <reservationSet>#{reservations_xml}</reservationSet>
              </DescribeInstancesResponse>
            XML
          end

          def describe_images_response
            <<~XML
              <DescribeImagesResponse>
                <imagesSet>
                  <item>
                    <imageId>ami-12345678</imageId>
                    <name>ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20240101</name>
                    <state>available</state>
                    <creationDate>2024-01-01T00:00:00.000Z</creationDate>
                  </item>
                </imagesSet>
              </DescribeImagesResponse>
            XML
          end

          def run_instances_response
            <<~XML
              <RunInstancesResponse>
                <instancesSet>
                  <item>
                    <instanceId>i-1234567890abcdef0</instanceId>
                    <instanceType>t3.micro</instanceType>
                    <imageId>ami-12345678</imageId>
                    <instanceState><name>pending</name></instanceState>
                    <placement><availabilityZone>us-east-1a</availabilityZone></placement>
                    <launchTime>#{Time.now.iso8601}</launchTime>
                    <tagSet></tagSet>
                  </item>
                </instancesSet>
              </RunInstancesResponse>
            XML
          end

          def describe_vpcs_response(vpcs)
            vpcs_xml = vpcs.map do |v|
              tags_xml = (v[:tags] || []).map { |t| "<item><key>#{t[:key]}</key><value>#{t[:value]}</value></item>" }.join
              <<~XML
                <item>
                  <vpcId>#{v[:vpc_id]}</vpcId>
                  <cidrBlock>#{v[:cidr_block]}</cidrBlock>
                  <tagSet>#{tags_xml}</tagSet>
                </item>
              XML
            end.join

            <<~XML
              <DescribeVpcsResponse>
                <vpcSet>#{vpcs_xml}</vpcSet>
              </DescribeVpcsResponse>
            XML
          end

          def describe_security_groups_response(groups)
            groups_xml = groups.map do |g|
              perms_xml = (g[:ip_permissions] || []).map do |p|
                ranges_xml = (p[:ip_ranges] || []).map { |r| "<item><cidrIp>#{r[:cidr_ip]}</cidrIp></item>" }.join
                <<~XML
                  <item>
                    <ipProtocol>#{p[:ip_protocol]}</ipProtocol>
                    <fromPort>#{p[:from_port]}</fromPort>
                    <toPort>#{p[:to_port]}</toPort>
                    <ipRanges>#{ranges_xml}</ipRanges>
                  </item>
                XML
              end.join

              <<~XML
                <item>
                  <groupId>#{g[:group_id]}</groupId>
                  <groupName>#{g[:group_name]}</groupName>
                  <ipPermissions>#{perms_xml}</ipPermissions>
                </item>
              XML
            end.join

            <<~XML
              <DescribeSecurityGroupsResponse>
                <securityGroupInfo>#{groups_xml}</securityGroupInfo>
              </DescribeSecurityGroupsResponse>
            XML
          end

          def create_security_group_response
            <<~XML
              <CreateSecurityGroupResponse>
                <groupId>sg-123456</groupId>
              </CreateSecurityGroupResponse>
            XML
          end

          def create_vpc_response
            <<~XML
              <CreateVpcResponse>
                <vpc>
                  <vpcId>vpc-123456</vpcId>
                  <cidrBlock>10.0.0.0/16</cidrBlock>
                </vpc>
              </CreateVpcResponse>
            XML
          end

          def create_subnet_response
            <<~XML
              <CreateSubnetResponse>
                <subnet>
                  <subnetId>subnet-123456</subnetId>
                </subnet>
              </CreateSubnetResponse>
            XML
          end

          def create_internet_gateway_response
            <<~XML
              <CreateInternetGatewayResponse>
                <internetGateway>
                  <internetGatewayId>igw-123456</internetGatewayId>
                </internetGateway>
              </CreateInternetGatewayResponse>
            XML
          end

          def describe_route_tables_response
            <<~XML
              <DescribeRouteTablesResponse>
                <routeTableSet>
                  <item>
                    <routeTableId>rtb-123456</routeTableId>
                    <associationSet></associationSet>
                  </item>
                </routeTableSet>
              </DescribeRouteTablesResponse>
            XML
          end

          def describe_key_pairs_response(keys)
            keys_xml = keys.map do |k|
              <<~XML
                <item>
                  <keyPairId>#{k[:key_pair_id]}</keyPairId>
                  <keyName>#{k[:key_name]}</keyName>
                  <keyFingerprint>#{k[:key_fingerprint]}</keyFingerprint>
                  <createTime>#{k[:create_time]&.iso8601}</createTime>
                </item>
              XML
            end.join

            <<~XML
              <DescribeKeyPairsResponse>
                <keySet>#{keys_xml}</keySet>
              </DescribeKeyPairsResponse>
            XML
          end

          def key_pair_not_found_response
            <<~XML
              <Response>
                <Errors>
                  <Error>
                    <Code>InvalidKeyPair.NotFound</Code>
                    <Message>The key pair 'test-key' does not exist</Message>
                  </Error>
                </Errors>
              </Response>
            XML
          end

          def import_key_pair_response
            <<~XML
              <ImportKeyPairResponse>
                <keyPairId>key-123456</keyPairId>
                <keyName>new-key</keyName>
                <keyFingerprint>aa:bb:cc:dd</keyFingerprint>
              </ImportKeyPairResponse>
            XML
          end

          def describe_regions_response
            <<~XML
              <DescribeRegionsResponse>
                <regionInfo>
                  <item><regionName>us-east-1</regionName></item>
                </regionInfo>
              </DescribeRegionsResponse>
            XML
          end

          def auth_failure_response
            <<~XML
              <Response>
                <Errors>
                  <Error>
                    <Code>AuthFailure</Code>
                    <Message>AWS was not able to validate the provided access credentials</Message>
                  </Error>
                </Errors>
              </Response>
            XML
          end
      end
    end
  end
end
