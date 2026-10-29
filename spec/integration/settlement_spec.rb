# frozen_string_literal: true

require 'spec_helper'

# Both routes that settle a PayPal payment on Spree 6 - the storefront's
# confirm call and PayPal's webhook - run through Spree's own workflows, in
# either order. Only the PayPal client is stubbed.
RSpec.describe 'PayPal settlement through confirm and webhook' do
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

  # What the webhook controller's job does once a delivery has been parsed.
  def deliver_webhook(event_type)
    # An order event is about the order; a capture event is about the capture, and names its order.
    resource = if event_type.start_with?('CHECKOUT.ORDER')
                 { 'id' => payment_session.external_id }
               else
                 { 'id' => capture_id, 'supplementary_data' => { 'related_ids' => { 'order_id' => payment_session.external_id } } }
               end

    body = { event_type: event_type, resource: resource }.to_json
    result = gateway.parse_webhook_event(body, {})
    return if result.nil?

    Spree::Payments::HandleWebhookJob.perform_now(
      payment_method_id: gateway.id, action: result[:action].to_s, payment_session_id: result[:payment_session].id
    )
  end

  def handle_webhook(action)
    Spree.payments_handle_webhook_workflow.call(payment_method: gateway, action: action, payment_session: payment_session)
  end

  # The storefront's confirm call.
  def confirm
    Spree::PaymentSessions::Complete.call(payment_session: Spree::PaymentSession.find(payment_session.id))
  end

  # Read from the database: the cart factory leaves `cart.payments` loaded.
  def payments
    Spree::Payment.where(response_code: payment_session.external_id)
  end

  def paypal_api_error(status_code)
    PaypalServerSdk::APIException.new("PayPal returned #{status_code}", double(status_code: status_code))
  end

  let(:cart) { create(:cart_ready_for_delivery) }
  let(:gateway) { create(:paypal_merchant_gateway, store: cart.store) }
  let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }
  let(:captured) { captured_order('COMPLETED') }
  let(:capture_id) { captured['purchase_units'][0]['payments']['captures'][0]['id'] }
  # The order as PayPal holds it before anyone captures it.
  let(:storefront_keys) { { 'client_token' => 'test-client-token', 'enable_apple_pay' => true, 'enable_card_fields' => true } }
  let(:created) { fixture('paypal_order').merge('id' => captured['id']).merge(storefront_keys) }
  let(:payment_session) do
    create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, amount: cart.total,
                                             external_id: captured['id'], external_data: created)
  end

  before do
    # Any copy of the gateway, such as the one a job loads, talks to this client.
    allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
    allow(orders_api).to receive_messages(get_order: paypal_response(captured), capture_order: paypal_response(captured))
    allow(Spree.payments_handle_webhook_workflow).to receive(:call).and_call_original
  end

  shared_examples 'a placed cart paid once' do
    it 'creates exactly one payment, keyed on the PayPal order id' do
      expect(payments.pluck(:response_code)).to eq([payment_session.external_id])
    end

    it 'places the cart as an order' do
      expect(cart.reload).to have_attributes(completed_at: be_present, order: be_present)
    end

    it 'puts the one payment on the order' do
      expect(cart.reload.order.payments.pluck(:id)).to eq(payments.pluck(:id))
    end
  end

  context 'when the webhook arrives first' do
    before { handle_webhook(:captured) }

    it_behaves_like 'a placed cart paid once'

    it 'completes the session' do
      expect(payment_session.reload).to be_completed
    end

    it 'completes the payment' do
      expect(payments.sole).to be_completed
    end

    it 'records the PayPal capture id on the payment' do
      expect(payments.sole.metadata['paypal_capture_id']).to eq(capture_id)
    end

    it 'reads the PayPal order once, to find the capture' do
      expect(orders_api).to have_received(:get_order).once
    end

    it 'never captures' do
      expect(orders_api).not_to have_received(:capture_order)
    end

    it 'keeps the storefront keys on the session' do
      expect(payment_session.reload.external_data).to include(storefront_keys)
    end

    context 'when the storefront then confirms' do
      it 'creates no second payment' do
        confirm

        expect(payments.count).to eq(1)
      end

      it 'does not capture again' do
        confirm

        expect(orders_api).not_to have_received(:capture_order)
      end

      it 'succeeds' do
        expect(confirm).to be_success
      end
    end
  end

  context 'when the storefront confirms first' do
    before do
      allow(orders_api).to receive(:get_order).and_return(paypal_response(created))
      confirm
    end

    it 'captures once' do
      expect(orders_api).to have_received(:capture_order).once
    end

    it 'completes the session' do
      expect(payment_session.reload).to be_completed
    end

    it 'completes the payment' do
      expect(payments.sole).to be_completed
    end

    it 'leaves placing the cart to Carts::Complete' do
      expect(cart.reload.order).to be_nil
    end

    context 'when the webhook then arrives' do
      before { handle_webhook(:captured) }

      it 'still has exactly one payment' do
        expect(payments.count).to eq(1)
      end

      it 'leaves the cart for the storefront to place' do
        expect(cart.reload.order).to be_nil
      end
    end

    context 'when the storefront then places the cart' do
      before { Spree.carts_complete_workflow.call(cart: cart.reload) }

      it_behaves_like 'a placed cart paid once'

      it 'records the PayPal capture id on the payment' do
        expect(payments.sole.metadata['paypal_capture_id']).to eq(capture_id)
      end
    end
  end

  context 'when PayPal delivers the same webhook twice' do
    before do
      deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
      deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
    end

    it_behaves_like 'a placed cart paid once'
  end

  # PayPal can answer a capture with a 5xx after it took the funds. The confirm
  # call then leaves the session pending, and the capture webhook is what
  # settles it.
  context 'when a capture hid behind a PayPal server error on confirm' do
    before do
      allow(orders_api).to receive_messages(get_order: paypal_response(created))
      allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(503))
      expect(confirm).to be_failure

      allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))
      deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
    end

    it_behaves_like 'a placed cart paid once'

    it 'completes the session' do
      expect(payment_session.reload).to be_completed
    end

    it 'completes the payment' do
      expect(payments.sole).to be_completed
    end

    it 'records the PayPal capture id on the payment' do
      expect(payments.sole.metadata['paypal_capture_id']).to eq(capture_id)
    end

    it 'kept the storefront keys through the failed confirm and the webhook' do
      expect(payment_session.reload.external_data).to include(storefront_keys)
    end
  end

  context 'when PayPal reports the capture as pending, then as completed' do
    before do
      allow(orders_api).to receive(:get_order).and_return(paypal_response(captured_order('PENDING')))
      deliver_webhook('PAYMENT.CAPTURE.PENDING')
    end

    it 'settles a payment that is not completed yet' do
      expect(payments.sole).to be_pending
    end

    it 'completes the session' do
      expect(payment_session.reload).to be_completed
    end

    it 'places the cart' do
      expect(cart.reload.order).to be_present
    end

    it 'records the PayPal capture id on the pending payment' do
      expect(payments.sole.metadata['paypal_capture_id']).to eq(capture_id)
    end

    context 'when the completed event arrives' do
      before do
        allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))
        deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
      end

      it_behaves_like 'a placed cart paid once'

      it 'completes the same payment' do
        expect(payments.sole).to be_completed
      end
    end
  end

  context 'when the approved event arrives' do
    before { deliver_webhook('CHECKOUT.ORDER.APPROVED') }

    it 'does not run the webhook workflow' do
      expect(Spree.payments_handle_webhook_workflow).not_to have_received(:call)
    end

    it 'leaves the session pending, with no payment' do
      expect([payment_session.reload.status, payments.count]).to eq(['pending', 0])
    end

    it 'does not place the cart' do
      expect(cart.reload.order).to be_nil
    end
  end

  # Core settles a captured webhook as paid whatever the order shows, so the
  # gem must refuse before it gets that far.
  shared_examples 'a captured event that settles nothing' do
    let!(:result) { handle_webhook(:captured) }

    it 'fails the workflow' do
      expect(result).to be_failure
    end

    it 'creates no payment' do
      expect(payments).to be_empty
    end

    it 'leaves the session pending' do
      expect(payment_session.reload).to be_pending
    end

    it 'does not place the cart' do
      expect(cart.reload.order).to be_nil
    end
  end

  context 'when a captured event arrives but the PayPal order holds no capture' do
    let(:captured) { fixture('captured_paypal_order').tap { |data| data['purchase_units'][0].delete('payments') } }

    it_behaves_like 'a captured event that settles nothing'
  end

  context 'when a captured event arrives and the PayPal order shows the capture declined' do
    let(:captured) { captured_order('DECLINED') }

    it_behaves_like 'a captured event that settles nothing'
  end

  context 'when a captured event arrives for a session already holding a declined capture' do
    let(:created) { captured_order('DECLINED') }

    it_behaves_like 'a captured event that settles nothing'

    it 'does not read the PayPal order again' do
      expect(orders_api).not_to have_received(:get_order)
    end
  end
end
