# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalPlatform::Gateway::PaymentSessions do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_platform_gateway, store: store) }
  let(:user) { create(:user) }
  let(:order) { create(:order_with_line_items, store: store, user: user, state: 'payment') }

  describe '#create_payment_session' do
    let(:paypal_order_id) { '9DP54594E6135602P' }
    let(:paypal_response_data) do
      double(
        id: paypal_order_id,
        as_json: JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/paypal_order.json')))
      )
    end
    let(:paypal_response) { double(data: paypal_response_data) }

    before do
      orders_api = double
      allow(gateway).to receive(:client).and_return(double(orders: orders_api))
      allow(orders_api).to receive(:create_order).and_return(paypal_response)
      allow(gateway).to receive(:generate_client_token).and_return('test-client-token')
    end

    it 'creates a payment session record' do
      expect do
        gateway.create_payment_session(order: order)
      end.to change(Spree::PaymentSessions::PaypalPlatform, :count).by(1)
    end

    it 'stores a client token for Card Fields in external_data' do
      session = gateway.create_payment_session(order: order)
      expect(session.external_data['client_token']).to eq('test-client-token')
    end

    it 'advertises funding flags to the storefront' do
      session = gateway.create_payment_session(order: order)
      expect(session.external_data['enable_apple_pay']).to be true
      expect(session.external_data['enable_card_fields']).to be true
    end

    context 'when card fields are disabled' do
      before { gateway.preferred_enable_card_fields = false }

      it 'does not request a client token' do
        expect(gateway).not_to receive(:generate_client_token)
        session = gateway.create_payment_session(order: order)
        expect(session.external_data).not_to have_key('client_token')
        expect(session.external_data['enable_card_fields']).to be false
      end
    end

    context 'when the client token cannot be generated' do
      before { allow(gateway).to receive(:generate_client_token).and_return(nil) }

      it 'still creates the session without a client token' do
        session = gateway.create_payment_session(order: order)
        expect(session.external_data).not_to have_key('client_token')
      end
    end

    context 'when amount is zero' do
      it 'returns nil' do
        expect(gateway.create_payment_session(order: order, amount: 0)).to be_nil
      end
    end
  end

  describe '#update_payment_session' do
    let(:payment_session) { create(:paypal_platform_payment_session, order: order, payment_method: gateway) }

    it 'updates the amount' do
      gateway.update_payment_session(payment_session: payment_session, amount: 99.99)
      expect(payment_session.reload.amount).to eq(99.99)
    end
  end

  describe '#complete_payment_session' do
    let(:payment_session) { create(:paypal_platform_payment_session, order: order, payment_method: gateway) }
    let(:captured_data) { JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/captured_paypal_order.json'))) }
    let(:response_data) { double(status: 'COMPLETED', as_json: captured_data) }
    let(:response) { double(data: response_data) }

    let(:orders_api) { double }
    let(:fetched_data) { double(status: 'APPROVED', as_json: { 'status' => 'APPROVED' }) }
    let(:fetched) { double(data: fetched_data) }

    before do
      allow(gateway).to receive(:client).and_return(double(orders: orders_api))
      allow(orders_api).to receive(:get_order).and_return(fetched)
      allow(orders_api).to receive(:capture_order).and_return(response)
    end

    it 'creates a payment and marks the session completed' do
      expect do
        gateway.complete_payment_session(payment_session: payment_session)
      end.to change(Spree::Payment, :count).by(1)

      expect(payment_session.reload.status).to eq('completed')
    end

    context 'when PayPal has already captured (Apple Pay confirmOrder)' do
      let(:fetched_data) { double(status: 'COMPLETED', as_json: captured_data) }

      it 'does not capture again' do
        expect(orders_api).not_to receive(:capture_order)
        gateway.complete_payment_session(payment_session: payment_session)
        expect(payment_session.reload.status).to eq('completed')
      end
    end

    context 'when capture status is not COMPLETED' do
      let(:response_data) { double(status: 'PENDING', as_json: { 'status' => 'PENDING' }) }

      it 'marks the session as failed' do
        gateway.complete_payment_session(payment_session: payment_session)
        expect(payment_session.reload.status).to eq('failed')
      end
    end

    context 'when PayPal API raises an error' do
      before do
        allow(orders_api).to receive(:capture_order).and_raise(
          PaypalServerSdk::APIException.new('Capture failed', double(status_code: 422))
        )
      end

      it 'marks the session as failed and raises GatewayError' do
        expect do
          gateway.complete_payment_session(payment_session: payment_session)
        end.to raise_error(Spree::Core::GatewayError, /PayPal API error/)

        expect(payment_session.reload.status).to eq('failed')
      end
    end
  end

  describe '#parse_webhook_event' do
    let(:payment_session) { create(:paypal_platform_payment_session, order: order, payment_method: gateway, external_id: 'ORDER-123') }
    let(:raw_body) { { event_type: 'CHECKOUT.ORDER.APPROVED', resource: { 'id' => 'ORDER-123' } }.to_json }
    let(:signed_headers) do
      {
        'PAYPAL-TRANSMISSION-ID' => 'tx-1',
        'PAYPAL-TRANSMISSION-TIME' => '2026-08-17T00:00:00Z',
        'PAYPAL-CERT-URL' => 'https://api.paypal.com/cert',
        'PAYPAL-AUTH-ALGO' => 'SHA256withRSA',
        'PAYPAL-TRANSMISSION-SIG' => 'sig'
      }
    end

    before { payment_session }

    context 'when webhook_secret is blank in a local env' do
      before { gateway.update!(preferences: gateway.preferences.merge(webhook_secret: nil)) }

      it 'returns authorized action with the payment session' do
        result = gateway.parse_webhook_event(raw_body, {})
        expect(result[:action]).to eq(:authorized)
      end
    end

    context 'when webhook_secret is blank outside a local env' do
      before do
        gateway.update!(preferences: gateway.preferences.merge(webhook_secret: nil))
        allow(Rails.env).to receive(:local?).and_return(false)
      end

      it 'raises WebhookSignatureError' do
        expect do
          gateway.parse_webhook_event(raw_body, {})
        end.to raise_error(Spree::PaymentMethod::WebhookSignatureError, /webhook_secret is not configured/)
      end
    end

    context 'when webhook_secret is configured' do
      before { gateway.update!(preferences: gateway.preferences.merge(webhook_secret: 'WH-123')) }

      it 'raises when transmission headers are missing' do
        expect do
          gateway.parse_webhook_event(raw_body, {})
        end.to raise_error(Spree::PaymentMethod::WebhookSignatureError, /Missing PayPal webhook headers/)
      end

      it 'raises when PayPal reports an invalid signature' do
        stub_paypal_http(
          { 'access_token' => 'tok' },
          { 'verification_status' => 'FAILURE' }
        )

        expect do
          gateway.parse_webhook_event(raw_body, signed_headers)
        end.to raise_error(Spree::PaymentMethod::WebhookSignatureError, /Invalid webhook signature/)
      end

      it 'returns authorized when PayPal verifies the signature' do
        stub_paypal_http(
          { 'access_token' => 'tok' },
          { 'verification_status' => 'SUCCESS' }
        )

        result = gateway.parse_webhook_event(raw_body, signed_headers)
        expect(result[:action]).to eq(:authorized)
      end
    end

    context 'when the event is PAYMENT.CAPTURE.COMPLETED' do
      let(:raw_body) do
        { event_type: 'PAYMENT.CAPTURE.COMPLETED',
          resource: { 'id' => 'CAPTURE-456', 'supplementary_data' => { 'related_ids' => { 'order_id' => 'ORDER-123' } } } }.to_json
      end

      before { gateway.update!(preferences: gateway.preferences.merge(webhook_secret: nil)) }

      it 'returns captured action with the payment session' do
        result = gateway.parse_webhook_event(raw_body, {})
        expect(result[:action]).to eq(:captured)
      end
    end

    context 'when the payment session is not found' do
      let(:raw_body) { { event_type: 'CHECKOUT.ORDER.APPROVED', resource: { 'id' => 'UNKNOWN' } }.to_json }

      before { gateway.update!(preferences: gateway.preferences.merge(webhook_secret: nil)) }

      it 'returns nil' do
        expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
      end
    end
  end

  def stub_paypal_http(*bodies)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    responses = bodies.map { |body| instance_double(Net::HTTPSuccess, body: body.to_json, code: '200') }
    allow(http).to receive(:request).and_return(*responses)
    allow(Net::HTTP).to receive(:new).and_return(http)
  end
end
