# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalPlatform::Gateway do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_platform_gateway, store: store) }

  describe 'validations' do
    it 'requires client_id' do
      gateway.preferred_client_id = nil
      expect(gateway).not_to be_valid
    end

    it 'requires client_secret' do
      gateway.preferred_client_secret = nil
      expect(gateway).not_to be_valid
    end
  end

  describe '#session_required?' do
    it 'returns true' do
      expect(gateway.session_required?).to be true
    end
  end

  describe '#payment_session_class' do
    it 'returns Spree::PaymentSessions::PaypalPlatform' do
      expect(gateway.payment_session_class).to eq(Spree::PaymentSessions::PaypalPlatform)
    end
  end

  describe '#payment_source_class' do
    it 'returns the PayPal wallet source' do
      expect(gateway.payment_source_class).to eq(Spree::PaypalPlatform::PaymentSources::Paypal)
    end
  end

  describe '#method_type' do
    it 'returns spree_paypal_platform' do
      expect(gateway.method_type).to eq('spree_paypal_platform')
    end
  end

  describe '#default_name' do
    it 'returns PayPal' do
      expect(gateway.default_name).to eq('PayPal')
    end
  end

  describe '#apple_pay_enabled?' do
    it 'is true by default' do
      expect(gateway.apple_pay_enabled?).to be true
    end
  end

  it 'does not define an unused apple_pay_domain preference' do
    expect(gateway.has_preference?(:apple_pay_domain)).to be false
  end

  describe '#client' do
    it 'returns a PayPal SDK client' do
      expect(gateway.client).to be_a(PaypalServerSdk::Client)
    end
  end

  describe '#authorize' do
    it 'raises NotImplementedError' do
      expect { gateway.authorize(1000, double) }.to raise_error(NotImplementedError)
    end
  end

  describe '#client logging' do
    it 'does not log PayPal request bodies' do
      allow(PaypalServerSdk::RequestLoggingConfiguration).to receive(:new).and_call_original

      gateway.client

      expect(PaypalServerSdk::RequestLoggingConfiguration).to have_received(:new).with(
        hash_including(log_body: false)
      )
    end
  end

  describe '#purchase' do
    let(:payment_source) { double(paypal_id: 'PAYPAL-ORDER-123') }

    it 'delegates to capture with the paypal_id' do
      allow(gateway).to receive(:capture)
      gateway.purchase(1000, payment_source)
      expect(gateway).to have_received(:capture).with(1000, 'PAYPAL-ORDER-123', {})
    end
  end

  describe '#capture' do
    let(:order) { create(:order, store: store) }
    let(:gateway_options) { { order_id: "#{order.number}-123" } }
    let(:paypal_id) { 'PAYPAL-ORDER-123' }

    context 'when capture is successful' do
      let(:response_data) { double(status: 'COMPLETED', id: paypal_id, as_json: { 'id' => paypal_id }) }
      let(:response) { double(data: response_data) }

      before do
        orders_api = double
        allow(gateway).to receive(:client).and_return(double(orders: orders_api))
        allow(orders_api).to receive(:capture_order).with({
                                                            'id' => paypal_id,
                                                            'prefer' => 'return=representation'
                                                          }).and_return(response)
      end

      it 'returns a successful billing response' do
        result = gateway.capture(1000, paypal_id, gateway_options)
        expect(result.success?).to be true
      end
    end

    context 'when capture status is not COMPLETED' do
      let(:response_data) { double(status: 'PENDING', id: paypal_id, as_json: { 'id' => paypal_id }) }
      let(:response) { double(data: response_data) }

      before do
        orders_api = double
        allow(gateway).to receive(:client).and_return(double(orders: orders_api))
        allow(orders_api).to receive(:capture_order).and_return(response)
      end

      it 'returns a failure response' do
        result = gateway.capture(1000, paypal_id, gateway_options)
        expect(result.success?).to be false
      end
    end

    context 'when the order is not found' do
      it 'returns a failure response' do
        result = gateway.capture(1000, paypal_id, { order_id: 'NONEXISTENT-123' })
        expect(result.message).to eq('Order not found')
      end
    end

    context 'when PayPal API raises an error' do
      before do
        orders_api = double
        allow(gateway).to receive(:client).and_return(double(orders: orders_api))
        allow(orders_api).to receive(:capture_order).and_raise(
          PaypalServerSdk::APIException.new('The specified resource does not exist.', double(status_code: 404))
        )
      end

      it 'raises a GatewayError' do
        expect do
          gateway.capture(1000, paypal_id, gateway_options)
        end.to raise_error(Spree::Core::GatewayError, /PayPal API error/)
      end
    end
  end

  describe '#create_profile' do
    let(:user) { create(:user) }
    let(:order) { create(:order_with_line_items, user: user, store: store) }
    let(:payment_source) do
      Spree::PaypalPlatform::PaymentSources::Paypal.create!(
        payment_method: gateway,
        account_id: 'PAYPAL-ACCOUNT-123'
      )
    end
    let(:payment) { create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total) }

    it 'creates a gateway customer record' do
      expect { gateway.create_profile(payment) }.to change(Spree::GatewayCustomer, :count).by(1)
    end

    context 'when the source is Apple Pay' do
      let(:payment_source) { create(:paypal_platform_apple_pay_source, payment_method: gateway) }

      it 'does not create a gateway customer' do
        expect(gateway.create_profile(payment)).to be_nil
      end
    end
  end

  describe '#void' do
    let(:authorization) { 'AUTH-123' }
    let(:response_data) { double(as_json: { 'id' => authorization }) }
    let(:response) { double(data: response_data) }

    before do
      payments_api = double
      allow(gateway).to receive(:client).and_return(double(payments: payments_api))
      allow(payments_api).to receive(:void_payment).with(
        { 'authorization_id' => authorization, 'prefer' => 'return=representation' }
      ).and_return(response)
    end

    it 'returns a successful billing response' do
      expect(gateway.void(authorization, nil).success?).to be true
    end

    context 'when PayPal API raises an error' do
      before do
        payments_api = double
        allow(gateway).to receive(:client).and_return(double(payments: payments_api))
        allow(payments_api).to receive(:void_payment).and_raise(
          PaypalServerSdk::APIException.new('Void failed', double(status_code: 422))
        )
      end

      it 'raises a GatewayError' do
        expect { gateway.void(authorization, nil) }.to raise_error(Spree::Core::GatewayError, /PayPal API error/)
      end
    end
  end

  describe '#credit' do
    let(:order) { create(:order, store: store, currency: 'USD') }
    let(:refund) { double(order: order) }
    let(:gateway_options) { { originator: refund } }
    let(:capture_id) { 'CAPTURE-123' }
    let(:refund_id) { 'REFUND-456' }
    let(:response_data) { double(id: refund_id, as_json: { 'id' => refund_id }) }
    let(:response) { double(data: response_data) }

    before do
      payments_api = double
      allow(gateway).to receive(:client).and_return(double(payments: payments_api))
      allow(payments_api).to receive(:refund_captured_payment).with(
        {
          'capture_id' => capture_id,
          'amount' => { 'value' => '10.0', 'currency_code' => 'USD' }
        }
      ).and_return(response)
    end

    it 'returns a successful billing response with the refund ID' do
      expect(gateway.credit(1000, nil, capture_id, gateway_options).authorization).to eq(refund_id)
    end

    context 'when the originator does not respond to order' do
      let(:gateway_options) { { originator: order } }

      it 'uses the originator as the order' do
        expect(gateway.credit(1000, nil, capture_id, gateway_options).success?).to be true
      end
    end

    context 'when the order is not found' do
      let(:gateway_options) { { originator: nil } }

      it 'returns a failure response' do
        expect(gateway.credit(1000, nil, capture_id, gateway_options).message).to eq('Order not found')
      end
    end
  end

  describe '#cancel' do
    let(:authorization) { 'AUTH-123' }

    context 'when the payment is completed and credit_allowed is zero' do
      let(:payment) { double(completed?: true, credit_allowed: 0) }

      it 'returns success without creating a refund' do
        expect(gateway.cancel(authorization, payment).authorization).to eq(authorization)
      end
    end

    context 'when the payment is not completed' do
      let(:payment) { double(completed?: false) }
      let(:response_data) { double(as_json: { 'id' => authorization }) }
      let(:response) { double(data: response_data) }

      before do
        payments_api = double
        allow(gateway).to receive(:client).and_return(double(payments: payments_api))
        allow(payments_api).to receive(:void_payment).and_return(response)
      end

      it 'voids the payment via PayPal' do
        expect(gateway.cancel(authorization, payment).success?).to be true
      end
    end
  end
end
