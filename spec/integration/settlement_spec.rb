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

  # The captured order fixture for the cart's total, with its capture at the
  # given status. The payment records the amount PayPal captured.
  def captured_order(capture_status)
    fixture('captured_paypal_order').tap do |data|
      total = format('%.2f', cart.total)
      data['purchase_units'][0]['amount']['value'] = total
      data['purchase_units'][0]['payments']['captures'][0].merge!('status' => capture_status, 'amount' => { 'currency_code' => 'USD', 'value' => total })
    end
  end

  # A PayPal event body. An order event is about the order; a capture event is
  # about the capture, and names its order.
  def webhook_body(event_type)
    resource = if event_type.start_with?('CHECKOUT.ORDER')
                 { 'id' => payment_session.external_id }
               else
                 { 'id' => capture_id, 'supplementary_data' => { 'related_ids' => { 'order_id' => payment_session.external_id } } }
               end

    { id: 'WH-EVENT-1', event_type: event_type, resource: resource }.to_json
  end

  # What the webhook controller's job does once a delivery has been parsed.
  def deliver_webhook(event_type)
    result = gateway.parse_webhook_event(webhook_body(event_type), {})
    return if result.nil?

    Spree::Payments::HandleWebhookJob.perform_now(
      payment_method_id: gateway.id, action: result[:action].to_s, payment_session_id: result[:payment_session].id
    )
  end

  # Runs the webhook workflow on a session loaded afresh, as the job loads it:
  # the memoized `payment_session` can be stale (it may predate a confirm that
  # captured and stored the order), which would make the workflow fail before it
  # reached the settlement it is meant to exercise.
  def handle_webhook(action, metadata: {})
    Spree.payments_handle_webhook_workflow.call(
      payment_method: gateway, action: action, payment_session: Spree::PaymentSession.find(payment_session.id), metadata: metadata
    )
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

    # The stored capture is COMPLETED, so the webhook needs no PayPal read, and
    # core finds the payment completed and leaves it alone.
    context 'when the webhook then arrives' do
      let!(:payment_updated_at) { payments.sole.updated_at }
      let!(:webhook_result) { deliver_webhook('PAYMENT.CAPTURE.COMPLETED') }

      it 'runs the webhook workflow for a captured event' do
        expect(Spree.payments_handle_webhook_workflow).to have_received(:call).with(hash_including(action: :captured))
      end

      it 'succeeds' do
        expect(webhook_result).to be_success
      end

      it 'does not read the PayPal order again' do
        expect(orders_api).to have_received(:get_order).once
      end

      it 'still has exactly one payment' do
        expect(payments.count).to eq(1)
      end

      it 'leaves the payment as the confirm settled it' do
        expect(payments.sole.updated_at).to eq(payment_updated_at)
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

  # Spree keeps a source's profile id unique per source type, not per payment
  # method. A buyer whose PayPal account already has a source under another
  # PayPal method (a second store, a recreated method) must still be settled:
  # PayPal has the money.
  context "when another PayPal method already holds a source for the buyer's PayPal account" do
    let(:account_id) { captured['payment_source']['paypal']['account_id'] }
    let(:other_gateway) { create(:paypal_merchant_gateway, store: cart.store) }

    before do
      create(:paypal_merchant_payment_source, payment_method: other_gateway, gateway_payment_profile_id: account_id)
      allow(orders_api).to receive(:get_order).and_return(paypal_response(created))
    end

    let!(:confirm_result) { confirm }

    it 'confirms' do
      expect(confirm_result).to be_success
    end

    it 'completes the session' do
      expect(payment_session.reload).to be_completed
    end

    it 'settles a completed payment with no source' do
      expect(payments.sole).to have_attributes(completed?: true, source: nil)
    end

    context 'when the storefront then places the cart' do
      before { Spree.carts_complete_workflow.call(cart: cart.reload) }

      it_behaves_like 'a placed cart paid once'
    end
  end

  # The job drops the parsed metadata today; a caller that passes it on must not
  # merge the whole PayPal event into the payment.
  context 'when a direct caller passes on the parsed event metadata' do
    before do
      parsed = gateway.parse_webhook_event(webhook_body('PAYMENT.CAPTURE.COMPLETED'), {})
      handle_webhook(parsed[:action], metadata: parsed[:metadata])
    end

    it 'records the event id and type on the payment' do
      expect(payments.sole.metadata).to include('paypal_event_id' => 'WH-EVENT-1', 'paypal_event_type' => 'PAYMENT.CAPTURE.COMPLETED')
    end

    it 'keeps the capture id' do
      expect(payments.sole.metadata).to include('paypal_capture_id' => capture_id)
    end

    it 'does not record the PayPal event itself' do
      expect(payments.sole.metadata).not_to have_key('paypal_event')
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
    let!(:failed_confirm) do
      allow(orders_api).to receive_messages(get_order: paypal_response(created))
      allow(orders_api).to receive(:capture_order).and_raise(paypal_api_error(503))
      confirm
    end
    let!(:status_after_failed_confirm) { payment_session.reload.status }

    before do
      allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))
      deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
    end

    it 'failed the confirm' do
      expect(failed_confirm).to be_failure
    end

    it 'attempted the capture once' do
      expect(orders_api).to have_received(:capture_order).once
    end

    it 'left the session pending after the failed confirm' do
      expect(status_after_failed_confirm).to eq('pending')
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
