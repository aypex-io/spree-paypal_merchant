# frozen_string_literal: true

require 'spec_helper'

# Refunds, cancels and voids run through Spree's own workflows and models; only
# the PayPal client is stubbed. A copy of the gateway is loaded for each call,
# so the stub is on the SDK client rather than on one gateway.
RSpec.describe 'PayPal refunds and cancellation through Spree workflows' do
  def paypal_refund(id: 'REFUND-1', status: 'COMPLETED')
    refund = instance_double(PaypalServerSdk::Refund, id: id, status: status, as_json: { 'id' => id, 'status' => status })
    instance_double(PaypalServerSdk::ApiResponse, data: refund)
  end

  def paypal_error(status, message)
    PaypalServerSdk::ErrorException.new(message, double(status_code: status, raw_body: { name: 'ERROR', message: message }.to_json))
  end

  def refund_of(capture_id, value)
    { 'capture_id' => capture_id, 'amount' => { 'value' => value, 'currency_code' => 'USD' } }
  end

  # Read from the database: the payment's association can be loaded.
  def refunds
    Spree::Refund.where(payment_id: payment.id)
  end

  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController, refund_captured_payment: paypal_refund) }
  let(:canceler) { create(:admin_user) }
  let(:order) { create(:completed_order_with_totals, store: store) }
  let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
  let(:status) { 'completed' }
  # Settled as a Spree 6 session leaves it: the PayPal order id as response code
  # and the capture id on the metadata.
  let(:payment) do
    create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: status,
                     response_code: 'ORDER-1', metadata: { 'paypal_capture_id' => 'CAP-1' })
  end
  let(:total) { order.total.to_d }

  before do
    allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, payments: payments_api))
    order.update!(canceler: canceler)
    payment
  end

  describe 'a refund from the workflow' do
    let(:result) { Spree.refund_create_workflow.call(payment: payment, amount: 12.5, refunder: canceler) }

    it 'refunds the capture the payment recorded, for the amount asked' do
      result

      expect(payments_api).to have_received(:refund_captured_payment).once.with(refund_of('CAP-1', '12.50'))
    end

    it 'records the refund with the PayPal refund id' do
      expect(result.value).to have_attributes(transaction_id: 'REFUND-1', amount: 12.5)
    end

    it 'keeps one refund' do
      result

      expect(refunds.count).to eq(1)
    end

    it 'leaves the payment response code, which links the payment to its PayPal order' do
      result

      expect(payment.reload.response_code).to eq('ORDER-1')
    end

    context 'when the payment was taken on 5.x and holds the capture id as its response code' do
      let(:payment) do
        create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: status,
                         response_code: 'CAPTURE-FROM-5X')
      end

      it 'refunds that capture' do
        result

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAPTURE-FROM-5X', '12.50'))
      end
    end

    context 'when PayPal refuses the refund' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(422, 'The capture is fully refunded')) }

      it 'fails with PayPal\'s message' do
        expect(result).to be_failure
        expect(result.error.to_s).to include('The capture is fully refunded')
      end

      it 'does not record a refund' do
        result

        expect(refunds.count).to eq(0)
      end

      it 'does not claim PayPal did not answer' do
        expect(result.error.to_s).not_to match(/did not confirm/)
      end
    end

    context 'when PayPal does not confirm the refund' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(503, 'Service unavailable')) }

      it 'fails, saying PayPal did not confirm it and to check PayPal before retrying' do
        expect(result).to be_failure
        expect(result.error.to_s).to match(/PayPal did not confirm the refund.*Check the payment in PayPal before retrying/)
      end

      it 'does not record a refund' do
        result

        expect(refunds.count).to eq(0)
      end

      it 'asks PayPal once' do
        result

        expect(payments_api).to have_received(:refund_captured_payment).once
      end
    end

    # PayPal can accept the request and still say the refund did not happen.
    context 'when PayPal answers with a refund that failed' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_return(paypal_refund(status: 'FAILED')) }

      it 'fails, saying PayPal did not issue the refund' do
        expect(result).to be_failure
        expect(result.error.to_s).to eq('PayPal did not issue the refund (status FAILED).')
      end

      it 'does not record a refund' do
        result

        expect(refunds.count).to eq(0)
      end

      it 'leaves the whole payment refundable' do
        result

        expect(payment.reload.credit_allowed).to eq(total)
      end
    end

    context 'when PayPal answers with a refund that is pending' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_return(paypal_refund(status: 'PENDING')) }

      it 'records the refund' do
        expect(result.value).to have_attributes(transaction_id: 'REFUND-1', amount: 12.5)
      end
    end

    context 'when the request times out' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(Faraday::TimeoutError) }

      it 'fails, saying PayPal did not confirm it' do
        expect(result).to be_failure
        expect(result.error.to_s).to match(/PayPal did not confirm the refund/)
      end
    end
  end

  describe 'canceling a completed payment' do
    it 'refunds the whole payment through the refund workflow' do
      payment.cancel!

      expect(payments_api).to have_received(:refund_captured_payment).once.with(refund_of('CAP-1', format('%.2f', total)))
    end

    it 'records the refund as an order cancellation by whoever canceled' do
      payment.cancel!

      expect(refunds.sole).to have_attributes(
        reason: Spree::RefundReason.order_canceled_reason(store), refunder: canceler, transaction_id: 'REFUND-1', amount: total
      )
    end

    it 'voids the payment' do
      payment.cancel!

      expect(payment.reload).to be_void
    end

    # handle_response writes a response's authorization over the response code.
    it 'keeps the PayPal order id as the payment response code' do
      payment.cancel!

      expect(payment.reload.response_code).to eq('ORDER-1')
    end

    context 'when asked to keep the money' do
      before { payment.cancel!(refund: false) }

      it 'does not call PayPal' do
        expect(payments_api).not_to have_received(:refund_captured_payment)
      end

      it 'records no refund' do
        expect(refunds.count).to eq(0)
      end

      it 'keeps the PayPal order id as the payment response code' do
        expect(payment.reload.response_code).to eq('ORDER-1')
      end
    end

    context 'when part of it was already refunded' do
      before { Spree.refund_create_workflow.call(payment: payment, amount: 10) }

      it 'refunds what is left' do
        payment.cancel!

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAP-1', format('%.2f', total - 10)))
      end
    end

    context 'when it was refunded in full' do
      before { Spree.refund_create_workflow.call(payment: payment) }

      it 'asks PayPal for no second refund' do
        payment.cancel!

        expect(payments_api).to have_received(:refund_captured_payment).once
      end
    end

    context 'when PayPal does not confirm the refund' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(500, 'Internal error')) }

      it 'raises, saying PayPal did not confirm it and to check PayPal before retrying' do
        expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError, /PayPal did not confirm the refund.*before retrying/)
      end

      it 'records no refund and leaves the payment completed' do
        expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError)

        expect(refunds.count).to eq(0)
        expect(payment.reload).to be_completed
      end
    end

    context 'when PayPal refuses the refund' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(422, 'The capture is fully refunded')) }

      it "raises with PayPal's message" do
        expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError, /The capture is fully refunded/)
      end
    end
  end

  # PayPal may still complete it. Voiding it in Spree would leave the money
  # captured against a payment that can no longer complete or be refunded.
  describe 'canceling a payment PayPal is still processing' do
    let(:status) { 'pending' }

    it 'raises, saying PayPal is still processing it and to refund it once it completes' do
      expect { payment.cancel! }
        .to raise_error(Spree::Core::GatewayError, 'PayPal is still processing this payment; refund it once PayPal completes it.')
    end

    it 'leaves the payment pending, not failed or void' do
      expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError)

      expect(payment.reload).to be_pending
    end

    it 'does not call PayPal' do
      expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError)

      expect(payments_api).not_to have_received(:refund_captured_payment)
    end

    it 'keeps the PayPal order id as the payment response code' do
      expect { payment.cancel! }.to raise_error(Spree::Core::GatewayError)

      expect(payment.reload.response_code).to eq('ORDER-1')
    end
  end

  describe 'canceling a payment that holds no money' do
    let(:status) { 'failed' }

    it 'voids it without calling PayPal' do
      payment.cancel!

      expect(payments_api).not_to have_received(:refund_captured_payment)
      expect(payment.reload).to be_void
    end

    it 'keeps the PayPal order id as the payment response code' do
      payment.cancel!

      expect(payment.reload.response_code).to eq('ORDER-1')
    end
  end

  describe 'voiding a payment' do
    let(:result) { Spree.payment_void_workflow.call(payment: payment) }

    it 'fails, telling the merchant to refund instead' do
      expect(result).to be_failure
      expect(result.error.to_s).to eq('PayPal payments are captured at checkout; refund the payment instead.')
    end

    it 'does not call PayPal' do
      result

      expect(PaypalServerSdk::Client).not_to have_received(:new)
    end

    it 'leaves the payment as it was' do
      result

      expect(payment.reload).to be_completed
    end

    # PayPal may still complete it, so it is not voided in Spree.
    context 'when PayPal is still processing the payment' do
      let(:status) { 'pending' }

      it 'fails, telling the merchant to refund it once PayPal completes it' do
        expect(result).to be_failure
        expect(result.error.to_s).to eq('PayPal is still processing this payment; refund it once PayPal completes it.')
      end

      it 'leaves the payment pending' do
        result

        expect(payment.reload).to be_pending
      end
    end
  end

  describe 'canceling the order' do
    let(:result) { Spree.order_cancel_workflow.call(order: order, canceler: canceler, refund_payments: true) }

    it 'refunds the PayPal payment in full' do
      result

      expect(payments_api).to have_received(:refund_captured_payment).once.with(refund_of('CAP-1', format('%.2f', total)))
    end

    it 'cancels the order' do
      expect(result).to be_success
      expect(order.reload).to be_canceled
    end

    it 'keeps the PayPal order id as the payment response code' do
      result

      expect(payment.reload.response_code).to eq('ORDER-1')
    end
  end
