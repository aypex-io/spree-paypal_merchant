# frozen_string_literal: true

require 'spec_helper'
require 'rake'

# Records the refunds made in PayPal before its webhook was set up, one order
# at a time. PayPal's REST API is stubbed at the HTTP level.
RSpec.describe 'spree:paypal_merchant:sync_refunds' do
  include PaypalHttp

  let(:rake_file) { Spree::PaypalMerchant::Engine.root.join('lib/tasks/spree_paypal_merchant.rake').to_s }
  let(:task) { Rake.application['spree:paypal_merchant:sync_refunds'] }

  # The task's own file, in a Rake application of its own: the host app's
  # environment is already loaded.
  around do |example|
    original = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load rake_file
    example.run
  ensure
    Rake.application = original
  end

  def sync_refunds(order_number)
    task.invoke(*order_number)
  end

  def refunds
    Spree::Refund.where(payment_id: payment.id)
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

  it 'is one of the tasks the engine gives the host app' do
    expect(Spree::PaypalMerchant::Engine.paths['lib/tasks'].existent).to include(rake_file)
  end

  it "records the refunds made in PayPal for the order's PayPal payments" do
    expect { sync_refunds(order.number) }.to output.to_stdout

    expect(refunds.pluck(:transaction_id)).to contain_exactly('1JU08902781691411', '8MC585209K746392H')
  end

  it 'prints what it recorded' do
    expect { sync_refunds(order.number) }
      .to output(/Payment #{payment.number}:\n  recorded PayPal refund 1JU08902781691411 \(\$10\.00\)\n  recorded PayPal refund 8MC585209K746392H \(\$15\.00\)/)
      .to_stdout
  end

  it 'sends PayPal no refund request' do
    expect { sync_refunds(order.number) }.to output.to_stdout

    expect(a_request(:post, PaypalHttp::REFUND_REQUEST)).not_to have_been_made
  end

  it 'prints what it skipped when run again' do
    expect { sync_refunds(order.number) }.to output.to_stdout
    task.reenable

    expect { sync_refunds(order.number) }.to output(/1JU08902781691411.*already recorded.*\n.*8MC585209K746392H.*already recorded/).to_stdout
  end

  context 'when the order has payments of other methods' do
    let!(:check_payment) do
      create(:payment, order: order, payment_method: create(:check_payment_method, store: store), amount: 1, status: 'completed')
    end

    it 'leaves them out' do
      expect { sync_refunds(order.number) }.not_to output(/#{check_payment.number}/).to_stdout
    end
  end

  context 'when the order has no PayPal payment' do
    let!(:payment) { nil }

    it 'says so' do
      expect { sync_refunds(order.number) }.to output(/no PayPal payments/).to_stdout
    end
  end

  context 'when a refund made in Spree is still waiting for PayPal' do
    before { payment.refunds.create!(amount: 1, reason: Spree::RefundReason.last) }

    it 'says the payment was not synced, and why' do
      expect { sync_refunds(order.number) }.to output(/Payment #{payment.number}: not synced: .*not confirmed yet/).to_stdout
    end
  end

  it 'stops when no order has the number' do
    expect { sync_refunds('R000000000') }.to raise_error(SystemExit).and output(/No order R000000000/).to_stderr
  end

  it 'stops, saying how to use it, without an order number' do
    expect { sync_refunds(nil) }.to raise_error(SystemExit).and output(/sync_refunds\[<order number>\]/).to_stderr
  end
end
