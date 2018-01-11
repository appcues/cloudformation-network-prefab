require 'cfer/groups'
require 'cfer/prefab/network'

resource :Network, 'Cfer::Prefab::Network' do
  nat_count 1

  properties(AvailabilityZones: (0..3).map { |az| Fn::select(az, Fn::get_azs(AWS::region)) })

  cidr_block '10.0.0.0/16'
  tier_size 22

  tiers \
    Private: {
      ForbidInternetAccess: false
    },
    Data: {
      ForbidInternetAccess: true
    }

  tag :Network, true
end


