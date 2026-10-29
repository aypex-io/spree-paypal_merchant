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

  # The captured order fixture for the cart's total, with its capture at the
  # given status. The payment records the amount PayPal captured.
  def captured_order(capture_status)
    fixture('captured_paypal_order').tap do |data|
      total = format('%.2f', cart.total)
      data['purchase_units'][0]['amount']['value'] = total
      data['purchase_units'][0]['payments']['captures'][0].merge!('status' => capture_status, 'amount' => { 'currency_code' => 'USD', 'value' => total })
    end
  end

  def paypal_api_error(status_code)
    PaypalServerSdk::APIException.new("PayPal returned #{status_code}", double(status_code: status_code))
  end

  # An error as the SDK raises it for a PayPal error body naming an issue.
  def paypal_issue_error(status_code, issue)
    body = { name: 'UNPROCESSABLE_ENTITY', message: 'The requested action could not be performed.', details: [{ issue: issue }] }
    PaypalServerSdk::ErrorException.new('Unprocessable', double(status_code: status_code, raw_body: body.to_json))
  end

  # A PayPal error body with no message of its own, only issue descriptions:
  # the SDK's error then has a nil message.
  def paypal_error_without_message(status_code, description)
    body = { name: 'UNPROCESSABLE_ENTITY', details: [{ issue: 'INSTRUMENT_DECLINED', description: description }] }
    PaypalServerSdk::ErrorException.new('Unprocessable', double(status_code: status_code, raw_body: body.to_json))
  end

  # What the SDK raises for a PayPal server error whose body is not JSON (an
  # HTML error page): building its error fails before an APIException exists.
  def unreadable_paypal_answer
    PaypalServerSdk::ErrorException.new('Bad gateway', double(status_code: 502, raw_body: '<html>Bad gateway</html>'))
  rescue TypeError => e
    e
  end

  # Read from the database: the cart factory leaves `cart.payments` loaded,
  # so the association would not see a payment created through another copy.
  def payments_on_cart
    Spree::Payment.where(cart: cart)
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
    before do
      # The presenter builds the real request; its own spec covers the payload.
      allow(Spree::PaypalMerchant::OrderPresenter).to receive(:new).and_call_original
      allow(orders_api).to receive(:create_order).and_return(paypal_response(fixture('paypal_order')))
      allow(gateway).to receive(:generate_client_token).and_return('test-client-token')
    end

    it 'asks PayPal for the whole total, with a breakdown that adds up to it' do
      gateway.create_payment_session(order: cart)

      expect(orders_api).to have_received(:create_order) do |request|
        amount = request['body'].purchase_units[0].amount
        charges = %i[item_total shipping handling tax_total].sum { |field| (amount.breakdown.public_send(field)&.value || 0).to_d }
        discounts = %i[shipping_discount discount].sum { |field| (amount.breakdown.public_send(field)&.value || 0).to_d }

        expect([amount.value.to_d, charges - discounts]).to eq([cart.total, cart.total])
      end
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

      before { allow(cart).to receive(:total_minus_store_credits).and_return(amount_due) }

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

      before { allow(orders_api).to receive(:get_order).and_raise(Faraday::TimeoutError) }

      it 'raises a gateway error and leaves the session open' do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError, /connection error/)

        expect(open_session.reload).to be_pending
      end
    end

    context 'when PayPal sends a server error that is not JSON' do
      before { allow(orders_api).to receive(:create_order).and_raise(unreadable_paypal_answer) }

      it 'raises a gateway error saying PayPal sent an answer that could not be read' do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError, /could not be read/)
      end
    end

    # The SDK's error has a nil message when PayPal's body carries none.
    context 'when PayPal refuses the order with issue descriptions only' do
      before { allow(orders_api).to receive(:create_order).and_raise(paypal_error_without_message(422, 'The order was refused')) }

      it "raises a gateway error with PayPal's description" do
        expect { gateway.create_payment_session(order: cart) }.to raise_error(Spree::Core::GatewayError, 'PayPal API error: The order was refused')
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
    let(:storefront_keys) { { 'client_token' => 'test-client-token', 'enable_apple_pay' => true, 'enable_card_fields' => true } }
    let(:stored_data) { fixture('paypal_order').merge(storefront_keys) }
    let(:payment_session) do
      create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, amount: cart.total, external_data: stored_data)
    end

    def update(**attributes)
      gateway.update_payment_session(payment_session: payment_session, **attributes)
    end

    # The PayPal order keeps its amount, and the payment would record the new one.
    context 'when the amount differs from the session amount' do
      it 'raises a gateway error telling the caller to create a new session' do
        expect { update(amount: cart.total + 10) }.to raise_error(Spree::Core::GatewayError, /create a new payment session/)
      end

      it 'leaves the session amount as it was' do
        expect { update(amount: cart.total + 10) }.to raise_error(Spree::Core::GatewayError)

        expect(payment_session.reload.amount).to eq(cart.total)
      end

      it 'refuses a lower amount too' do
        expect { update(amount: cart.total - 1) }.to raise_error(Spree::Core::GatewayError)
      end

      it 'does not call PayPal' do
        expect { update(amount: cart.total + 10) }.to raise_error(Spree::Core::GatewayError)

        expect(gateway).not_to have_received(:client)
      end
    end

    it 'accepts the amount the session already has, as the API sends it' do
      expect { update(amount: format('%.2f', cart.total)) }.not_to raise_error
    end

    it 'accepts no amount' do
      expect { update(amount: nil) }.not_to raise_error
    end

    # The gem writes every key the storefront reads, and PayPal's order is
    # what settlement reads, so nothing a client sends is stored.
    context 'when the client sends external_data' do
      let(:client_data) do
        {
          'id' => 'OTHER-ORDER',
          'status' => 'COMPLETED',
          'purchase_units' => [{ 'payments' => { 'captures' => [{ 'id' => 'FAKE', 'status' => 'COMPLETED' }] } }],
          'payment_source' => { 'paypal' => { 'account_id' => 'SOMEONE-ELSE' } },
          'client_token' => 'client-chosen',
          'enable_card_fields' => false
        }
      end

      it 'stores none of it' do
        update(external_data: client_data)

        expect(payment_session.reload.external_data).to eq(stored_data)
      end

      it 'leaves the session with no capture' do
        update(external_data: client_data)

        expect(payment_session.reload.paypal_capture).to be_nil
      end
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

        expect(payments_on_cart.pluck(:response_code)).to eq([payment_session.external_id])
      end

      it 'completes the payment' do
        complete

        expect(payments_on_cart.sole).to be_completed
      end

      it 'records the PayPal capture id on the payment' do
        complete

        expect(payments_on_cart.sole.metadata['paypal_capture_id']).to eq('6F473251BB811841E')
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

        expect(payments_on_cart.sole).to have_attributes(completed?: false, pending?: true)
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

          expect(payments_on_cart).to be_empty
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

        expect(payments_on_cart).to be_empty
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

    context 'when PayPal refuses the capture' do
      before { allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(422)) }

      it 'marks the session as failed and raises GatewayError' do
        expect { complete }.to raise_error(Spree::Core::GatewayError, /PayPal API error/)

        expect(payment_session.reload.status).to eq('failed')
      end
    end

    context "when PayPal declines the buyer's funding source" do
      before { allow(orders_api).to receive(:capture_order).and_raise(paypal_issue_error(422, 'INSTRUMENT_DECLINED')) }

      it 'fails the session and raises a gateway error' do
        expect { complete }.to raise_error(Spree::Core::GatewayError)

        expect(payment_session.reload).to be_failed
      end

      it 'creates no payment' do
        expect { complete }.to raise_error(Spree::Core::GatewayError)

        expect(payments_on_cart).to be_empty
      end
    end

    # The SDK's error has a nil message when PayPal's body carries none.
    context 'when PayPal refuses the capture with issue descriptions only' do
      before { allow(orders_api).to receive(:capture_order).and_raise(paypal_error_without_message(422, 'The instrument presented was declined')) }

      it "raises a gateway error with PayPal's description" do
        expect { complete }.to raise_error(Spree::Core::GatewayError, 'PayPal API error: The instrument presented was declined')
      end
    end

    # PayPal can send these after it has captured, so the outcome is unknown:
    # the session must stay usable for a retry that reads the order again.
    [401, 408, 429, 500, 503].each do |status_code|
      context "when the capture is answered with #{status_code}" do
        before { allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(status_code)) }

        it 'raises a gateway error and leaves the session pending' do
          expect { complete }.to raise_error(Spree::Core::GatewayError)

          expect(payment_session.reload).to be_pending
        end
      end
    end

    # The storefront keeps reading these from the session while it is still open.
    context 'when the session carries the storefront keys' do
      let(:storefront_keys) { { 'client_token' => 'test-client-token', 'enable_apple_pay' => true, 'enable_card_fields' => true } }
      let(:payment_session) do
        create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, external_data: fixture('paypal_order').merge(storefront_keys))
      end

      context 'when the capture is answered with a server error' do
        before { allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(503)) }

        it 'leaves the session pending with the storefront keys' do
          expect { complete }.to raise_error(Spree::Core::GatewayError)

          expect(payment_session.reload).to be_pending.and have_attributes(external_data: a_hash_including(storefront_keys))
        end
      end

      context 'when the capture is COMPLETED' do
        it 'stores the captured order over the stored one and keeps the storefront keys' do
          complete

          expect(payment_session.reload.external_data).to eq(captured.merge(storefront_keys))
        end
      end

      context 'when the capture is PENDING' do
        let(:captured) { captured_order('PENDING') }

        it 'stores the captured order and keeps the storefront keys' do
          complete

          expect(payment_session.reload).to have_attributes(paypal_capture_status: 'PENDING', external_data: a_hash_including(storefront_keys))
        end
      end
    end

    [429, 503].each do |status_code|
      context "when a #{status_code} hid a capture that went through" do
        before { allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(status_code)) }

        # The first confirm gets the error; PayPal had captured, and the buyer confirms again.
        def confirm_twice
          expect { complete }.to raise_error(Spree::Core::GatewayError)
          allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))

          gateway.complete_payment_session(payment_session: payment_session.reload)
        end

        it 'settles one completed payment on the retry' do
          confirm_twice

          expect(payments_on_cart.map { |payment| [payment.response_code, payment.completed?] }).to eq([[payment_session.external_id, true]])
        end

        it 'completes the session on the retry' do
          confirm_twice

          expect(payment_session.reload).to be_completed
        end

        it 'does not capture again on the retry' do
          confirm_twice

          expect(orders_api).to have_received(:capture_order).once
        end
      end
    end

    [Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError, Net::HTTP::Persistent::Error].each do |transport_error|
      context "when the capture gets no answer (#{transport_error})" do
        before { allow(orders_api).to receive(:capture_order).and_raise(transport_error) }

        it 'raises a gateway error and leaves the session pending' do
          expect { complete }.to raise_error(Spree::Core::GatewayError, /connection error/)

          expect(payment_session.reload).to be_pending
        end
      end
    end

    # A 502 or 503 with an HTML body: the SDK cannot build its error, so it
    # raises TypeError instead of an APIException. PayPal may have captured.
    context 'when PayPal answers the capture with a server error that is not JSON' do
      before { allow(orders_api).to receive(:capture_order).and_raise(unreadable_paypal_answer) }

      it 'raises a gateway error and leaves the session pending' do
        expect { complete }.to raise_error(Spree::Core::GatewayError, /could not be read/)

        expect(payment_session.reload).to be_pending
      end

      it 'settles the capture on a retry once PayPal answers' do
        expect { complete }.to raise_error(Spree::Core::GatewayError)
        allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))

        gateway.complete_payment_session(payment_session: payment_session.reload)

        expect([payment_session.reload.status, payments_on_cart.sole.completed?]).to eq(['completed', true])
      end
    end

    # Through core's workflow, as the storefront's confirm call runs it.
    context 'when the confirm workflow meets a server error that is not JSON' do
      before { allow(orders_api).to receive(:capture_order).and_raise(unreadable_paypal_answer) }

      it 'fails the workflow rather than raising' do
        expect(Spree::PaymentSessions::Complete.call(payment_session: payment_session)).to be_failure
      end
    end

    # A double-submitted confirm: the other request captured first.
    context 'when PayPal reports the order already captured' do
      before do
        allow(orders_api).to receive(:get_order).and_return(paypal_response(approved_order), paypal_response(captured))
        allow(orders_api).to receive(:capture_order).and_raise(paypal_issue_error(422, 'ORDER_ALREADY_CAPTURED'))
      end

      it 'reads the order again' do
        complete

        expect(orders_api).to have_received(:get_order).twice
      end

      it 'completes the session' do
        complete

        expect(payment_session.reload).to be_completed
      end

      it 'settles one completed payment' do
        complete

        expect(payments_on_cart.sole).to be_completed
      end

      context 'when the other request has already settled the payment' do
        before do
          winner = Spree::PaymentSession.find(payment_session.id)
          winner.update!(external_data: captured)
          winner.process
          winner.settle_payment!(captured: true)
        end

        it 'keeps one payment and completes the session' do
          complete

          expect([payments_on_cart.count, payment_session.reload.status]).to eq([1, 'completed'])
        end
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
    %w[COMPLETED PENDING PARTIALLY_REFUNDED].each do |capture_status|
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
    [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |transport_error|
      context "when PayPal cannot be reached (#{transport_error})" do
        before { allow(orders_api).to receive(:get_order).and_raise(transport_error) }

        it 'raises the error as itself and leaves the session unchanged' do
          expect { cancel }.to raise_error(transport_error)

          expect(payment_session.reload).to be_pending
        end
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
    let(:event_type) { 'PAYMENT.CAPTURE.COMPLETED' }
    let(:paypal_order_id) { 'ORDER-123' }
    let(:capture_id) { 'CAPTURE-456' }
    # A capture event names the capture in `id` and the PayPal order in `related_ids`.
    let(:raw_body) do
      { id: 'WH-EVENT-1', event_type: event_type,
        resource: { 'id' => capture_id, 'supplementary_data' => { 'related_ids' => { 'order_id' => paypal_order_id } } } }.to_json
    end
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

      # A transient failure is answered 401, so PayPal sends the event again.
      [Errno::ECONNRESET, OpenSSL::SSL::SSLError, Net::ProtocolError, EOFError].each do |transport_error|
        it "raises WebhookSignatureError when the check fails with #{transport_error}" do
          stub_paypal_http({ 'access_token' => 'tok' })
          allow(Net::HTTP.new('api-m.sandbox.paypal.com', 443)).to receive(:request).and_raise(transport_error)

          expect do
            gateway.parse_webhook_event(raw_body, signed_headers)
          end.to raise_error(Spree::PaymentMethod::WebhookSignatureError, /Webhook verification failed/)
        end
      end

      it 'returns captured when PayPal verifies the signature' do
        stub_paypal_http(
          { 'access_token' => 'tok' },
          { 'verification_status' => 'SUCCESS' }
        )

        result = gateway.parse_webhook_event(raw_body, signed_headers)
        expect(result[:action]).to eq(:captured)
      end
    end

    context 'when webhook_secret is blank in a local env' do
      before { gateway.update!(preferences: gateway.preferences.merge(webhook_secret: nil)) }

      # Whatever lands in metadata is merged into a payment's own, so it names the event, not the payload.
      it 'passes on only the event id and type as metadata' do
        result = gateway.parse_webhook_event(raw_body, {})
        expect(result[:metadata]).to eq(paypal_event_id: 'WH-EVENT-1', paypal_event_type: 'PAYMENT.CAPTURE.COMPLETED')
      end

      # The approved order has not been captured, so there is nothing to settle:
      # settling it would complete the session with no payment.
      context 'when the event is CHECKOUT.ORDER.APPROVED' do
        let(:raw_body) { { event_type: 'CHECKOUT.ORDER.APPROVED', resource: { 'id' => 'ORDER-123' } }.to_json }

        it 'returns nil' do
          expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
        end
      end

      {
        'PAYMENT.CAPTURE.COMPLETED' => :captured,
        # A pending capture settles as a payment that is not completed yet.
        'PAYMENT.CAPTURE.PENDING' => :authorized,
        'PAYMENT.CAPTURE.DENIED' => :failed,
        'PAYMENT.CAPTURE.DECLINED' => :failed,
        'PAYMENT.CAPTURE.REVERSED' => :canceled,
        'PAYMENT.CAPTURE.REFUNDED' => :canceled
      }.each do |type, action|
        context "when the event is #{type}" do
          let(:event_type) { type }

          it "returns the #{action} action with the payment session" do
            expect(gateway.parse_webhook_event(raw_body, {})).to include(action: action, payment_session: payment_session)
          end
        end
      end

      context 'when the event is one the gem does not act on' do
        let(:event_type) { 'PAYMENT.CAPTURE.SOMETHING_NEW' }

        it 'returns nil' do
          expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
        end
      end

      context 'when the PayPal order is unknown' do
        let(:paypal_order_id) { 'UNKNOWN' }

        it 'returns nil' do
          expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
        end
      end

      context 'when the session belongs to another payment method' do
        let(:other_gateway) { create(:paypal_merchant_gateway, store: store) }
        let(:payment_session) { create(:paypal_merchant_payment_session, cart: cart, payment_method: other_gateway, external_id: 'ORDER-123') }

        it 'returns nil' do
          expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
        end
      end

      context 'when the event has no PayPal order id' do
        let(:raw_body) { { event_type: 'PAYMENT.CAPTURE.COMPLETED', resource: { 'id' => 'CAPTURE-456' } }.to_json }

        it 'returns nil' do
          expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
        end
      end

      # Payments taken on 5.x are keyed on the capture id, which Spree 6 cannot
      # link back to the session: a late or redelivered event would settle twice.
      context 'when the session was completed with a payment keyed on the capture id' do
        let(:payment_session) do
          create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, external_id: 'ORDER-123', status: 'completed')
        end

        before do
          cart.payments.create!(payment_method: gateway, response_code: payment_response_code, amount: payment_session.amount,
                                skip_source_requirement: true)
        end

        context 'when the payment holds the event capture id' do
          let(:payment_response_code) { 'CAPTURE-456' }

          it 'returns nil' do
            expect(gateway.parse_webhook_event(raw_body, {})).to be_nil
          end

          it 'returns nil for every capture event' do
            bodies = %w[PAYMENT.CAPTURE.PENDING PAYMENT.CAPTURE.DENIED PAYMENT.CAPTURE.REFUNDED].map do |type|
              { event_type: type, resource: { 'id' => 'CAPTURE-456', 'supplementary_data' => { 'related_ids' => { 'order_id' => 'ORDER-123' } } } }.to_json
            end

            expect(bodies.map { |body| gateway.parse_webhook_event(body, {}) }).to all(be_nil)
          end
        end

        context 'when the payment is keyed on the PayPal order id, as Spree 6 does' do
          let(:payment_response_code) { 'ORDER-123' }

          it 'still returns the action: core ignores a payment it already settled' do
            expect(gateway.parse_webhook_event(raw_body, {})).to include(action: :captured)
          end
        end

        context 'when the payment holds another capture id' do
          let(:payment_response_code) { 'CAPTURE-OTHER' }

          it 'still returns the action' do
            expect(gateway.parse_webhook_event(raw_body, {})).to include(action: :captured)
          end
        end
      end

      context 'when the session is still pending and a payment holds the capture id' do
        before do
          cart.payments.create!(payment_method: gateway, response_code: 'CAPTURE-456', amount: payment_session.amount,
                                skip_source_requirement: true)
        end

        it 'still returns the action' do
          expect(gateway.parse_webhook_event(raw_body, {})).to include(action: :captured)
        end
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
