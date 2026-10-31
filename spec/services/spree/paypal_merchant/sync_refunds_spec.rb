# frozen_string_literal: true

require 'spec_helper'

# A refund made in PayPal's dashboard never passes through Spree, so the order
# kept showing as paid. The sync reads the refunds PayPal holds for a payment
# and records each one Spree is missing. PayPal's REST API is stubbed at the
# HTTP level; Spree's models, workflows, events and order totals are real.
RSpec.describe Spree::PaypalMerchant::SyncRefunds do
  include PaypalHttp

  # A refund as PayPal lists it on its order. Other fields, such as status or
  # create_time, replace the defaults.
  def paypal_refund(id, value, currency: 'USD', capture: capture_id, **fields)
    {
      'id' => id, 'status' => 'COMPLETED', 'amount' => { 'currency_code' => currency, 'value' => value },
      'links' => [
        { 'href' => "https://api.sandbox.paypal.com/v2/payments/refunds/#{id}", 'rel' => 'self', 'method' => 'GET' },
        { 'href' => "https://api.sandbox.paypal.com/v2/payments/captures/#{capture}", 'rel' => 'up', 'method' => 'GET' }
      ],
      'create_time' => '2026-10-02T09:00:00Z', 'update_time' => '2026-10-02T09:00:00Z'
    }.merge(fields.stringify_keys)
  end

  # PayPal's order for the payment, holding the given refunds.
  def paypal_order_with(*paypal_refunds)
    paypal_fixture('refunded_paypal_order').tap do |data|
      data['purchase_units'][0]['payments']['refunds'] = paypal_refunds
    end
  end

  def money(amount)
    format('%.2f', amount)
  end

  # As the job runs it: on the payment read afresh.
  def sync
    described_class.new(payment: Spree::Payment.find(payment.id)).call
  end

  # Read from the database: the payment's association can be loaded.
  def refunds
    Spree::Refund.where(payment_id: payment.id).order(:id)
  end

  def paypal_api_error(status_code)
    PaypalServerSdk::APIException.new("PayPal returned #{status_code}", double(status_code: status_code))
  end

  let(:capture_id) { '3C679366HH908993F' }
  let(:paypal_order_id) { '5O190127TN364715T' }
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:order) { create(:completed_order_with_totals, store: store) }
  let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
  let(:payment_status) { 'completed' }
  # Settled as a Spree 6 session leaves it: the PayPal order id as response code
  # and the capture id on the metadata.
  let(:payment) do
    create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: payment_status,
                     response_code: paypal_order_id, metadata: { 'paypal_capture_id' => capture_id })
  end
  let(:total) { order.total.to_d }
  let!(:refund_reason) { create(:refund_reason, store: store, name: Spree::RefundReason::RETURN_PROCESSING_REASON) }

  before do
    stub_paypal_token
    stub_paypal_refund_requests
    payment
  end

  context 'when the payment was refunded in full in PayPal' do
    before { stub_paypal_order(paypal_order_with(paypal_refund('1JU08902781691411', money(total)))) }

    it 'records one refund, for the PayPal amount, with the PayPal refund id' do
      sync

      expect(refunds.sole).to have_attributes(amount: total, transaction_id: '1JU08902781691411', order: order, reason: refund_reason)
    end

    it 'sends PayPal no refund request' do
      sync

      expect(a_request(:post, PaypalHttp::REFUND_REQUEST)).not_to have_been_made
    end

    it 'marks the order refunded' do
      sync

      expect(order.reload.payment_state).to eq('refunded')
    end

    # Spree's own refund path: the workflow the dashboard and API call.
    it 'leaves the order as a refund made in Spree leaves it' do
      twin_order = create(:completed_order_with_totals, store: store)
      twin_payment = create(:payment, order: twin_order, payment_method: gateway, source: payment_source, amount: twin_order.total,
                                      status: 'completed', response_code: 'ORDER-TWIN', metadata: { 'paypal_capture_id' => 'CAPTURE-TWIN' })
      Spree.refund_create_workflow.call(payment: twin_payment, reason: refund_reason)

      sync

      settled = ->(o) { o.reload.slice(:payment_state, :payment_total, :total) }
      expect(settled.call(order)).to eq(settled.call(twin_order))
    end

    it 'leaves nothing more to refund on the payment' do
      sync

      expect(payment.reload.credit_allowed).to be_zero
    end

    it 'announces the refund as Spree does' do
      allow(Spree::Events).to receive(:publish).and_call_original

      sync

      expect(Spree::Events).to have_received(:publish).with('refund.created', anything, anything).once
      expect(Spree::Events).to have_received(:publish).with('payment.refunded', anything, anything).once
    end

    it 'notes on the refund that it was recorded from PayPal' do
      sync

      expect(refunds.sole.metadata).to include(
        'recorded_from' => 'paypal', 'paypal_refund_id' => '1JU08902781691411', 'paypal_capture_id' => capture_id,
        'paypal_create_time' => '2026-10-02T09:00:00Z'
      )
    end

    it 'records no refunder and no originator, as for a manual refund' do
      sync

      expect(refunds.sole).to have_attributes(refunder: nil, originator: nil)
    end

    it 'reports the refund it recorded' do
      result = sync

      expect([result.recorded, result.skipped]).to eq([[refunds.sole], []])
    end
  end

  context 'when PayPal holds two partial refunds' do
    before { stub_paypal_order(paypal_fixture('refunded_paypal_order')) }

    it 'records both, oldest first' do
      sync

      expect(refunds.pluck(:transaction_id, :amount)).to eq([['1JU08902781691411', 10], ['8MC585209K746392H', 15]])
    end

    it 'marks the order partly refunded' do
      sync

      expect(order.reload.payment_state).to eq('partially_refunded')
    end

    it 'records nothing new when it runs again' do
      sync

      expect { sync }.not_to change(refunds, :count)
    end

    it 'reports both as already recorded when it runs again' do
      sync

      expect(sync.skipped).to contain_exactly(/1JU08902781691411.*already recorded/, /8MC585209K746392H.*already recorded/)
    end

    it 'leaves the rest of the payment refundable' do
      sync

      expect(payment.reload.credit_allowed).to eq(total - 25)
    end
  end

  context 'when the refunds arrive out of order' do
    before do
      stub_paypal_order(paypal_order_with(paypal_refund('LATER', '15.00', create_time: '2026-10-03T09:00:00Z'),
                                          paypal_refund('EARLIER', '10.00', create_time: '2026-10-02T09:00:00Z')))
    end

    it 'records the older first' do
      sync

      expect(refunds.pluck(:transaction_id)).to eq(%w[EARLIER LATER])
    end
  end

  # Spree saves the PayPal refund id as the refund's transaction id once
  # PayPal answers the credit, and PayPal sends its refund event for it too.
  context 'when one of the refunds was made in Spree' do
    before do
      stub_request(:post, "#{PaypalHttp::PAYPAL_API}/v2/payments/captures/#{capture_id}/refund")
        .to_return(paypal_json({ id: '1JU08902781691411', status: 'COMPLETED', amount: { currency_code: 'USD', value: '10.00' } }))
      Spree.refund_create_workflow.call(payment: payment, amount: 10, reason: refund_reason)
      stub_paypal_order(paypal_fixture('refunded_paypal_order'))
    end

    it 'records only the refund made in PayPal' do
      sync

      expect(refunds.pluck(:transaction_id, :amount)).to eq([['1JU08902781691411', 10], ['8MC585209K746392H', 15]])
    end
  end

  # Spree commits the refund row before it asks PayPal, and writes the PayPal
  # refund id when PayPal answers. Until then the PayPal refund being reported
  # may be that one.
  context 'when a refund made in Spree has no PayPal refund id yet' do
    before do
      payment.refunds.create!(amount: 10, reason: refund_reason)
      stub_paypal_order(paypal_fixture('refunded_paypal_order'))
    end

    it 'raises, so it is tried again later' do
      expect { sync }.to raise_error(described_class::RefundInProgress)
    end

    it 'records nothing' do
      expect { sync }.to raise_error(described_class::RefundInProgress)

      expect(refunds.pluck(:transaction_id)).to eq([nil])
    end
  end

  context 'when a PayPal refund is in another currency' do
    before { stub_paypal_order(paypal_order_with(paypal_refund('IN-EUROS', '10.00', currency: 'EUR'))) }

    it 'records nothing, and logs why' do
      allow(Rails.logger).to receive(:warn)

      sync

      expect(refunds).to be_empty
      expect(Rails.logger).to have_received(:warn).with(/IN-EUROS.*EUR.*payment is in USD/)
    end
  end

  context 'when a PayPal refund is for more than is left to refund' do
    before do
      payment.refunds.create!(amount: total - 5, reason: refund_reason, transaction_id: 'REFUNDED-EARLIER')
      stub_paypal_order(paypal_order_with(paypal_refund('REFUNDED-EARLIER', money(total - 5)), paypal_refund('TOO-MUCH', '10.00')))
    end

    it 'records nothing, and logs why' do
      allow(Rails.logger).to receive(:warn)

      sync

      expect(refunds.pluck(:transaction_id)).to eq(['REFUNDED-EARLIER'])
      expect(Rails.logger).to have_received(:warn).with(/TOO-MUCH.*10\.00 USD.*only 5\.00 USD is left to refund/)
    end
  end

  context 'when the store has no refund reasons' do
    let!(:refund_reason) { nil }

    before { stub_paypal_order(paypal_fixture('refunded_paypal_order')) }

    it 'records nothing, and logs why' do
      allow(Rails.logger).to receive(:warn)

      sync

      expect(refunds).to be_empty
      expect(Rails.logger).to have_received(:warn).with(/no refund reason/).at_least(:once)
    end

    it 'creates no refund reason' do
      expect { sync }.not_to change(Spree::RefundReason, :count)
    end
  end

  # The admin API's default when no reason is named.
  context "when the store has refund reasons but no 'Return processing'" do
    let!(:refund_reason) { nil }
    let!(:reasons) { %w[Goodwill Damaged].map { |name| create(:refund_reason, store: store, name: name) } }

    before { stub_paypal_order(paypal_order_with(paypal_refund('1JU08902781691411', '10.00'))) }

    it "uses the store's first refund reason by name" do
      sync

      expect(refunds.sole.reason.name).to eq('Damaged')
    end

    it 'creates no refund reason' do
      expect { sync }.not_to change(Spree::RefundReason, :count)
    end
  end

  context "when another store has a 'Return processing' reason" do
    let!(:refund_reason) { create(:refund_reason, store: create(:store), name: Spree::RefundReason::RETURN_PROCESSING_REASON) }

    before { stub_paypal_order(paypal_fixture('refunded_paypal_order')) }

    it 'does not use it' do
      sync

      expect(refunds).to be_empty
    end
  end

  # Spree records PayPal's PENDING refunds it asked for; one made in PayPal is
  # recorded once PayPal completes it.
  %w[PENDING FAILED CANCELLED].each do |status|
    context "when a PayPal refund is #{status}" do
      before { stub_paypal_order(paypal_order_with(paypal_refund('NOT-DONE', '10.00', status: status))) }

      it 'records nothing' do
        sync

        expect(refunds).to be_empty
      end

      it 'reports it as not recorded' do
        expect(sync.skipped).to contain_exactly(/NOT-DONE.*#{status}/)
      end
    end
  end

  context 'when a PayPal refund names another capture' do
    before { stub_paypal_order(paypal_order_with(paypal_refund('OTHER-CAPTURE-REFUND', '10.00', capture: 'ANOTHER-CAPTURE'))) }

    it 'records nothing' do
      sync

      expect(refunds).to be_empty
    end
  end

  context 'when a PayPal refund does not name its capture' do
    before do
      refund = paypal_refund('NO-UP-LINK', '10.00')
      refund['links'] = refund['links'].reject { |link| link['rel'] == 'up' }
      stub_paypal_order(paypal_order_with(refund))
    end

    it 'records it: the PayPal order has one capture' do
      sync

      expect(refunds.pluck(:transaction_id)).to eq(['NO-UP-LINK'])
    end
  end

  %w[pending processing failed void].each do |status|
    context "when the payment is #{status}" do
      let(:payment_status) { status }

      it 'records nothing, without asking PayPal' do
        allow(Rails.logger).to receive(:warn)

        sync

        expect(refunds).to be_empty
        expect(a_request(:get, /#{PaypalHttp::PAYPAL_API}/o)).not_to have_been_made
        expect(Rails.logger).to have_received(:warn).with(/#{status}/)
      end
    end
  end

  # Payments taken on 5.x hold the capture id as their response code and
  # nothing on their metadata. PayPal's capture names its order.
  context 'when the payment was taken on 5.x' do
    let(:payment) do
      create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: 'completed',
                       response_code: capture_id)
    end
    let(:paypal_capture) { paypal_fixture('paypal_capture') }

    before do
      stub_paypal_capture(paypal_capture)
      stub_paypal_order(paypal_fixture('refunded_paypal_order'))
    end

    it 'finds the PayPal order through the capture, and records its refunds' do
      sync

      expect(refunds.pluck(:transaction_id, :amount)).to eq([['1JU08902781691411', 10], ['8MC585209K746392H', 15]])
    end

    context 'when the capture names its order only by link' do
      let(:paypal_capture) { paypal_fixture('paypal_capture').except('supplementary_data') }

      it 'follows the link' do
        sync

        expect(refunds.count).to eq(2)
      end
    end
  end

  describe 'when PayPal cannot be read' do
    let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }

    before do
      allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
    end

    [Faraday::ConnectionFailed.new('refused'), Faraday::TimeoutError.new('timed out')].each do |error|
      context "when the request fails with #{error.class}" do
        before { allow(orders_api).to receive(:get_order).and_raise(error) }

        it 'raises PaypalUnavailable, so it is tried again later' do
          expect { sync }.to raise_error(described_class::PaypalUnavailable)
        end
      end
    end

    [500, 503, 429, 401].each do |status|
      context "when PayPal answers #{status}" do
        before { allow(orders_api).to receive(:get_order).and_raise(paypal_api_error(status)) }

        it 'raises PaypalUnavailable, so it is tried again later' do
          expect { sync }.to raise_error(described_class::PaypalUnavailable)
        end
      end
    end

    context 'when PayPal has no such order for these credentials' do
      before { allow(orders_api).to receive(:get_order).and_raise(paypal_api_error(404)) }

      it 'raises a gateway error, which trying again will not change' do
        expect { sync }.to raise_error(Spree::Core::GatewayError, /PayPal refused/)
      end
    end

    it 'records nothing' do
      allow(orders_api).to receive(:get_order).and_raise(Faraday::ConnectionFailed.new('refused'))

      expect { sync }.to raise_error(described_class::PaypalUnavailable)
      expect(refunds).to be_empty
    end
  end
end
