# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'payment method registration' do
  let(:registered) { Rails.application.config.spree.payment_methods }

  it 'registers the PayPal Checkout gateway' do
    expect(registered).to include(Spree::PaypalMerchant::Gateway)
  end

  it 'registers the gateway once' do
    expect(registered.count(Spree::PaypalMerchant::Gateway)).to eq(1)
  end

  it 'targets Spree 6' do
    expect(Gem.loaded_specs['spree_core'].version).to be >= Gem::Version.new('6.0.0')
    expect(defined?(Spree::Admin)).to be_nil
  end
end
