# frozen_string_literal: true

require 'spec_helper'

# The PayPal order fixes what the buyer pays. A client that changes the session
# amount must not change what Spree records, or the cart could be placed as
# paid while PayPal took less and the store credit was never spent. Runs
# through the Store API and Spree's own workflows; only the PayPal client is
# stubbed.
RSpec.describe 'A PayPal session amount the client tries to change', type: :request do
  include_context 'API v3 Store'

  def fixture(name)
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join("spec/fixtures/#{name}.json")))
  end

  # A PayPal order as the SDK returns it.
  def paypal_response(data)
    order = instance_double(PaypalServerSdk::Order, id: data['id'], status: data['status'], as_json: data)
    instance_double(PaypalServerSdk::ApiResponse, data: order)
  end

  # The captured order fixture, for an order and a capture of the given amount.
  def captured_order(value)
    fixture('captured_paypal_order').tap do |data|
      data['id'] = paypal_order_id
      data['purchase_units'][0]['amount'] = { 'currency_code' => 'USD', 'value' => value }
      data['purchase_units'][0]['payments']['captures'][0]['amount'] = { 'currency_code' => 'USD', 'value' => value }
    end
  end

  def money(amount)
    format('%.2f', amount)
  end

  let(:paypal_order_id) { '5O190127TN364715T' }
  let(:cart) { create(:cart_ready_for_delivery, store: store, customer: user) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:store_credit) { create(:store_credit, customer: user, store: store, amount: 5, currency: cart.currency) }
  let(:amount_due) { cart.reload.total_minus_store_credits }
  let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }
  let(:payment_session) do
    create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, amount: amount_due, external_id: paypal_order_id,
                                             external_data: fixture('paypal_order').merge('id' => paypal_order_id))
  end

  before do
    allow(PaypalServerSdk::Client).to receive(:new).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
    create(:store_credit_payment_method, store: store)
    store_credit
    cart.add_store_credit_payments
  end

  it 'applies the store credit, so PayPal is asked for less than the total' do
    expect([amount_due, cart.reload.total - amount_due]).to eq([cart.total - 5, 5])
  end

  describe 'PATCH of the session amount' do
    before do
      patch "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions/#{payment_session.prefixed_id}",
            params: { amount: money(cart.total) }, headers: bearer_headers, as: :json
    end

    it 'is refused as unprocessable' do
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'tells the storefront to create a new payment session' do
      expect(json_response.dig('error', 'message')).to match(/create a new payment session/)
    end

    it 'leaves the session amount as the amount due' do
      expect(payment_session.reload.amount).to eq(amount_due)
    end
  end

  describe 'PATCH of the session external_data' do
    before do
      patch "/api/v3/store/carts/#{cart.prefixed_id}/payment_sessions/#{payment_session.prefixed_id}",
            params: { external_data: { status: 'COMPLETED', purchase_units: [{ payments: { captures: [{ status: 'COMPLETED' }] } }] } },
            headers: bearer_headers, as: :json
    end

    it 'succeeds' do
      expect(response).to have_http_status(:ok)
    end

    it 'stores none of it' do
      expect(payment_session.reload).to have_attributes(paypal_capture: nil, external_data: a_hash_including('status' => 'CREATED'))
    end
  end

  # A session whose amount disagrees with PayPal's capture, such as one changed
  # before this release refused it.
  context 'when the session amount says the whole total but PayPal captured the amount due' do
    let(:captured) { captured_order(money(amount_due)) }

    before do
      payment_session.update!(amount: cart.reload.total)
      approved = fixture('paypal_order').merge('id' => paypal_order_id, 'status' => 'APPROVED',
                                               'purchase_units' => [{ 'amount' => { 'currency_code' => 'USD', 'value' => money(amount_due) } }])
      allow(orders_api).to receive_messages(get_order: paypal_response(approved), capture_order: paypal_response(captured))

      Spree::PaymentSessions::Complete.call(payment_session: Spree::PaymentSession.find(payment_session.id))
      Spree.carts_complete_workflow.call(cart: cart.reload)
    end

    let(:order) { cart.reload.order }
    let(:paypal_payment) { Spree::Payment.find_by!(response_code: paypal_order_id) }

    it 'records the amount PayPal captured on the PayPal payment' do
      expect(paypal_payment).to have_attributes(amount: amount_due, completed?: true)
    end

    it 'takes the rest from the store credit' do
      expect(order.payments.store_credits.map { |payment| [payment.amount, payment.status] }).to eq([[BigDecimal(5), 'completed']])
    end

    it 'spends the store credit' do
      expect(store_credit.reload.amount_used).to eq(5)
    end

    it 'places the order, paid in full' do
      expect(order).to have_attributes(completed?: true, payment_total: order.total)
    end
  end
end
