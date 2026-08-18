# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Api::V3::PaymentMethodSerializer do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_platform_gateway, store: store) }

  it 'includes public funding preferences' do
    payload = described_class.new(gateway).to_h
    prefs = payload[:public_preferences] || payload['public_preferences']
    expect(prefs).to include('enable_apple_pay' => true).or include(enable_apple_pay: true)
    expect(prefs).to include('enable_card_fields' => true).or include(enable_card_fields: true)
  end
end
