# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::SyncRefundsJob do
  include ActiveJob::TestHelper
  include PaypalHttp

  def refunds
    Spree::Refund.where(payment_id: payment.id)
  end

  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:order) { create(:completed_order_with_totals, store: store) }
  let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
  let(:payment) do
    create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: 'completed',
                     response_code: '5O190127TN364715T', metadata: { 'paypal_capture_id' => '3C679366HH908993F' })
  end
  let!(:refund_reason) { create(:refund_reason, store: store, name: Spree::RefundReason::RETURN_PROCESSING_REASON) }

  before do
    stub_paypal_token
    stub_paypal_refund_requests
    stub_paypal_order(paypal_fixture('refunded_paypal_order'))
  end

  it "runs on the queue Spree's payment webhooks use" do
    expect(described_class.new.queue_name).to eq(Spree.queues.payment_webhooks.to_s)
  end

  it 'records the refunds made in PayPal' do
    described_class.perform_now(payment_id: payment.id)

    expect(refunds.pluck(:transaction_id)).to contain_exactly('1JU08902781691411', '8MC585209K746392H')
  end

  it 'sends PayPal no refund request' do
    described_class.perform_now(payment_id: payment.id)

    expect(a_request(:post, PaypalHttp::REFUND_REQUEST)).not_to have_been_made
  end

  context 'when a refund made in Spree has no PayPal refund id yet' do
    before { payment.refunds.create!(amount: 10, reason: refund_reason) }

    it 'tries again later, and records nothing' do
      expect { described_class.perform_now(payment_id: payment.id) }.to have_enqueued_job(described_class).with(payment_id: payment.id)

      expect(refunds.pluck(:transaction_id)).to eq([nil])
    end

    it 'gives up after five tries, logging what to run once it settles' do
      allow(Rails.logger).to receive(:warn)

      perform_enqueued_jobs { described_class.perform_later(payment_id: payment.id) }

      expect(Rails.logger).to have_received(:warn).with(/#{payment.number}.*spree:paypal_merchant:sync_refunds/).once
      expect(refunds.count).to eq(1)
    end
  end

  context 'when PayPal cannot be read' do
    let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }

    before do
      allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
      allow(orders_api).to receive(:get_order).and_raise(Faraday::ConnectionFailed.new('refused'))
    end

    it 'tries again later' do
      expect { described_class.perform_now(payment_id: payment.id) }.to have_enqueued_job(described_class).with(payment_id: payment.id)
    end
  end

  context 'when PayPal refuses to show the order' do
    before do
      stub_request(:get, "#{PaypalHttp::PAYPAL_API}/v2/checkout/orders/5O190127TN364715T")
        .to_return(paypal_json({ name: 'RESOURCE_NOT_FOUND', message: 'The specified resource does not exist.' }, status: 404))
    end

    it 'logs why, and does not try again' do
      allow(Rails.logger).to receive(:warn)

      expect { described_class.perform_now(payment_id: payment.id) }.not_to have_enqueued_job(described_class)
      expect(Rails.logger).to have_received(:warn).with(/#{payment.number}.*404/)
    end
  end

  context 'when the payment is gone' do
    it 'does nothing more' do
      expect { described_class.perform_now(payment_id: 0) }.not_to have_enqueued_job(described_class)
    end
  end
end
