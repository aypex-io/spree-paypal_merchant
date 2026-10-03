# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaymentSessions::PaypalMerchant do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:user) { create(:user) }
  let(:order) { create(:order_with_line_items, store: store, user: user) }
  let(:captured_data) do
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/captured_paypal_order.json')))
  end

  describe '#paypal_order_id' do
    let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_id: 'ORDER-123') }

    it 'returns the external_id' do
      expect(session.paypal_order_id).to eq('ORDER-123')
    end
  end

  describe '#paypal_capture_id' do
    context 'when the order is captured' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_data: captured_data) }

      it 'returns the capture ID from external_data' do
        expect(session.paypal_capture_id).to eq('6F473251BB811841E')
      end
    end

    context 'when the order is not captured' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway) }

      it 'returns nil' do
        expect(session.paypal_capture_id).to be_nil
      end
    end
  end

  describe '#accepted?' do
    context 'when status is COMPLETED' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_data: captured_data) }

      it 'returns true' do
        expect(session.accepted?).to be true
      end
    end

    context 'when status is not COMPLETED' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway) }

      it 'returns false' do
        expect(session.accepted?).to be false
      end
    end
  end

  describe '#find_or_create_payment!' do
    let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_data: captured_data) }

    it 'creates a Spree::Payment record' do
      expect { session.find_or_create_payment! }.to change(Spree::Payment, :count).by(1)
    end

    it 'sets the response_code to the capture ID' do
      payment = session.find_or_create_payment!
      expect(payment.response_code).to eq('6F473251BB811841E')
    end

    it 'creates a PayPal payment source' do
      payment = session.find_or_create_payment!
      expect(payment.source).to be_a(Spree::PaypalMerchant::PaymentSources::Paypal)
    end

    it 'does not create duplicate payments' do
      session.find_or_create_payment!
      expect { session.find_or_create_payment! }.not_to change(Spree::Payment, :count)
    end

    context 'when the captured source is Apple Pay' do
      let(:apple_pay_data) do
        JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/captured_apple_pay_order.json')))
      end
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_data: apple_pay_data) }

      it 'creates an Apple Pay payment source' do
        payment = session.find_or_create_payment!
        expect(payment.source).to be_a(Spree::PaypalMerchant::PaymentSources::ApplePay)
      end
    end

    context 'when payment_source data is not present' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway, external_data: captured_data.except('payment_source')) }

      it 'creates a payment without a source' do
        payment = session.find_or_create_payment!
        expect(payment.source).to be_nil
      end
    end

    context 'when capture has not happened yet' do
      let(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway) }

      it 'returns nil' do
        expect(session.find_or_create_payment!).to be_nil
      end
    end
  end
end
