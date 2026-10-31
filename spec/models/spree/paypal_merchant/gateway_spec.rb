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

  it 'has no 5.x checkout flow' do
    own_methods = described_class.instance_methods(false) + described_class.private_instance_methods(false)

    expect(own_methods).not_to include(:find_order)
    expect(defined?(Spree::PaypalMerchant::Order)).to be_nil
    expect(Spree::Order.new).not_to respond_to(:paypal_id)
  end

  # Spree::Gateway hands authorize, purchase and capture it does not define to
  # #provider, which this gateway cannot build. Each answers for itself.
  it 'answers authorize, purchase and capture itself' do
    own_methods = described_class.instance_methods(false)

    expect(own_methods).to include(:authorize, :purchase, :capture)
  end

  # The dashboard lists third-party payment methods under Settings ->
  # Integrations as cards, with a letter avatar when there is no logo.
  describe '.provider_listing' do
    it 'shows the PayPal logo, links to the setup guide, and lists PayPal as third-party' do
      expect(described_class.provider_listing).to eq(
        logo_url: described_class.logo_url,
        docs_url: 'https://github.com/aypex-io/spree-paypal_merchant#readme',
        third_party: true
      )
    end
  end

  # Shipped with the gem, so the dashboard needs no asset pipeline and asks no
  # other host for it.
  describe '.logo_url' do
    let(:logo_path) { Spree::PaypalMerchant::Engine.root.join('lib/spree/paypal_merchant/paypal-mark.svg') }
    let(:prefix) { 'data:image/svg+xml;base64,' }

    it 'is an SVG data URI' do
      expect(described_class.logo_url).to start_with(prefix)
    end

    it "decodes to the bundled PayPal mark's exact bytes" do
      expect(described_class.logo_url.delete_prefix(prefix).unpack1('m0')).to eq(File.binread(logo_path))
    end

    it 'is built once, and frozen' do
      expect(described_class.logo_url).to be_frozen.and be_equal(described_class.logo_url)
    end

    it 'ships the mark in the gem' do
      gemspec = Bundler.load_gemspec(Spree::PaypalMerchant::Engine.root.join('spree-paypal_merchant.gemspec'))

      expect(gemspec.files).to include('lib/spree/paypal_merchant/paypal-mark.svg')
    end
  end

  describe '#webhook_url' do
    let(:store) { create(:store, url: store_url) }
    let(:store_url) { 'shop.example.com' }
    let(:path) { "/api/v3/webhooks/payments/#{gateway.prefixed_id}" }

    # PayPal only accepts an absolute https URL. The store is read afresh, as
    # it remembers its formatted URL once built.
    context 'in production' do
      before do
        gateway.reload
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('production'))
      end

      it "is an absolute https URL on the store's host" do
        expect(gateway.webhook_url).to eq("https://shop.example.com#{path}")
      end

      context 'when the store URL names another scheme and a port' do
        let(:store_url) { 'http://shop.example.com:8080' }

        it 'is still https, on the bare host' do
          expect(gateway.webhook_url).to eq("https://shop.example.com#{path}")
        end
      end
    end

    it 'is absolute in development and test too' do
      expect(gateway.webhook_url).to start_with('http://shop.example.com').and end_with(path)
    end

    it 'is nil without a store' do
      expect(described_class.new.webhook_url).to be_nil
    end
  end

  # PayPal captures at checkout. A store default must not make Spree treat a
  # pending PayPal payment as one it captures on dispatch or leaves to staff.
  describe '#resolved_capture_method' do
    %w[checkout on_dispatch manual].each do |store_default|
      context "when the store defaults to #{store_default}" do
        before { store.update!(preferred_capture_method: store_default) }

        it 'is checkout' do
          expect(gateway.resolved_capture_method).to eq('checkout')
        end

        it 'captures at checkout, never on dispatch or by hand' do
          expect([gateway.capture_at_checkout?, gateway.capture_on_dispatch?, gateway.capture_manually?]).to eq([true, false, false])
        end
      end
    end

    context 'when the store defaults to on_dispatch and an order holds a pending PayPal payment' do
      let(:order) { create(:order_ready_to_ship, store: store, with_payment: false) }
      let!(:paypal_payment) do
        create(:payment, order: order, payment_method: gateway, source: nil, amount: order.total, status: 'pending', response_code: 'ORDER-1',
                         skip_source_requirement: true)
      end

      before { store.update!(preferred_capture_method: 'on_dispatch') }

      it 'leaves the PayPal payment out of the payments the fulfillment captures on dispatch' do
        expect(order.reload.fulfillments.first.payments_to_capture_on_dispatch).not_to include(paypal_payment)
      end
    end
  end

  # Spree's checkout processing would send these. A PayPal payment is taken
  # through a payment session, so there is nothing to authorize or purchase.
  %i[authorize purchase].each do |verb|
    describe "##{verb}" do
      let(:response) { gateway.public_send(verb, Spree::Money.new(10, currency: 'USD'), nil, {}) }

      it 'is not a success' do
        expect(response).not_to be_success
      end

      it 'says PayPal payments are taken through a payment session' do
        expect(response.message).to match(/through a PayPal payment session/)
      end

      it 'does not call PayPal' do
        allow(gateway).to receive(:client)

        response

        expect(gateway).not_to have_received(:client)
      end
    end
  end

  # A failure marks the payment failed; a raise would leave it processing,
  # which void and cancel read as PayPal still completing it.
  context 'when Spree processes a PayPal payment outside a session' do
    let(:order) { create(:completed_order_with_totals, store: store) }
    let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
    let(:payment) { create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: 'checkout') }
    let!(:result) { Spree.payment_process_workflow.call(payment: payment) }

    it 'fails, saying PayPal payments are taken through a payment session' do
      expect([result.failure?, result.error.to_s]).to match([true, /through a PayPal payment session/])
    end

    it 'marks the payment failed, so it can be canceled' do
      expect(payment.reload).to be_failed
    end
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

    it 'lets the SDK repeat only GET and PUT' do
      gateway.client

      expect(PaypalServerSdk::Client).to have_received(:new).with(hash_including(retry_methods: %i[get put]))
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

    # A payment PayPal has not finished is never voided in Spree, which would
    # leave the money captured when PayPal completes it. Spree hands the gateway
    # the payment's prefixed id, so the message can tell the two apart.
    context 'when the payment is one of the gateway\'s own' do
      let(:order) { create(:completed_order_with_totals, store: store) }
      let(:payment_source) { Spree::PaypalMerchant::PaymentSources::Paypal.create!(payment_method: gateway, account_id: 'PAYPAL-ACCOUNT-123') }
      let(:status) { 'pending' }
      let(:payment) do
        create(:payment, order: order, payment_method: gateway, source: payment_source, amount: order.total, status: status, response_code: 'ORDER-1')
      end
      let(:options) { payment.gateway_options }
      let(:still_processing) { 'PayPal is still processing this payment; refund it once PayPal completes it.' }
      let(:captured) { 'PayPal payments are captured at checkout; refund the payment instead.' }

      %w[checkout pending processing].each do |unfinished|
        context "when it is #{unfinished}" do
          let(:status) { unfinished }

          it 'says PayPal is still processing it, and to refund it once it completes' do
            expect(gateway.void('ORDER-1', payment_source, options).message).to eq(still_processing)
          end

          it 'is still not a success' do
            expect(gateway.void('ORDER-1', payment_source, options)).not_to be_success
          end
        end
      end

      context 'when it is completed' do
        let(:status) { 'completed' }

        it 'says to refund it instead' do
          expect(gateway.void('ORDER-1', payment_source, options).message).to eq(captured)
        end
      end

      context 'when the id belongs to another payment method' do
        let(:other_payment) do
          create(:payment, order: create(:completed_order_with_totals, store: store), payment_method: create(:check_payment_method, store: store),
                           source: nil, amount: 10, status: 'pending')
        end

        it 'says to refund it instead' do
          expect(gateway.void('ORDER-1', payment_source, { payment_prefixed_id: other_payment.prefixed_id }).message).to eq(captured)
        end
      end

      it 'says to refund it instead when the id is not a payment' do
        expect(gateway.void('ORDER-1', payment_source, { payment_prefixed_id: 'pay_nonexistent' }).message).to eq(captured)
      end
    end
  end

  describe '#credit' do
    let(:payments_api) { instance_double(PaypalServerSdk::PaymentsController, refund_captured_payment: paypal_refund) }
    let(:refund_status) { 'COMPLETED' }
    let(:refund_json) { { 'id' => 'REFUND-456', 'status' => refund_status, 'status_details' => { 'reason' => 'ECHECK' } } }
    let(:paypal_refund) do
      refund_data = instance_double(PaypalServerSdk::Refund, id: 'REFUND-456', status: refund_status, as_json: refund_json)
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

    # PayPal can accept the request and still report that the refund did not happen.
    %w[FAILED CANCELLED].each do |status|
      context "when PayPal answers with a #{status} refund" do
        let(:refund_status) { status }

        it 'fails' do
          expect(gateway.credit(money, nil, 'ORDER-1', options)).not_to be_success
        end

        it 'says PayPal did not issue the refund, with its status' do
          expect(gateway.credit(money, nil, 'ORDER-1', options).message).to eq("PayPal did not issue the refund (status #{status}).")
        end

        it 'has no authorization, so no refund id is recorded' do
          expect(gateway.credit(money, nil, 'ORDER-1', options).authorization).to be_nil
        end

        it 'does not tell the merchant to check PayPal' do
          expect(gateway.credit(money, nil, 'ORDER-1', options).message).not_to match(/did not confirm/i)
        end

        # Spree logs the response when it refuses a refund.
        it "carries PayPal's refund in the params, for the log" do
          params = gateway.credit(money, nil, 'ORDER-1', options).params

          expect(params).to include('id' => 'REFUND-456', 'status' => status, 'status_details' => { 'reason' => 'ECHECK' })
        end

        # Spree reads params['message'] before the message, so it must be ours.
        context 'when the refund JSON has a message of its own' do
          let(:refund_json) { { 'id' => 'REFUND-456', 'status' => status, 'message' => 'something else' } }

          it 'still reports the message above' do
            response = gateway.credit(money, nil, 'ORDER-1', options)

            expect(response.params['message']).to eq("PayPal did not issue the refund (status #{status}).")
          end
        end
      end
    end

    # A pending refund is on its way to the buyer, so Spree records it.
    %w[PENDING COMPLETED].each do |status|
      context "when PayPal answers with a #{status} refund" do
        let(:refund_status) { status }

        it 'succeeds with the PayPal refund id' do
          expect(gateway.credit(money, nil, 'ORDER-1', options)).to be_success.and have_attributes(authorization: 'REFUND-456')
        end
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

    # Named as well as listed below, so dropping one from the list fails here.
    [Faraday::SSLError, Net::HTTP::Persistent::Error].each do |transport_error|
      context "when the connection fails with #{transport_error}" do
        before { allow(payments_api).to receive(:refund_captured_payment).and_raise(transport_error) }

        it_behaves_like 'a refund PayPal did not confirm'
      end
    end

    Spree::PaypalMerchant::Gateway::CONNECTION_ERRORS.each do |error_class|
      context "when the request fails with #{error_class}" do
        before { allow(payments_api).to receive(:refund_captured_payment).and_raise(error_class) }

        it_behaves_like 'a refund PayPal did not confirm'
      end
    end

    # A 502 or 503 with an HTML body: the SDK cannot build its error, so it
    # raises TypeError instead of an APIException. PayPal may have refunded.
    context 'when PayPal sends a server error that is not JSON' do
      before { allow(payments_api).to receive(:refund_captured_payment).and_raise(unreadable_paypal_answer) }

      it_behaves_like 'a refund PayPal did not confirm'

      it 'says PayPal sent an answer that could not be read' do
        expect(gateway.credit(money, nil, 'ORDER-1', options).message).to include('PayPal sent an answer that could not be read')
      end
    end

    # Any other TypeError is a bug, not an answer from PayPal.
    it 'lets a TypeError that is not about the JSON through' do
      allow(payments_api).to receive(:refund_captured_payment).and_raise(TypeError, "nil can't be coerced into BigDecimal")

      expect { gateway.credit(money, nil, 'ORDER-1', options) }.to raise_error(TypeError, /coerced/)
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

    # PayPal may still complete these, so they are never voided in Spree: that
    # would leave the money captured with no payment to refund. It raises
    # rather than failing, because a failed response would mark the payment
    # failed.
    %w[checkout pending processing].each do |unfinished_status|
      context "when the payment is #{unfinished_status}" do
        let(:status) { unfinished_status }

        it 'raises, saying PayPal is still processing it and to refund it once it completes' do
          expect { gateway.cancel(payment.response_code, payment) }
            .to raise_error(Spree::Core::GatewayError, 'PayPal is still processing this payment; refund it once PayPal completes it.')
        end

        it 'raises even when asked not to refund' do
          expect { gateway.cancel(payment.response_code, payment, refund: false) }.to raise_error(Spree::Core::GatewayError, /still processing/)
        end

        it 'does not refund or call PayPal' do
          expect { gateway.cancel(payment.response_code, payment) }.to raise_error(Spree::Core::GatewayError)

          expect(Spree.refund_create_workflow).not_to have_received(:call)
          expect(gateway).not_to have_received(:client)
        end
      end
    end

    # These hold no money, so there is nothing to wait for or to refund.
    %w[failed void invalid].each do |dead_status|
      context "when the payment is #{dead_status}" do
        let(:status) { dead_status }

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

  # Spree's Capture action, for a payment left pending by a pending PayPal
  # capture. PayPal captured at checkout, so this only reads the PayPal order
  # and reports what PayPal did.
  describe '#capture' do
    let(:orders_api) { instance_double(PaypalServerSdk::OrdersController) }
    let(:capture_status) { 'COMPLETED' }
    let(:captures) { [{ 'id' => 'CAP-1', 'status' => capture_status, 'amount' => { 'currency_code' => 'USD', 'value' => '30.00' } }] }
    let(:paypal_order) { { 'id' => 'ORDER-1', 'status' => 'COMPLETED', 'purchase_units' => [{ 'payments' => { 'captures' => captures } }] } }
    let(:money) { Spree::Money.new(30, currency: 'USD') }

    def paypal_response(data)
      order = instance_double(PaypalServerSdk::Order, id: data['id'], status: data['status'], as_json: data)
      instance_double(PaypalServerSdk::ApiResponse, data: order)
    end

    def capture
      gateway.capture(money, 'ORDER-1', {})
    end

    before do
      allow(gateway).to receive(:client).and_return(instance_double(PaypalServerSdk::Client, orders: orders_api))
      allow(orders_api).to receive(:get_order).and_return(paypal_response(paypal_order))
      allow(orders_api).to receive(:capture_order)
    end

    context 'when PayPal completed the capture' do
      it 'succeeds' do
        expect(capture).to be_success
      end

      it 'reads the PayPal order named by the response code' do
        capture

        expect(orders_api).to have_received(:get_order).with('id' => 'ORDER-1', 'prefer' => 'return=representation')
      end

      it 'never captures at PayPal' do
        capture

        expect(orders_api).not_to have_received(:capture_order)
      end

      # Spree copies a non-nil authorization into the payment's response code,
      # which is the PayPal order id that links the payment to its session.
      it 'returns no authorization' do
        expect(capture.authorization).to be_nil
      end

      context 'when asked for less than PayPal captured' do
        let(:money) { Spree::Money.new(10, currency: 'USD') }

        it 'raises, since PayPal took the whole amount' do
          expect { capture }.to raise_error(Spree::Core::GatewayError, /PayPal captured 30.00 USD/)
        end
      end
    end

    context 'when PayPal is still processing the capture' do
      let(:capture_status) { 'PENDING' }

      it 'raises, saying PayPal is still processing the payment' do
        expect { capture }.to raise_error(Spree::Core::GatewayError, /PayPal is still processing this payment/)
      end
    end

    # A failed response makes Spree fail the payment: no money moved.
    %w[DECLINED FAILED].each do |status|
      context "when PayPal's capture is #{status}" do
        let(:capture_status) { status }

        it 'fails, with the status' do
          expect(capture).to have_attributes(success?: false, message: "PayPal did not take this payment (capture #{status}).")
        end
      end
    end

    # Money moved and came back, or none is recorded: settling that is for the
    # merchant, so nothing changes.
    %w[REFUNDED PARTIALLY_REFUNDED].each do |status|
      context "when PayPal's capture is #{status}" do
        let(:capture_status) { status }

        it 'raises, naming the status' do
          expect { capture }.to raise_error(Spree::Core::GatewayError, /#{status}/)
        end
      end
    end

    context 'when the PayPal order holds no capture' do
      let(:captures) { [] }

      it 'raises' do
        expect { capture }.to raise_error(Spree::Core::GatewayError, /no capture/)
      end
    end

    # Without PayPal's answer the payment is left as it is, to be tried again.
    context 'when PayPal cannot be read' do
      [503, 404].each do |status|
        it "raises when PayPal answers #{status}" do
          allow(orders_api).to receive(:get_order).and_raise(PaypalServerSdk::APIException.new('PayPal error', double(status_code: status)))

          expect { capture }.to raise_error(Spree::Core::GatewayError, /PayPal API error/)
        end
      end

      Spree::PaypalMerchant::Gateway::CONNECTION_ERRORS.each do |error_class|
        it "raises when the request fails with #{error_class}" do
          allow(orders_api).to receive(:get_order).and_raise(error_class)

          expect { capture }.to raise_error(Spree::Core::GatewayError)
        end
      end

      it 'raises when PayPal sends a server error that is not JSON' do
        allow(orders_api).to receive(:get_order).and_raise(unreadable_paypal_answer)

        expect { capture }.to raise_error(Spree::Core::GatewayError)
      end
    end

    # Spree's capture workflow claims the payment (processing) before it asks
    # the gateway, and has no undo for a raise. Each raise puts the payment
    # back to pending, so Capture can be pressed again.
    context "when Spree has claimed one of the gateway's own payments" do
      let(:order) { create(:completed_order_with_totals, store: store) }
      let(:status) { 'processing' }
      let(:payment) do
        create(:payment, order: order, payment_method: gateway, source: nil, amount: 30, status: status, response_code: 'ORDER-1',
                         skip_source_requirement: true)
      end

      def capture
        gateway.capture(money, 'ORDER-1', payment.gateway_options)
      end

      {
        'PayPal is still processing the capture' => -> { captures[0]['status'] = 'PENDING' },
        'PayPal cannot be read' => -> { allow(orders_api).to receive(:get_order).and_raise(Faraday::ConnectionFailed) },
        'PayPal sends a server error that is not JSON' => -> { allow(orders_api).to receive(:get_order).and_raise(unreadable_paypal_answer) },
        'the amount differs from what PayPal captured' => -> { captures[0]['amount']['value'] = '29.00' },
        "PayPal's capture is REFUNDED" => -> { captures[0]['status'] = 'REFUNDED' }
      }.each do |situation, arrange|
        context "when #{situation}" do
          before { instance_exec(&arrange) }

          it 'raises and puts the payment back to pending' do
            expect { capture }.to raise_error(Spree::Core::GatewayError)

            expect(payment.reload).to be_pending
          end
        end
      end

      context 'when PayPal declined the capture' do
        let(:capture_status) { 'DECLINED' }

        it 'leaves the status to Spree, which fails the payment' do
          expect(capture).not_to be_success
          expect(payment.reload).to be_processing
        end
      end

      # A webhook that completed the payment meanwhile wins.
      context 'when the payment completed while PayPal was asked' do
        let(:status) { 'completed' }
        let(:capture_status) { 'PENDING' }

        it 'leaves it completed' do
          expect { capture }.to raise_error(Spree::Core::GatewayError)

          expect(payment.reload).to be_completed
        end
      end

      context 'when the payment belongs to another payment method' do
        let(:capture_status) { 'PENDING' }
        let(:payment) do
          create(:payment, order: order, payment_method: create(:check_payment_method, store: store), source: nil, amount: 30,
                           status: 'processing')
        end

        it 'leaves it alone' do
          expect { capture }.to raise_error(Spree::Core::GatewayError)

          expect(payment.reload).to be_processing
        end
      end
    end
  end

  # What the SDK raises for a PayPal server error whose body is not JSON (an
  # HTML error page): building its error fails before an APIException exists.
  def unreadable_paypal_answer
    PaypalServerSdk::ErrorException.new('Bad gateway', double(status_code: 502, raw_body: '<html>Bad gateway</html>'))
  rescue TypeError => e
    e
  end
end
