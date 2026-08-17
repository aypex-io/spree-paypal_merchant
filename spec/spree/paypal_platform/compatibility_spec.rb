# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'gateway type names' do
  it 'includes the gateway type string' do
    expect(Spree::PaypalPlatform.gateway_type_names).to include('Spree::PaypalPlatform::Gateway')
  end
end
