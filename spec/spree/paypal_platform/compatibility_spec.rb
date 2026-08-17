# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'gateway type names' do
  it 'includes the current type string' do
    expect(Spree::PaypalPlatform.gateway_type_names).to include('Spree::PaypalPlatform::Gateway')
  end

  it 'does not include other PayPal gems' do
    expect(Spree::PaypalPlatform.gateway_type_names).not_to include(
      'SpreePaypalCheckout::Gateway',
      'Spree::PaypalCheckout::Gateway'
    )
  end
end
