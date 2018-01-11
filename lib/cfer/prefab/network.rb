require 'cfer'
require 'cfer/groups'
require 'ipaddress'

Cfer::Groups::Stack::resource_group "Cfer::Prefab::Network" do |args|
  vpc_cidr = IPAddress.parse(args[:CidrBlock]) || raise("cidr_block must be set")
  vpc_name = args[:NetworkName] || {"Ref": "AWS::StackName"}

  resource :Vpc, 'AWS::EC2::VPC' do
    cidr_block vpc_cidr.to_string
    enable_dns_support true
    enable_dns_hostnames true
    instance_tenancy 'default'

    properties args[:Vpc] if args[:Vpc]
    tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, "VPC"])
  end

  tier_cidrs = vpc_cidr.subnet(args[:TierSize] || 22)
  tiers = args[:Tiers].to_a.each_with_index.map do |tier, tier_index|
    tier_name = tier[0]
    tier_data = tier[1]

    tier_data.merge(
      Name: tier_name,
      Index: tier_index,
      Cidrs: tier_cidrs[tier_index].split(4)
    )
  end

  resource :IGW, 'AWS::EC2::InternetGateway' do
    tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, "IGW"])
  end

  resource "VPCGatewayAttachment", 'AWS::EC2::VPCGatewayAttachment' do
    vpc_id ref(:Vpc)
    internet_gateway_id ref(:IGW)
  end


  nat_count = args[:NatCount] || 1
  az_count = args[:AvailabilityZones].count

  raise "The network does not support having more NATs than AZs. Ensure `nat_count` is less than or equal to the number of availability zones." if nat_count > az_count

  (0...nat_count).each_with_index do |az, nat_i|

    resource "EIP#{nat_i}", 'AWS::EC2::EIP' do
      domain 'vpc'
    end

    resource "NAT#{nat_i}", 'AWS::EC2::NatGateway' do
      allocation_id get_att("EIP#{nat_i}", "AllocationId")
      subnet_id ref("PublicSubnet#{nat_i}")

      tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, "NAT", nat_i])
    end

  end

  public_cidrs = tier_cidrs.last.split(4)
  args[:AvailabilityZones].each_with_index do |az, az_i|
    resource "PublicSubnet#{az_i}", 'AWS::EC2::Subnet' do
      availability_zone az
      cidr_block public_cidrs[az_i].to_string
      vpc_id ref(:Vpc)
      map_public_ip_on_launch true

      properties args[:PublicSubnet] if args[:PublicSubnet]
      tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, "Public", az_i, az, "Subnet"])
    end

    resource "PublicRouteTable#{az_i}", 'AWS::EC2::RouteTable' do
      vpc_id ref(:Vpc)

      properties args[:PublicRouteTable] if args[:PublicRouteTable]
      tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, "Public", az_i, az, "Route Table"])
    end

    resource "DefaultPublicRoute#{az_i}", 'AWS::EC2::Route', DependsOn: [ name_of("VPCGatewayAttachment") ] do
      route_table_id ref("PublicRouteTable#{az_i}")
      gateway_id ref(:IGW)

      destination_cidr_block '0.0.0.0/0'
    end

    resource "PublicSubnetRouteTableAssociation#{az_i}", 'AWS::EC2::SubnetRouteTableAssociation' do
      subnet_id ref("PublicSubnet#{az_i}")
      route_table_id ref("PublicRouteTable#{az_i}")
    end


    tiers.each do |tier|

      resource "#{tier[:Name]}Subnet#{az_i}", 'AWS::EC2::Subnet' do
        availability_zone az
        cidr_block tier[:Cidrs][az_i].to_string
        vpc_id ref(:Vpc)
        map_public_ip_on_launch false

        properties tier[:Subnet] if tier[:Subnet]
        tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, tier[:Name], az_i, az, "Subnet"])
      end

      resource "#{tier[:Name]}PrivateRouteTable#{az_i}", 'AWS::EC2::RouteTable' do
        vpc_id ref(:Vpc)

        properties tier[:PrivateRouteTable] if tier[:PrivateRouteTable]
        tag :Name, Cfer::Core::Functions::Fn::join(' ', [vpc_name, tier[:Name], az_i, az, "Route Table"])
      end

      resource "#{tier[:Name]}SubnetRouteTableAssociation#{az_i}", 'AWS::EC2::SubnetRouteTableAssociation' do
        subnet_id ref("#{tier[:Name]}Subnet#{az_i}")
        route_table_id ref("#{tier[:Name]}PrivateRouteTable#{az_i}")
      end

      unless tier[:ForbidInternetAccess]
        resource "#{tier[:Name]}DefaultPrivateRoute#{az_i}", 'AWS::EC2::Route' do
          route_table_id ref("#{tier[:Name]}PrivateRouteTable#{az_i}")
          nat_gateway_id ref("NAT#{az_i % nat_count}")

          destination_cidr_block '0.0.0.0/0'
        end
      end

    end
  end
end

