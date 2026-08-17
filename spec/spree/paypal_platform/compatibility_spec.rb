# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'historical PayPal Checkout STI type names' do
  it 'includes the official gem type string' do
    expect(Spree::PaypalPlatform.gateway_type_names).to include('SpreePaypalCheckout::Gateway')
  end

  it 'includes the short-lived Spree::PaypalCheckout type string' do
    expect(Spree::PaypalPlatform.gateway_type_names).to include('Spree::PaypalCheckout::Gateway')
  end

  it 'includes the current type string' do
    expect(Spree::PaypalPlatform.gateway_type_names).to include('Spree::PaypalPlatform::Gateway')
  end
end
