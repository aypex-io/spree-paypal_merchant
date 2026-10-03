# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::CaptureOrder do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:order) { create(:order_with_line_items, store: store, state: 'payment') }
  let(:paypal_order) { create(:paypal_merchant_order, order: order, payment_method: gateway) }
  let(:service) { described_class.new(paypal_order: paypal_order) }

  describe '#call' do
    it 'returns the paypal order when the Spree order is already completed' do
      allow(order).to receive(:completed?).and_return(true)

      expect(service.call).to eq(paypal_order)
    end

    it 'captures, creates a payment, and completes checkout' do
      captured = JSON.parse(
        File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/captured_paypal_order.json'))
      )
      gateway_response = Spree::PaypalMerchant::Gateway::GatewayResponse.new(
        true, 'ok', captured, captured['id']
      )
      checkout = class_double('CheckoutComplete', call: true)
      allow(gateway).to receive(:capture).and_return(gateway_response)
      allow(Spree::Dependencies).to receive(:checkout_complete_service).and_return('CheckoutComplete')
      stub_const('CheckoutComplete', checkout)

      service.call

      expect(paypal_order.reload).to be_completed
    end
  end
end