end

# A PayPal capture can be PENDING for a while. The payment is not voided in
# Spree while PayPal may still collect it: when PayPal completes it, the money
# is held against a payment that can be refunded.
RSpec.describe 'PayPal payment that PayPal is still processing' do
  def fixture(name)
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join("spec/fixtures/#{name}.json")))
  end

  def paypal_response(data)
    order = instance_double(PaypalServerSdk::Order, id: data['id'], status: data['status'], as_json: data)
    instance_double(PaypalServerSdk::ApiResponse, data: order)
  end

  def captured_order(capture_status)
    fixture('captured_paypal_order').tap do |data|
      data['purchase_units'][0]['payments']['captures'][0]['status'] = capture_status
    end
  end

  # A capture event is about the capture, and names its order.
  def deliver_webhook(event_type)
    body = {
      id: 'WH-EVENT-1', event_type: event_type,
      resource: { 'id' => capture_id, 'supplementary_data' => { 'related_ids' => { 'order_id' => payment_session.external_id } } }
    }.to_json
    result = gateway.parse_webhook_event(body, {})

    Spree::Payments::HandleWebhookJob.perform_now(
      payment_method_id: gateway.id, action: result[:action].to_s, payment_session_id: result[:payment_session].id
    )
  end

  # Read from the database: the cart and the order can hold loaded payments.
  def payment
    Spree::Payment.where(response_code: payment_session.external_id).sole
  end

  def cancel_order
    Spree.order_cancel_workflow.call(order: placed_order, refund_payments: true)
  end

  let(:cart) { create(:cart_ready_for_delivery) }
  let(:gateway) { create(:paypal_merchant_gateway, store: cart.store) }
  let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }
  let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController, refund_captured_payment: paypal_refund) }
  let(:paypal_refund) do
    refund = instance_double(PaypalServerSdk::Refund, id: 'REFUND-1', status: 'COMPLETED', as_json: { 'id' => 'REFUND-1' })
    instance_double(PaypalServerSdk::ApiResponse, data: refund)
  end
  let(:captured) { captured_order('COMPLETED') }
  let(:capture_id) { captured['purchase_units'][0]['payments']['captures'][0]['id'] }
  let(:payment_session) do
    create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, amount: cart.total, external_id: captured['id'],
                                             external_data: fixture('paypal_order').merge('id' => captured['id']))
  end
  let(:placed_order) { cart.reload.order }
  let(:still_processing) { 'PayPal is still processing this payment; refund it once PayPal completes it.' }

  before do
    allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api, payments: payments_api))
    allow(orders_api).to receive(:get_order).and_return(paypal_response(captured_order('PENDING')))
    deliver_webhook('PAYMENT.CAPTURE.PENDING')
  end

  it 'starts as a pending payment on a placed order' do
    expect(payment).to be_pending
    expect(placed_order).to be_present
  end

  describe 'canceling the order meanwhile' do
    it 'raises, saying PayPal is still processing the payment and to refund it once it completes' do
      expect { cancel_order }.to raise_error(Spree::Core::GatewayError, still_processing)
    end

    it 'leaves the payment pending, not voided' do
      expect { cancel_order }.to raise_error(Spree::Core::GatewayError)

      expect(payment).to be_pending
    end

    it 'does not call PayPal' do
      expect { cancel_order }.to raise_error(Spree::Core::GatewayError)

      expect(payments_api).not_to have_received(:refund_captured_payment)
    end
  end

  describe 'when PayPal then completes the capture' do
    let!(:order_id) { placed_order.id }
    let!(:placed_at) { placed_order.completed_at }

    before do
      expect { cancel_order }.to raise_error(Spree::Core::GatewayError)
      allow(orders_api).to receive(:get_order).and_return(paypal_response(captured))
      deliver_webhook('PAYMENT.CAPTURE.COMPLETED')
    end

    it 'completes the payment' do
      expect(payment).to be_completed
    end

    it 'does not place the order again' do
      expect(cart.reload.order).to have_attributes(id: order_id, completed_at: placed_at)
      expect(Spree::Order.where(number: placed_order.number).count).to eq(1)
    end

    it 'leaves the payment refundable' do
      expect(payment.credit_allowed).to be_positive
    end

    it 'refunds it through the refund workflow, against the capture' do
      result = Spree.refund_create_workflow.call(payment: payment, amount: 10)

      expect(result).to be_success
      expect(payments_api).to have_received(:refund_captured_payment).with(hash_including('capture_id' => capture_id))
      expect(Spree::Refund.where(payment_id: payment.id).sole).to have_attributes(transaction_id: 'REFUND-1')
    end
  end
end
