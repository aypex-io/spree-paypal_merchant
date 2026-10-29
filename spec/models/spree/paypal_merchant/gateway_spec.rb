# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::Gateway do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }

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
    it 'returns Spree::PaymentSessions::PaypalMerchant' do
      expect(gateway.payment_session_class).to eq(Spree::PaymentSessions::PaypalMerchant)
    end
  end

  describe '#payment_source_class' do
    it 'returns the PayPal wallet source' do
      expect(gateway.payment_source_class).to eq(Spree::PaypalMerchant::PaymentSources::Paypal)
    end
  end

  describe '#method_type' do
    it 'returns spree_paypal_merchant' do
      expect(gateway.method_type).to eq('spree_paypal_merchant')
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

  describe 'public funding preferences' do
    it 'exposes apple pay and card fields flags' do
      expect(gateway.public_preferences).to include(enable_apple_pay: true, enable_card_fields: true)
    end

    it 'reflects disabled card fields' do
      gateway.preferred_enable_card_fields = false
      expect(gateway.card_fields_enabled?).to be false
    end
  end

  it 'has no pre-session capture flow' do
    # Spree::Gateway delegates authorize/purchase/capture to #provider, so
    # respond_to? is always true; check that this gateway defines none itself.
    own_methods = described_class.instance_methods(false) + described_class.private_instance_methods(false)

    expect(own_methods).not_to include(:authorize, :purchase, :capture, :find_order)
    expect(defined?(Spree::PaypalMerchant::Order)).to be_nil
    expect(Spree::Order.new).not_to respond_to(:paypal_id)
  end

  it "finds the store's active PayPal gateway" do
    gateway

    expect(store.paypal_merchant_gateway).to eq(gateway)
    expect(Spree::PaymentMethod.paypal_merchant).to include(gateway)
  end

  describe '#client' do
    it 'returns a PayPal SDK client' do
      expect(gateway.client).to be_a(PaypalServerSdk::Client)
    end
  end

  describe '#client limits' do
    before { allow(PaypalServerSdk::Client).to receive(:new).and_call_original }

    it 'builds the client with the request timeout and the retry count' do
      gateway.client

      expect(PaypalServerSdk::Client).to have_received(:new).with(
        hash_including(timeout: Spree::PaypalMerchant::Gateway::REQUEST_TIMEOUT, max_retries: Spree::PaypalMerchant::Gateway::MAX_RETRIES)
      )
    end

    it 'limits a request to 15 seconds and retries a read 3 times' do
      expect([Spree::PaypalMerchant::Gateway::REQUEST_TIMEOUT, Spree::PaypalMerchant::Gateway::MAX_RETRIES]).to eq([15, 3])
    end
  end

  # Stubbed at the HTTP level, so the SDK's own retry middleware is what runs.
  describe '#client retries' do
    let(:paypal_api) { 'https://api-m.sandbox.paypal.com' }
    let(:order_url) { "#{paypal_api}/v2/checkout/orders/ORDER-1" }
    let(:json_headers) { { 'Content-Type' => 'application/json' } }
    let(:order_body) { { id: 'ORDER-1', status: 'APPROVED' }.to_json }

    before do
      stub_request(:post, "#{paypal_api}/v1/oauth2/token")
        .to_return(status: 200, headers: json_headers, body: { access_token: 'token', token_type: 'Bearer', expires_in: 32_400 }.to_json)
      # The wait between attempts is the SDK's default; the specs do not sit through it.
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
    end

    it 'retries a read that PayPal answers with a server error' do
      stub_request(:get, order_url)
        .to_return({ status: 503, headers: json_headers, body: '{}' }, { status: 200, headers: json_headers, body: order_body })

      expect(gateway.fetch_paypal_order('ORDER-1').data).to have_attributes(id: 'ORDER-1', status: 'APPROVED')
      expect(a_request(:get, order_url)).to have_been_made.twice
    end

    it 'gives up on a read after the third retry' do
      stub_request(:get, order_url).to_return(status: 503, headers: json_headers, body: '{}')

      expect { gateway.fetch_paypal_order('ORDER-1') }.to raise_error(PaypalServerSdk::APIException)
      expect(a_request(:get, order_url)).to have_been_made.times(1 + Spree::PaypalMerchant::Gateway::MAX_RETRIES)
    end

    it 'never sends a capture twice, so a retry cannot capture a second time' do
      stub_request(:post, "#{order_url}/capture").to_return(status: 503, headers: json_headers, body: '{}')

      expect { gateway.client.orders.capture_order('id' => 'ORDER-1') }.to raise_error(PaypalServerSdk::APIException)
      expect(a_request(:post, "#{order_url}/capture")).to have_been_made.once
    end
  end

  describe '#fetch_paypal_order' do
    let(:orders_api) { instance_double(PaypalServerSdk::OrdersController, get_order: paypal_response) }
    let(:paypal_response) { double(data: double(status: 'COMPLETED')) }

    before { allow(gateway).to receive(:client).and_return(double(orders: orders_api)) }

    it 'asks PayPal for the order with its captures' do
      gateway.fetch_paypal_order('ORDER-1')

      expect(orders_api).to have_received(:get_order).with('id' => 'ORDER-1', 'prefer' => 'return=representation')
    end

    it 'returns the PayPal response' do
      expect(gateway.fetch_paypal_order('ORDER-1')).to eq(paypal_response)
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

  describe '#create_profile' do
    let(:user) { create(:user) }
    let(:order) { create(:order_with_line_items, customer: user, store: store) }
    let(:payment_source) do
      Spree::PaypalMerchant::PaymentSources::Paypal.create!(
        payment_method: gateway,
        account_id: 'PAYPAL-ACCOUNT-123'
      )
    end
    let(:payment) { create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total) }

    it 'creates a gateway customer record' do
      expect { gateway.create_profile(payment) }.to change(Spree::GatewayCustomer, :count).by(1)
    end

    context 'when the source is Apple Pay' do
      let(:payment_source) { create(:paypal_merchant_apple_pay_source, payment_method: gateway) }

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
