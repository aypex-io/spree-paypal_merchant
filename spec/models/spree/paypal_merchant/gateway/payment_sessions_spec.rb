# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::Gateway::PaymentSessions do
  def fixture(name)
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join("spec/fixtures/#{name}.json")))
  end

  # A PayPal order as the SDK returns it.
  def paypal_response(data)
    order = instance_double(PaypalServerSdk::Order, id: data['id'], status: data['status'], as_json: data)
    instance_double(PaypalServerSdk::ApiResponse, data: order)
  end

  # The captured order fixture, with its capture at the given status.
  def captured_order(capture_status)
    fixture('captured_paypal_order').tap do |data|
      data['purchase_units'][0]['payments']['captures'][0]['status'] = capture_status
    end
  end

  def paypal_api_error(status_code)
    PaypalServerSdk::APIException.new("PayPal returned #{status_code}", double(status_code: status_code))
  end

  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:customer) { create(:user) }
  let(:cart) { create(:cart_with_line_items, store: store, customer: customer) }
  let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }

  before do
    allow(gateway).to receive(:client).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
  end

  describe '#create_payment_session' do
    let(:presenter) { instance_double(Spree::PaypalMerchant::OrderPresenter, to_json: { 'body' => 'order request' }) }

    before do
      # The request body is the presenter's concern, covered by its own spec.
      allow(Spree::PaypalMerchant::OrderPresenter).to receive(:new).and_return(presenter)
      allow(orders_api).to receive(:create_order).and_return(paypal_response(fixture('paypal_order')))
      allow(gateway).to receive(:generate_client_token).and_return('test-client-token')
    end

    it 'persists a payment session' do
      expect do
        gateway.create_payment_session(order: cart)
      end.to change(Spree::PaymentSessions::PaypalMerchant, :count).by(1)
    end

    it 'gives the session to the cart' do
      expect(gateway.create_payment_session(order: cart).cart).to eq(cart)
    end

    it 'leaves the session without an order' do
      expect(gateway.create_payment_session(order: cart).order).to be_nil
    end

    it 'records the cart customer on the session' do
      expect(gateway.create_payment_session(order: cart).customer).to eq(customer)
    end

    it 'keys the session on the PayPal order id' do
      expect(gateway.create_payment_session(order: cart).external_id).to eq('9DP54594E6135602P')
    end

    it 'sends the cart to PayPal for the amount due' do
      gateway.create_payment_session(order: cart)

      expect(Spree::PaypalMerchant::OrderPresenter).to have_received(:new).with(cart, amount: cart.total_minus_store_credits)
    end

    it 'keeps the keys the storefront reads in external_data' do
      session = gateway.create_payment_session(order: cart)

      expect(session.external_data).to include(
        'id' => '9DP54594E6135602P',
        'status' => 'CREATED',
        'client_token' => 'test-client-token',
        'enable_apple_pay' => true,
        'enable_card_fields' => true
      )
    end

    context 'when the cart belongs to a guest' do
      let(:cart) { create(:cart_with_line_items, store: store) }

      it 'creates a session with no customer' do
        session = gateway.create_payment_session(order: cart)

        expect(session).to have_attributes(persisted?: true, customer: nil)
      end
    end

    context 'when card fields are disabled' do
      before { gateway.preferred_enable_card_fields = false }

      it 'does not request a client token' do
        gateway.create_payment_session(order: cart)

        expect(gateway).not_to have_received(:generate_client_token)
      end

      it 'tells the storefront card fields are off' do
        session = gateway.create_payment_session(order: cart)

        expect(session.external_data['enable_card_fields']).to be false
      end

      it 'stores no client token' do
        session = gateway.create_payment_session(order: cart)

        expect(session.external_data).not_to have_key('client_token')
      end
    end

    context 'when the client token cannot be generated' do
      before { allow(gateway).to receive(:generate_client_token).and_return(nil) }

      it 'still creates the session without a client token' do
        session = gateway.create_payment_session(order: cart)

        expect(session.external_data).not_to have_key('client_token')
      end
    end

    context 'when a gift card or store credit covers part of the cart' do
      let(:amount_due) { cart.total - 4 }

      before do
        allow(Spree::PaypalMerchant::OrderPresenter).to receive(:new).and_call_original
        allow(cart).to receive(:total_minus_store_credits).and_return(amount_due)
      end

      it 'asks PayPal for only the amount due' do
        gateway.create_payment_session(order: cart)

        expect(orders_api).to have_received(:create_order) do |request|
          expect(request['body'].purchase_units[0].amount.value.to_d).to eq(amount_due)
        end
      end

      it 'sets the session amount to the amount due' do
        expect(gateway.create_payment_session(order: cart).amount).to eq(amount_due)
      end
    end

    context 'when nothing is due' do
      it 'raises a gateway error' do
        expect do
          gateway.create_payment_session(order: cart, amount: 0)
        end.to raise_error(Spree::Core::GatewayError)
      end

      it 'does not create a PayPal order' do
        expect { gateway.create_payment_session(order: cart, amount: 0) }.to raise_error(Spree::Core::GatewayError)

        expect(orders_api).not_to have_received(:create_order)
      end
    end

    %w[on_dispatch manual].each do |capture_method|
      context "when the gateway itself is set to capture #{capture_method}" do
        before { gateway.update!(capture_method: capture_method) }

        it 'raises a gateway error' do
          expect do
            gateway.create_payment_session(order: cart)
          end.to raise_error(Spree::Core::GatewayError, /captures at checkout/)
        end

        it 'does not create a PayPal order' do
          expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError)

          expect(orders_api).not_to have_received(:create_order)
        end
      end
    end

    context 'when the gateway is explicitly set to capture at checkout' do
      before { gateway.update!(capture_method: 'checkout') }

      it 'creates the session' do
        expect(gateway.create_payment_session(order: cart)).to be_persisted
      end
    end

    # A store-wide default must not switch PayPal off: it always captures at checkout.
    context 'when only the store defaults to capture on dispatch' do
      before { store.update!(preferred_capture_method: 'on_dispatch') }

      it 'creates the session' do
        expect(gateway.create_payment_session(order: cart)).to be_persisted
      end
    end

    context 'when the cart has an open PayPal session' do
      let!(:open_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

      before { allow(orders_api).to receive(:get_order).and_return(paypal_response(fixture('paypal_order'))) }

      it 'cancels the open session' do
        gateway.create_payment_session(order: cart)

        expect(open_session.reload).to be_canceled
      end

      it 'creates a new pending session' do
        session = gateway.create_payment_session(order: cart)

        expect(session).to have_attributes(persisted?: true, status: 'pending')
      end
    end

    context 'when the cart has a failed PayPal session' do
      let!(:failed_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, status: 'failed') }

      before { allow(orders_api).to receive(:get_order).and_return(paypal_response(fixture('paypal_order'))) }

      it 'cancels the failed session' do
        gateway.create_payment_session(order: cart)

        expect(failed_session.reload).to be_canceled
      end
    end

    context 'when the cart already has a completed PayPal session' do
      before { create(:completed_paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

      it 'raises a gateway error' do
        expect do
          gateway.create_payment_session(order: cart)
        end.to raise_error(Spree::Core::GatewayError)
      end

      it 'does not create a PayPal order' do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError)

        expect(orders_api).not_to have_received(:create_order)
      end
    end

    context 'when an open session has already been paid at PayPal' do
      let!(:open_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

      before { allow(orders_api).to receive(:get_order).and_return(paypal_response(captured_order('COMPLETED'))) }

      it 'raises a gateway error and leaves the session open' do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError)

        expect(open_session.reload).to be_pending
      end
    end

    context 'when PayPal cannot be reached about an open session' do
      let!(:open_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

      before { allow(orders_api).to receive(:get_order).and_raise(Net::ReadTimeout) }

      it 'raises a gateway error and leaves the session open' do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError)

        expect(open_session.reload).to be_pending
      end
    end

    context 'when the cart has an open session for another payment method' do
      let(:other_gateway) { create(:paypal_merchant_gateway, store: store) }
      let!(:other_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: other_gateway) }

      it 'leaves that session alone' do
        gateway.create_payment_session(order: cart)

        expect(other_session.reload).to be_pending
      end
    end
  end

  describe '#update_payment_session' do
    let(:payment_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

    it 'updates the amount' do
      gateway.update_payment_session(payment_session: payment_session, amount: 99.99)
      expect(payment_session.reload.amount).to eq(99.99)
    end
  end

  describe '#complete_payment_session' do
    let(:payment_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }
    let(:approved_order) { { 'id' => payment_session.external_id, 'status' => 'APPROVED' } }
    let(:captured) { captured_order('COMPLETED') }

    before do
      allow(orders_api).to receive_messages(get_order: paypal_response(approved_order), capture_order: paypal_response(captured))
    end

    def complete
      gateway.complete_payment_session(payment_session: payment_session)
    end

    it 'captures the approved PayPal order' do
      complete

      expect(orders_api).to have_received(:capture_order).with('id' => payment_session.external_id, 'prefer' => 'return=representation')
    end

    it 'returns the session' do
      expect(complete).to eq(payment_session)
    end

    it 'stores the captured PayPal order on the session' do
      complete

      expect(payment_session.reload.external_data).to eq(captured)
    end

    context 'when the capture is COMPLETED' do
      it 'completes the session' do
        complete

        expect(payment_session.reload).to be_completed
      end

      it 'creates one payment on the cart, keyed on the PayPal order id' do
        complete

        expect(cart.payments.pluck(:response_code)).to eq([payment_session.external_id])
      end

      it 'completes the payment' do
        complete

        expect(cart.payments.sole).to be_completed
      end

      it 'records the PayPal capture id on the payment' do
        complete

        expect(cart.payments.sole.metadata['paypal_capture_id']).to eq('6F473251BB811841E')
      end

      it 'does not place the cart' do
        complete

        expect(cart.reload).to have_attributes(completed_at: nil, order: nil)
      end

      it 'records a gateway customer profile for the buyer' do
        complete

        expect(gateway.gateway_customers.where(customer: customer).pluck(:profile_id)).to eq(['RX8ZD67CZ67RU'])
      end

      context 'when the cart belongs to a guest' do
        let(:cart) { create(:cart_with_line_items, store: store) }

        it 'completes the session without a gateway customer profile' do
          complete

          expect([payment_session.reload.status, gateway.gateway_customers.count]).to eq(['completed', 0])
        end
      end
    end

    context 'when the capture is PENDING' do
      let(:captured) { captured_order('PENDING') }

      it 'completes the session' do
        complete

        expect(payment_session.reload).to be_completed
      end

      it 'creates a payment that is not completed yet' do
        complete

        expect(cart.payments.sole).to have_attributes(completed?: false, pending?: true)
      end
    end

    # PayPal can report the order COMPLETED while the capture inside it failed.
    %w[DECLINED FAILED].each do |capture_status|
      context "when the order is COMPLETED but its capture is #{capture_status}" do
        let(:captured) { captured_order(capture_status) }

        it 'fails the session' do
          complete

          expect(payment_session.reload).to be_failed
        end

        it 'creates no payment' do
          complete

          expect(cart.payments).to be_empty
        end
      end
    end

    context 'when the PayPal order has no capture' do
      let(:captured) { fixture('captured_paypal_order').tap { |data| data['purchase_units'][0].delete('payments') } }

      it 'fails the session' do
        complete

        expect(payment_session.reload).to be_failed
      end

      it 'creates no payment' do
        complete

        expect(cart.payments).to be_empty
      end
    end

    context 'when PayPal has already captured (Apple Pay confirmOrder)' do
      let(:approved_order) { captured }

      it 'does not capture again' do
        complete

        expect(orders_api).not_to have_received(:capture_order)
      end

      it 'completes the session' do
        complete

        expect(payment_session.reload).to be_completed
      end
    end

    context 'when the PayPal order amount no longer matches the amount due' do
      # e.g. a gift card applied, or the cart changed, after the PayPal order
      # was created. Capturing would take the stale amount.
      let(:approved_order) do
        {
          'id' => payment_session.external_id,
          'status' => 'APPROVED',
          'purchase_units' => [{ 'amount' => { 'currency_code' => 'USD', 'value' => (cart.total + 20).to_s } }]
        }
      end

      it 'does not capture, fails the session and raises' do
        expect { complete }.to raise_error(Spree::Core::GatewayError, /does not match the amount due/)

        expect(orders_api).not_to have_received(:capture_order)
        expect(payment_session.reload.status).to eq('failed')
      end
    end

    context 'when the PayPal order amount matches the amount due' do
      let(:approved_order) do
        {
          'id' => payment_session.external_id,
          'status' => 'APPROVED',
          'purchase_units' => [{ 'amount' => { 'currency_code' => 'USD', 'value' => format('%.2f', cart.total) } }]
        }
      end

      it 'captures' do
        complete

        expect(orders_api).to have_received(:capture_order)
      end
    end

    context 'when PayPal API raises an error' do
      before { allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(422)) }

      it 'marks the session as failed and raises GatewayError' do
        expect { complete }.to raise_error(Spree::Core::GatewayError, /PayPal API error/)

        expect(payment_session.reload.status).to eq('failed')
      end
    end

    # A stale browser tab must never capture for a session that can no longer be used.
    %w[canceled failed].each do |status|
      context "when the session is #{status}" do
        before { payment_session.update!(status: status) }

        it 'raises a gateway error without capturing' do
          expect { complete }.to raise_error(Spree::Core::GatewayError)

          expect(orders_api).not_to have_received(:capture_order)
        end
      end
    end

    context 'when the session belongs to a placed order' do
      let(:placed_order) { create(:order, store: store) }
      let(:payment_session) do
        create(:paypal_merchant_payment_session, cart: nil, order: placed_order, payment_method: gateway, amount: 10)
      end

      it 'raises a gateway error without capturing' do
        expect { complete }.to raise_error(Spree::Core::GatewayError)

        expect(orders_api).not_to have_received(:capture_order)
      end
    end
  end

  describe '#cancel_payment_session' do
    let(:payment_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway) }

    def cancel
      gateway.cancel_payment_session(payment_session: payment_session)
    end

    context 'when the PayPal order has not been captured' do
      before { allow(orders_api).to receive(:get_order).and_return(paypal_response(fixture('paypal_order'))) }

      it 'returns true' do
        expect(cancel).to be true
      end

      it 'cancels the session' do
        cancel

        expect(payment_session.reload).to be_canceled
      end

      it 'reads the PayPal order for the session' do
        cancel

        expect(orders_api).to have_received(:get_order).with('id' => payment_session.external_id, 'prefer' => 'return=representation')
      end
    end

    # Money has moved, or is on its way: canceling would hide it.
    %w[COMPLETED PENDING].each do |capture_status|
      context "when the capture is #{capture_status}" do
        before { allow(orders_api).to receive(:get_order).and_return(paypal_response(captured_order(capture_status))) }

        it 'raises a gateway error and leaves the session unchanged' do
          expect { cancel }.to raise_error(Spree::Core::GatewayError)

          expect(payment_session.reload).to be_pending
        end
      end
    end

    context 'when the capture was declined' do
      before { allow(orders_api).to receive(:get_order).and_return(paypal_response(captured_order('DECLINED'))) }

      it 'cancels the session' do
        expect(cancel).to be true
      end
    end

    # An order PayPal does not know for these credentials can never be paid.
    context 'when PayPal does not know the order' do
      before { allow(orders_api).to receive(:get_order).and_raise(paypal_api_error(404)) }

      it 'cancels the session' do
        cancel

        expect(payment_session.reload).to be_canceled
      end
    end

    # Not a refusal: the caller has to be able to ask again.
    context 'when PayPal times out' do
      before { allow(orders_api).to receive(:get_order).and_raise(Net::ReadTimeout) }

      it 'raises the timeout as itself and leaves the session unchanged' do
        expect { cancel }.to raise_error(Net::ReadTimeout)

        expect(payment_session.reload).to be_pending
      end
    end

    context 'when PayPal returns a server error' do
      before { allow(orders_api).to receive(:get_order).and_raise(paypal_api_error(503)) }

      it 'raises the API error as itself' do
        expect { cancel }.to raise_error(PaypalServerSdk::APIException)
      end
    end
  end

  describe '#parse_webhook_event' do
    let(:payment_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, external_id: 'ORDER-123') }
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
