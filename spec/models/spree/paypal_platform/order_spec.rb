# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalPlatform::Order do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_platform_gateway, store: store) }
  let(:order) { create(:order_with_line_items, store: store) }
  let(:paypal_platform_order) { create(:paypal_platform_order, order: order, payment_method: gateway) }

  describe '#paypal_payment_id' do
    context 'when the order is not captured' do
      it 'returns nil' do
        expect(paypal_platform_order.paypal_payment_id).to be_nil
      end
    end

    context 'when the order is captured' do
      let(:paypal_platform_order) { create(:captured_paypal_platform_order, order: order, payment_method: gateway, amount: order.total) }

      it 'returns the PayPal payment ID' do
        expect(paypal_platform_order.paypal_payment_id).to eq('6F473251BB811841E')
      end
    end
  end

  describe '#create_payment!' do
    subject { paypal_platform_order.create_payment! }

    context 'when the order is not captured' do
      it 'raises NotCapturedError' do
        expect { subject }.to raise_error(Spree::PaypalPlatform::Order::NotCapturedError)
      end
    end

    context 'when the order is captured' do
      let(:paypal_platform_order) { create(:captured_paypal_platform_order, order: order, payment_method: gateway, amount: order.total) }

      it 'creates a completed payment' do
        expect { subject }.to change(Spree::Payment, :count).by(1)
        expect(Spree::Payment.last.state).to eq('completed')
      end
    end
  end
end
