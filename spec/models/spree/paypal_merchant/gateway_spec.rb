# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::Gateway do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }

  describe 'validations' do
    it 'requires client_id' do
      gateway.preferred_client_id = nil
      expect(gateway).not_to be_valid
    end

    it 'requires client_secret' do
      gateway.preferred_client_secret = nil
      expect(gateway).not_to be_valid
    end
  end

  describe '#session_required?' do
    it 'returns true' do
      expect(gateway.session_required?).to be true
    end
  end

  describe '#payment_session_class' do
    it 'returns Spree::PaymentSessions::PaypalMerchant' do
      expect(gateway.payment_session_class).to eq(Spree::PaymentSessions::PaypalMerchant)
    end
  end

  describe '#payment_source_class' do
    it 'returns the PayPal wallet source' do
      expect(gateway.payment_source_class).to eq(Spree::PaypalMerchant::PaymentSources::Paypal)
    end
  end

  describe '#method_type' do
    it 'returns spree_paypal_merchant' do
      expect(gateway.method_type).to eq('spree_paypal_merchant')
    end
  end

  describe '#default_name' do
    it 'returns PayPal' do
      expect(gateway.default_name).to eq('PayPal')
    end
  end

  describe '#apple_pay_enabled?' do
    it 'is true by default' do
      expect(gateway.apple_pay_enabled?).to be true
    end
  end

  it 'does not define an unused apple_pay_domain preference' do
    expect(gateway.has_preference?(:apple_pay_domain)).to be false
  end

  describe 'public funding preferences' do
    it 'exposes apple pay and card fields flags' do
      expect(gateway.public_preferences).to include(enable_apple_pay: true, enable_card_fields: true)
    end

    it 'reflects disabled card fields' do
      gateway.preferred_enable_card_fields = false
      expect(gateway.card_fields_enabled?).to be false
    end
  end

  it 'has no pre-session capture flow' do
    # Spree::Gateway delegates authorize/purchase/capture to #provider, so
    # respond_to? is always true; check that this gateway defines none itself.
    own_methods = described_class.instance_methods(false) + described_class.private_instance_methods(false)

    expect(own_methods).not_to include(:authorize, :purchase, :capture, :find_order)
    expect(defined?(Spree::PaypalMerchant::Order)).to be_nil
    expect(Spree::Order.new).not_to respond_to(:paypal_id)
  end

  it "finds the store's active PayPal gateway" do
    gateway

    expect(store.paypal_merchant_gateway).to eq(gateway)
    expect(Spree::PaymentMethod.paypal_merchant).to include(gateway)
  end

  describe '#client' do
    it 'returns a PayPal SDK client' do
      expect(gateway.client).to be_a(PaypalServerSdk::Client)
    end
  end

  describe '#client limits' do
    before { allow(PaypalServerSdk::Client).to receive(:new).and_call_original }

    it 'builds the client with the request timeout and the retry count' do
      gateway.client

      expect(PaypalServerSdk::Client).to have_received(:new).with(
        hash_including(timeout: Spree::PaypalMerchant::Gateway::REQUEST_TIMEOUT, max_retries: Spree::PaypalMerchant::Gateway::MAX_RETRIES)
      )
    end

    it 'limits a request to 15 seconds and retries a read 3 times' do
      expect([Spree::PaypalMerchant::Gateway::REQUEST_TIMEOUT, Spree::PaypalMerchant::Gateway::MAX_RETRIES]).to eq([15, 3])
    end
  end

  # Stubbed at the HTTP level, so the SDK's own retry middleware is what runs.
  describe '#client retries' do
    let(:paypal_api) { 'https://api-m.sandbox.paypal.com' }
    let(:order_url) { "#{paypal_api}/v2/checkout/orders/ORDER-1" }
    let(:json_headers) { { 'Content-Type' => 'application/json' } }
    let(:order_body) { { id: 'ORDER-1', status: 'APPROVED' }.to_json }

    before do
      stub_request(:post, "#{paypal_api}/v1/oauth2/token")
        .to_return(status: 200, headers: json_headers, body: { access_token: 'token', token_type: 'Bearer', expires_in: 32_400 }.to_json)
      # The wait between attempts is the SDK's default; the specs do not sit through it.
      allow_any_instance_of(Faraday::Retry::Middleware).to receive(:sleep)
    end

    it 'retries a read that PayPal answers with a server error' do
      stub_request(:get, order_url)
        .to_return({ status: 503, headers: json_headers, body: '{}' }, { status: 200, headers: json_headers, body: order_body })

      expect(gateway.fetch_paypal_order('ORDER-1').data).to have_attributes(id: 'ORDER-1', status: 'APPROVED')
      expect(a_request(:get, order_url)).to have_been_made.twice
    end

    it 'gives up on a read after the third retry' do
      stub_request(:get, order_url).to_return(status: 503, headers: json_headers, body: '{}')

      expect { gateway.fetch_paypal_order('ORDER-1') }.to raise_error(PaypalServerSdk::APIException)
      expect(a_request(:get, order_url)).to have_been_made.times(1 + Spree::PaypalMerchant::Gateway::MAX_RETRIES)
    end

    it 'never sends a capture twice, so a retry cannot capture a second time' do
      stub_request(:post, "#{order_url}/capture").to_return(status: 503, headers: json_headers, body: '{}')

      expect { gateway.client.orders.capture_order('id' => 'ORDER-1') }.to raise_error(PaypalServerSdk::APIException)
      expect(a_request(:post, "#{order_url}/capture")).to have_been_made.once
    end
  end

  describe '#fetch_paypal_order' do
    let(:orders_api) { instance_double(PaypalServerSdk::OrdersController, get_order: paypal_response) }
    let(:paypal_response) { double(data: double(status: 'COMPLETED')) }

    before { allow(gateway).to receive(:client).and_return(double(orders: orders_api)) }

    it 'asks PayPal for the order with its captures' do
      gateway.fetch_paypal_order('ORDER-1')

      expect(orders_api).to have_received(:get_order).with('id' => 'ORDER-1', 'prefer' => 'return=representation')
    end

    it 'returns the PayPal response' do
      expect(gateway.fetch_paypal_order('ORDER-1')).to eq(paypal_response)
    end
  end

  describe '#client logging' do
    it 'does not log PayPal request bodies' do
      allow(PaypalServerSdk::RequestLoggingConfiguration).to receive(:new).and_call_original

      gateway.client

      expect(PaypalServerSdk::RequestLoggingConfiguration).to have_received(:new).with(
        hash_including(log_body: false)
      )
    end
  end

  describe '#create_profile' do
    let(:user) { create(:user) }
    let(:order) { create(:order_with_line_items, customer: user, store: store) }
    let(:payment_source) do
      Spree::PaypalMerchant::PaymentSources::Paypal.create!(
        payment_method: gateway,
        account_id: 'PAYPAL-ACCOUNT-123'
      )
    end
    let(:payment) { create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total) }

    # Read from the database: the payment method's association can be loaded.
    def gateway_customers
      Spree::GatewayCustomer.where(payment_method_id: gateway.id)
    end

    it 'creates a gateway customer record' do
      expect { gateway.create_profile(payment) }.to change { gateway_customers.count }.by(1)
    end

    it 'links the profile to the buyer as a customer' do
      gateway.create_profile(payment)

      expect(gateway_customers.sole).to have_attributes(customer_id: order.customer_id, profile_id: 'PAYPAL-ACCOUNT-123')
    end

    it 'returns the gateway customer' do
      expect(gateway.create_profile(payment)).to be_a(Spree::GatewayCustomer).and be_persisted
    end

    it 'keeps one profile when asked again for the same account' do
      gateway.create_profile(payment)

      expect { gateway.create_profile(payment) }.not_to(change { gateway_customers.count })
    end

    # A customer holds one profile per payment method, so a second PayPal
    # account is not stored; it must not raise at settlement.
    it 'keeps the first profile when the customer pays from another PayPal account' do
      gateway.create_profile(payment)
      other_source = Spree::PaypalMerchant::PaymentSources::Paypal.create!(
        payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-456', gateway_payment_profile_id: 'PROFILE-2'
      )
      other_payment = create(:payment, order: order, payment_method: gateway, source: other_source, amount: order.total)

      expect { gateway.create_profile(other_payment) }.not_to raise_error
      expect(gateway_customers.pluck(:profile_id)).to eq(['PAYPAL-ACCOUNT-123'])
    end

    context 'when the payment belongs to a cart' do
      let(:cart) { create(:cart_with_line_items, customer: user, store: store) }
      let(:payment) { create(:payment, cart: cart, order: nil, payment_method: gateway, source: payment_source, amount: cart.total) }

      it 'creates a gateway customer for the cart customer' do
        gateway.create_profile(payment)

        expect(gateway_customers.sole).to have_attributes(customer_id: user.id)
      end
    end

    # A guest checkout has an owner with no customer: nothing to link, nothing to raise.
    context 'when the buyer is a guest' do
      let(:order) { create(:order_with_line_items, customer: nil, store: store) }

      it 'creates no gateway customer' do
        expect { gateway.create_profile(payment) }.not_to(change { gateway_customers.count })
      end

      it 'returns nil without an error' do
        expect(gateway.create_profile(payment)).to be_nil
      end
    end

    context 'when a guest pays from a cart' do
      let(:cart) { create(:cart_with_line_items, customer: nil, store: store) }
      let(:payment) { create(:payment, cart: cart, order: nil, payment_method: gateway, source: payment_source, amount: cart.total) }

      it 'creates no gateway customer' do
        expect { gateway.create_profile(payment) }.not_to(change { gateway_customers.count })
      end
    end

    context 'when the source has no PayPal account id' do
      let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway) }

      it 'creates no gateway customer' do
        expect { gateway.create_profile(payment) }.not_to(change { gateway_customers.count })
      end
    end

    context 'when the source is Apple Pay' do
      let(:payment_source) { create(:paypal_merchant_apple_pay_source, payment_method: gateway) }

      it 'does not create a gateway customer' do
        expect(gateway.create_profile(payment)).to be_nil
      end
    end
  end

  describe 'money amounts' do
    it 'accepts Spree::Money amounts' do
      expect(described_class.accepts_money_amounts).to be true
    end

    # Without it Spree 6 hands the gateway hundredths, and warns that they go in 6.1.
    it 'gives the gateway a Spree::Money for a refund, not hundredths' do
      expect(gateway.gateway_amount(12.5, 'GBP')).to be_a(Spree::Money).and have_attributes(currency: Spree::Money.new(1, currency: 'GBP').currency)
    end

    it 'does not warn about hundredths' do
      expect { gateway.gateway_amount(12.5, 'GBP') }.not_to output(/hundredths/).to_stderr
    end
  end

  describe '#void' do
    let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController) }

    before { allow(gateway).to receive(:client).and_return(instance_double(PaypalServerSdk::Client, payments: payments_api)) }

    it 'is not a success' do
      expect(gateway.void('ORDER-1', nil)).not_to be_success
    end

    it 'tells the merchant to refund instead' do
      expect(gateway.void('ORDER-1', nil).message).to eq('PayPal payments are captured at checkout; refund the payment instead.')
    end

    it 'takes the arguments Spree passes it' do
      expect(gateway.void('ORDER-1', double, { order_id: 'R1' })).not_to be_success
    end

    it 'does not call PayPal' do
      gateway.void('ORDER-1', nil)

      expect(gateway).not_to have_received(:client)
    end

    it 'reads as the failure message when Spree reports it' do
      payment = build_stubbed(:payment)

      expect { payment.gateway_error(gateway.void('ORDER-1', nil)) }
        .to raise_error(Spree::Core::GatewayError, 'PayPal payments are captured at checkout; refund the payment instead.')
    end
  end

  describe '#credit' do
    let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController, refund_captured_payment: paypal_refund) }
    let(:paypal_refund) do
      refund_data = instance_double(PaypalServerSdk::Refund, id: 'REFUND-456', as_json: { 'id' => 'REFUND-456', 'status' => 'COMPLETED' })
      instance_double(PaypalServerSdk::ApiResponse, data: refund_data)
    end
    let(:metadata) { { 'paypal_capture_id' => 'CAP-1' } }
    let(:payment) { instance_double(Spree::Payment, metadata: metadata) }
    let(:refund) { instance_double(Spree::Refund, payment: payment) }
    let(:options) { { originator: refund } }
    let(:money) { Spree::Money.new(75, currency: 'USD') }

    before { allow(gateway).to receive(:client).and_return(instance_double(PaypalServerSdk::Client, payments: payments_api)) }

    # The request PayPal's refund endpoint is sent.
    def refund_of(capture_id, value, currency)
      { 'capture_id' => capture_id, 'amount' => { 'value' => value, 'currency_code' => currency } }
    end

    it 'refunds the capture recorded on the payment, to the currency decimals' do
      gateway.credit(money, nil, 'ORDER-1', options)

      expect(payments_api).to have_received(:refund_captured_payment).once.with(refund_of('CAP-1', '75.00', 'USD'))
    end

    it 'succeeds with the PayPal refund id as the authorization' do
      response = gateway.credit(money, nil, 'ORDER-1', options)

      expect(response).to be_success.and have_attributes(authorization: 'REFUND-456')
    end

    it 'returns a Spree payment response' do
      expect(gateway.credit(money, nil, 'ORDER-1', options)).to be_a(Spree::PaymentResponse)
    end

    context 'when the payment has no capture id (taken on 5.x)' do
      let(:metadata) { {} }

      it 'refunds the capture named by the response code' do
        gateway.credit(money, nil, 'CAPTURE-FROM-5X', options)

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAPTURE-FROM-5X', '75.00', 'USD'))
      end
    end

    context 'when there is no originator' do
      let(:options) { {} }

      it 'refunds the capture named by the response code' do
        gateway.credit(money, nil, 'CAPTURE-FROM-5X', options)

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAPTURE-FROM-5X', '75.00', 'USD'))
      end
    end

    context 'with a partial refund in pounds' do
      let(:money) { Spree::Money.new(12.5, currency: 'GBP') }

      it 'sends two decimals' do
        gateway.credit(money, nil, 'ORDER-1', options)

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAP-1', '12.50', 'GBP'))
      end
    end

    context 'with a currency that has no decimals' do
      let(:money) { Spree::Money.new(1000, currency: 'JPY') }

      it 'sends a whole number' do
        gateway.credit(money, nil, 'ORDER-1', options)

        expect(payments_api).to have_received(:refund_captured_payment).with(refund_of('CAP-1', '1000', 'JPY'))
      end
    end

    def paypal_error(status, message: 'The refund could not be made')
      PaypalServerSdk::ErrorException.new(message, double(status_code: status, raw_body: { name: 'UNPROCESSABLE_ENTITY', message: message }.to_json))
    end

    # PayPal looked at the request and said no, so the money did not move.
    context 'when PayPal refuses the refund' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(422, message: 'The capture is fully refunded')) }

      it 'fails' do
        expect(gateway.credit(money, nil, 'ORDER-1', options)).not_to be_success
      end

      it "fails with PayPal's message" do
        expect(gateway.credit(money, nil, 'ORDER-1', options).message).to include('The capture is fully refunded')
      end

      it 'does not tell the merchant to check PayPal' do
        expect(gateway.credit(money, nil, 'ORDER-1', options).message).not_to match(/did not confirm/i)
      end

      it 'returns the failure rather than raising' do
        expect { gateway.credit(money, nil, 'ORDER-1', options) }.not_to raise_error
      end
    end

    # Not knowing whether PayPal acted is the one way an admin retry can
    # refund twice, so the message says to check PayPal first.
    shared_examples 'a refund PayPal did not confirm' do
      it 'fails' do
        expect(gateway.credit(money, nil, 'ORDER-1', options)).not_to be_success
      end

      it 'says PayPal did not confirm the refund' do
        expect(gateway.credit(money, nil, 'ORDER-1', options).message).to match(/PayPal did not confirm the refund/)
      end

      it 'tells the merchant to check PayPal before retrying' do
        expect(gateway.credit(money, nil, 'ORDER-1', options).message).to match(/check .*PayPal before (retrying|trying again)/i)
      end

      it 'returns the failure rather than raising' do
        expect { gateway.credit(money, nil, 'ORDER-1', options) }.not_to raise_error
      end

      it 'asks PayPal once' do
        gateway.credit(money, nil, 'ORDER-1', options)

        expect(payments_api).to have_received(:refund_captured_payment).once
      end
    end

    [500, 503, 401, 408, 429].each do |status|
      context "when PayPal answers #{status}" do
        before { allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(status)) }

        it_behaves_like 'a refund PayPal did not confirm'
      end
    end

    Spree::PaypalMerchant::Gateway::CONNECTION_ERRORS.each do |error_class|
      context "when the request fails with #{error_class}" do
        before { allow(payments_api).to receive(:refund_captured_payment).and_raise(error_class) }

        it_behaves_like 'a refund PayPal did not confirm'
      end
    end

    # Spree::Refund turns a failed response into the error it shows the admin.
    it "is reported to the admin as the refund's error" do
      allow(payments_api).to receive(:refund_captured_payment).and_raise(paypal_error(503))
      response = gateway.credit(money, nil, 'ORDER-1', options)

      expect(response.params['message'] || response.message).to match(/PayPal did not confirm the refund/)
    end
  end

  describe '#cancel' do
    let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController) }
    let(:canceler) { create(:admin_user) }
    let(:order) { create(:completed_order_with_totals, store: store) }
    let(:status) { 'completed' }
    let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
    let(:payment) do
      create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: status,
                       response_code: 'ORDER-1', metadata: { 'paypal_capture_id' => 'CAP-1' })
    end
    let(:refund) { instance_double(Spree::Refund) }
    let(:workflow_result) { Spree::ServiceModule::Result.new(true, refund, nil) }

    before do
      allow(gateway).to receive(:client).and_return(instance_double(PaypalServerSdk::Client, payments: payments_api))
      allow(Spree.refund_create_workflow).to receive(:call).and_return(workflow_result)
      order.update!(canceler: canceler)
    end

    context 'when the payment is completed' do
      it 'refunds it through the refund workflow, for the canceled reason, by whoever canceled' do
        gateway.cancel(payment.response_code, payment)

        expect(Spree.refund_create_workflow).to have_received(:call).with(
          payment: payment, reason: Spree::RefundReason.order_canceled_reason(store), refunder: canceler
        )
      end

      it 'succeeds' do
        expect(gateway.cancel(payment.response_code, payment)).to be_success
      end

      # handle_response copies a non-nil authorization into the payment's
      # response_code, which here is the PayPal order id that links the session.
      it 'returns no authorization' do
        expect(gateway.cancel(payment.response_code, payment).authorization).to be_nil
      end

      it 'returns a Spree payment response' do
        expect(gateway.cancel(payment.response_code, payment)).to be_a(Spree::PaymentResponse)
      end

      it 'does not call PayPal directly' do
        gateway.cancel(payment.response_code, payment)

        expect(gateway).not_to have_received(:client)
      end
    end

    context 'when the refund workflow fails' do
      let(:workflow_result) { Spree::ServiceModule::Result.new(false, refund, Spree::ServiceModule::ResultError.new('PayPal declined the refund: nope')) }

      it 'raises a GatewayError with the workflow error' do
        expect { gateway.cancel(payment.response_code, payment) }.to raise_error(Spree::Core::GatewayError, 'PayPal declined the refund: nope')
      end
    end

    context 'when asked not to refund' do
      it 'does not refund' do
        gateway.cancel(payment.response_code, payment, refund: false)

        expect(Spree.refund_create_workflow).not_to have_received(:call)
      end

      it 'succeeds with no authorization' do
        expect(gateway.cancel(payment.response_code, payment, refund: false)).to be_success.and have_attributes(authorization: nil)
      end
    end

    context 'when nothing is left to refund' do
      before { allow(payment).to receive(:credit_allowed).and_return(0) }

      it 'does not refund' do
        gateway.cancel(payment.response_code, payment)

        expect(Spree.refund_create_workflow).not_to have_received(:call)
      end

      it 'succeeds with no authorization' do
        expect(gateway.cancel(payment.response_code, payment)).to be_success.and have_attributes(authorization: nil)
      end
    end

    %w[pending processing checkout].each do |incomplete_status|
      context "when the payment is #{incomplete_status}" do
        let(:status) { incomplete_status }

        it 'succeeds without calling PayPal' do
          expect(gateway.cancel(payment.response_code, payment)).to be_success
          expect(gateway).not_to have_received(:client)
        end

        it 'does not refund' do
          gateway.cancel(payment.response_code, payment)

          expect(Spree.refund_create_workflow).not_to have_received(:call)
        end

        it 'returns no authorization' do
          expect(gateway.cancel(payment.response_code, payment).authorization).to be_nil
        end
      end
    end

    context 'when there is no payment' do
      it 'succeeds without calling PayPal' do
        expect(gateway.cancel('ORDER-1')).to be_success
        expect(gateway).not_to have_received(:client)
      end
    end
  end
end
