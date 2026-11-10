# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::Api::V3::PaymentMethodSerializer do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }

  it 'includes public funding preferences' do
    payload = described_class.new(gateway).to_h
    prefs = payload[:public_preferences] || payload['public_preferences']
    expect(prefs).to include('enable_apple_pay' => true).or include(enable_apple_pay: true)
    expect(prefs).to include('enable_card_fields' => true).or include(enable_card_fields: true)
  end

  it 'exposes the client id and the express switch, never the secrets' do
    payload = described_class.new(gateway).to_h
    prefs = (payload[:public_preferences] || payload['public_preferences']).stringify_keys
    expect(prefs).to include('client_id' => gateway.preferred_client_id, 'enable_express_checkout' => true)
    expect(prefs.keys).not_to include('client_secret', 'webhook_secret')
  end
end
