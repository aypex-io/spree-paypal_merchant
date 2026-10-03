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
end
