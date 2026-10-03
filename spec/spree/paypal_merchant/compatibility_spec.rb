# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'gateway type names' do
  it 'includes the gateway type string' do
    expect(Spree::PaypalMerchant.gateway_type_names).to include('Spree::PaypalMerchant::Gateway')
  end
end
