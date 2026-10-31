# frozen_string_literal: true

require 'spec_helper'

# A refund made in PayPal's dashboard, end to end: PayPal's event reaches
# Spree's payments webhook, Spree answers 200 without a payment-session job,
# and the gem's job records the refund it reads from PayPal. PayPal's REST API
# is stubbed at the HTTP level; the webhook signature check is skipped, as in
# any local environment without a webhook id.
RSpec.describe 'A refund made in PayPal', type: :request do
  include ActiveJob::TestHelper
  include PaypalHttp

  def deliver_refund_event
    resource = paypal_fixture('refunded_paypal_order').dig('purchase_units', 0, 'payments', 'refunds', 0)
    body = { id: 'WH-REFUND-1', event_type: 'PAYMENT.CAPTURE.REFUNDED', resource_type: 'refund', resource: resource }.to_json

    post "/api/v3/webhooks/payments/#{gateway.prefixed_id}", params: body, headers: { 'CONTENT_TYPE' => 'application/json' }
  end

  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:order) { create(:completed_order_with_totals, store: store) }
  let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
  let!(:payment) do
    create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: 'completed',
                     response_code: '5O190127TN364715T', metadata: { 'paypal_capture_id' => '3C679366HH908993F' })
  end

  before do
    create(:refund_reason, store: store, name: Spree::RefundReason::RETURN_PROCESSING_REASON)
    stub_paypal_token
    stub_paypal_refund_requests
    stub_paypal_order(paypal_fixture('refunded_paypal_order'))
  end

  it 'is acknowledged, and queues the refund sync instead of a payment-session job' do
    deliver_refund_event

    expect(response).to have_http_status(:ok)
    expect(Spree::PaypalMerchant::SyncRefundsJob).to have_been_enqueued.with(payment_id: payment.id)
    expect(Spree::Payments::HandleWebhookJob).not_to have_been_enqueued
  end

  it "records PayPal's refunds on the payment, and the order shows them" do
    perform_enqueued_jobs { deliver_refund_event }

    expect(Spree::Refund.where(payment_id: payment.id).pluck(:transaction_id)).to contain_exactly('1JU08902781691411', '8MC585209K746392H')
    expect(order.reload.payment_state).to eq('partially_refunded')
  end

  it 'sends PayPal no refund request' do
    perform_enqueued_jobs { deliver_refund_event }

    expect(a_request(:post, PaypalHttp::REFUND_REQUEST)).not_to have_been_made
  end

  it 'records nothing more when PayPal sends the event again' do
    perform_enqueued_jobs { deliver_refund_event }

    expect { perform_enqueued_jobs { deliver_refund_event } }.not_to change(Spree::Refund, :count)
  end
end
