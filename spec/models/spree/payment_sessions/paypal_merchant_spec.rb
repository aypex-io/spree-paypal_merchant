# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaymentSessions::PaypalMerchant do
  def fixture(name)
    JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join("spec/fixtures/#{name}.json")))
  end

  # A captured order fixture whose capture took the cart's total: the payment
  # records the amount PayPal captured.
  def captured_for_cart(name)
    fixture(name).tap do |data|
      data['purchase_units'][0]['payments']['captures'][0]['amount'] = { 'currency_code' => cart.currency, 'value' => format('%.2f', cart.total) }
    end
  end

  let(:captured_data) { captured_for_cart('captured_paypal_order') }
  let(:apple_pay_data) { captured_for_cart('captured_apple_pay_order') }
  let(:created_data) { fixture('paypal_order') }
  let(:pending_data) do
    captured_for_cart('captured_paypal_order').tap do |data|
      data['status'] = 'APPROVED'
      data['purchase_units'][0]['payments']['captures'][0]['status'] = 'PENDING'
    end
  end
  let(:declined_data) do
    captured_for_cart('captured_paypal_order').tap do |data|
      data['purchase_units'][0]['payments']['captures'][0]['status'] = 'DECLINED'
    end
  end
  let(:external_data) { captured_data }
  let(:cart) { create(:cart_with_line_items) }
  # A payment can only settle through a method that belongs to the cart's store.
  let(:gateway) { create(:paypal_merchant_gateway, store: cart.store) }
  let(:session) do
    create(:paypal_merchant_payment_session, cart: cart, payment_method: gateway, external_data: external_data)
  end

  describe 'factory' do
    it 'builds a session that can settle with its default cart and gateway' do
      default_session = create(:paypal_merchant_payment_session, external_data: captured_data)

      expect(default_session.settle_payment!(captured: true)).to be_completed
    end

    it 'builds a gateway in the cart store for each of several carts in one store' do
      store = create(:store)
      sessions = Array.new(2) { create(:paypal_merchant_payment_session, cart: create(:cart_with_line_items, store: store)) }

      expect(sessions.map { |each_session| each_session.payment_method.store_id }).to eq([store.id, store.id])
    end
  end

  describe '#paypal_order_id' do
    let(:session) { create(:paypal_merchant_payment_session, external_id: 'ORDER-123') }

    it 'returns the external_id' do
      expect(session.paypal_order_id).to eq('ORDER-123')
    end
  end

  describe '#paypal_capture' do
    it 'returns the first capture hash when the order is captured' do
      expect(session.paypal_capture).to include('id' => '6F473251BB811841E', 'status' => 'COMPLETED')
    end

    context 'when the order is not captured' do
      let(:external_data) { created_data }

      it 'returns nil' do
        expect(session.paypal_capture).to be_nil
      end
    end
  end

  describe '#paypal_capture_id' do
    it 'returns the capture ID from external_data when the order is captured' do
      expect(session.paypal_capture_id).to eq('6F473251BB811841E')
    end

    context 'when the order is not captured' do
      let(:external_data) { created_data }

      it 'returns nil' do
        expect(session.paypal_capture_id).to be_nil
      end
    end
  end

  describe '#paypal_capture_status' do
    it 'returns the capture status when the order is captured' do
      expect(session.paypal_capture_status).to eq('COMPLETED')
    end

    context 'when the order is not captured' do
      let(:external_data) { created_data }

      it 'returns nil' do
        expect(session.paypal_capture_status).to be_nil
      end
    end
  end

  describe '#capture_settled?' do
    %w[COMPLETED DECLINED FAILED].each do |status|
      context "when the capture is #{status}" do
        let(:external_data) do
          captured_data.tap { |data| data['purchase_units'][0]['payments']['captures'][0]['status'] = status }
        end

        it 'is true' do
          expect(session.capture_settled?).to be true
        end
      end
    end

    context 'when the capture is PENDING' do
      let(:external_data) { pending_data }

      it 'is false' do
        expect(session.capture_settled?).to be false
      end
    end

    context 'when the order is not captured' do
      let(:external_data) { created_data }

      it 'is false' do
        expect(session.capture_settled?).to be false
      end
    end
  end

  describe '#accepted?' do
    it 'is true when the capture is COMPLETED' do
      expect(session.accepted?).to be true
    end

    # PayPal can report an order as COMPLETED whose capture was declined.
    context 'when the order is COMPLETED but its capture was DECLINED' do
      let(:external_data) { declined_data }

      it 'is false' do
        expect(session.accepted?).to be false
      end
    end

    context 'when the capture is pending' do
      let(:external_data) { pending_data }

      it 'is false' do
        expect(session.accepted?).to be false
      end
    end

    context 'when the order is not captured' do
      let(:external_data) { created_data }

      it 'is false' do
        expect(session.accepted?).to be false
      end
    end
  end

  describe '#successful?' do
    it 'is true when the capture is COMPLETED' do
      expect(session.successful?).to be true
    end

    context 'when the order is COMPLETED but its capture was DECLINED' do
      let(:external_data) { declined_data }

      it 'is false' do
        expect(session.successful?).to be false
      end
    end
  end

  describe '#settle_payment!' do
    it 'creates one payment on the cart' do
      payment = session.settle_payment!(captured: true)

      expect(cart.payments.to_a).to eq([payment])
    end

    it 'keys the payment on the PayPal order id' do
      payment = session.settle_payment!(captured: true)

      expect(payment.response_code).to eq(session.external_id)
    end

    it 'records the capture id in the payment metadata' do
      payment = session.settle_payment!(captured: true)

      expect(payment.reload.metadata['paypal_capture_id']).to eq('6F473251BB811841E')
    end

    it 'merges metadata passed by the caller' do
      payment = session.settle_payment!(captured: true, metadata: { 'paypal_event_id' => 'WH-1' })

      expect(payment.reload.metadata).to include('paypal_event_id' => 'WH-1', 'paypal_capture_id' => '6F473251BB811841E')
    end

    it 'creates a PayPal payment source' do
      payment = session.settle_payment!(captured: true)

      expect(payment.source).to be_a(Spree::PaypalMerchant::PaymentSources::Paypal)
    end

    it 'completes the payment' do
      payment = session.settle_payment!(captured: true)

      expect(payment.completed?).to be true
    end

    it 'links the session to the payment' do
      payment = session.settle_payment!(captured: true)

      expect(session.reload.payment).to eq(payment)
    end

    it 'keeps the cart at one payment when called twice' do
      session.settle_payment!(captured: true)

      expect { session.settle_payment!(captured: true) }.not_to change { cart.payments.count }.from(1)
    end

    context 'when the captured source is Apple Pay' do
      let(:external_data) { apple_pay_data }

      it 'creates an Apple Pay payment source' do
        payment = session.settle_payment!(captured: true)

        expect(payment.source).to be_a(Spree::PaypalMerchant::PaymentSources::ApplePay)
      end
    end

    context 'when payment_source data is not present' do
      let(:external_data) { captured_data.except('payment_source') }

      it 'creates a payment without a source' do
        payment = session.settle_payment!(captured: true)

        expect(payment.source).to be_nil
      end
    end

    # The money is already captured, so an unknown wallet must not stop the payment.
    context 'when PayPal reports a payment source the gem does not support' do
      let(:external_data) { captured_data.merge('payment_source' => { 'venmo' => { 'email_address' => 'buyer@example.com' } }) }

      before { allow(Rails.logger).to receive(:warn) }

      it 'completes a payment without a source' do
        payment = session.settle_payment!(captured: true)

        expect(payment).to have_attributes(source: nil, completed?: true)
      end
    end

    context 'when the capture is still pending' do
      let(:external_data) { pending_data }

      it 'leaves the payment incomplete' do
        payment = session.settle_payment!(captured: false)

        expect(payment.completed?).to be false
      end

      it 'still records the capture id' do
        payment = session.settle_payment!(captured: false)

        expect(payment.reload.metadata['paypal_capture_id']).to be_present
      end
    end

    # The payment records what PayPal took, so Spree's books match PayPal's
    # whatever the session says.
    context 'when the session amount differs from the amount PayPal captured' do
      let(:external_data) { captured_data.tap { |data| data['purchase_units'][0]['payments']['captures'][0]['amount']['value'] = '7.50' } }

      before { session.update!(amount: cart.total) }

      it 'records the captured amount on the payment' do
        payment = session.settle_payment!(captured: true)

        expect(payment.reload.amount).to eq(BigDecimal('7.50'))
      end

      it 'records the captured amount on a pending payment too' do
        external_data['purchase_units'][0]['payments']['captures'][0]['status'] = 'PENDING'

        expect(session.settle_payment!(captured: false).reload.amount).to eq(BigDecimal('7.50'))
      end
    end

    context 'when the capture carries no amount' do
      let(:external_data) { captured_data.tap { |data| data['purchase_units'][0]['payments']['captures'][0].delete('amount') } }

      it 'records the session amount' do
        expect(session.settle_payment!(captured: true).reload.amount).to eq(session.amount)
      end
    end
  end

  describe '#payment_source_for_settlement' do
    context 'when PayPal reports a payment source the gem does not support' do
      let(:external_data) { captured_data.merge('payment_source' => { 'venmo' => { 'email_address' => 'buyer@example.com' } }) }

      before { allow(Rails.logger).to receive(:warn) }

      it 'returns nil' do
        expect(session.payment_source_for_settlement).to be_nil
      end

      it 'logs the unsupported source type' do
        session.payment_source_for_settlement

        expect(Rails.logger).to have_received(:warn).with(/venmo/)
      end

      it 'does not log the buyer details' do
        session.payment_source_for_settlement

        expect(Rails.logger).not_to have_received(:warn).with(/buyer@example\.com/)
      end
    end
  end

  describe '#prepare_for_settlement!' do
    let(:gateway_order) { double(data: double(as_json: captured_data)) }

    before { allow(session.payment_method).to receive(:fetch_paypal_order).and_return(gateway_order) }

    context 'when the capture is not settled yet' do
      let(:external_data) { created_data }

      it 'fetches the PayPal order once' do
        session.prepare_for_settlement!

        expect(session.payment_method).to have_received(:fetch_paypal_order).with(session.external_id).once
      end

      it 'stores the fetched order in external_data' do
        session.prepare_for_settlement!

        expect(session.external_data).to eq(captured_data)
      end

      it 'persists the fetched order' do
        session.prepare_for_settlement!

        expect(session.reload.external_data).to eq(captured_data)
      end

      it 'returns the session' do
        expect(session.prepare_for_settlement!).to eq(session)
      end

      # The storefront reads these from the session while it is still open.
      context 'when the stored session data carries the storefront keys' do
        let(:external_data) do
          created_data.merge('client_token' => 'test-client-token', 'enable_apple_pay' => true, 'enable_card_fields' => false)
        end

        it 'keeps the storefront keys after fetching' do
          session.prepare_for_settlement!

          expect(session.reload.external_data).to include(
            'client_token' => 'test-client-token', 'enable_apple_pay' => true, 'enable_card_fields' => false
          )
        end

        it 'reads the capture from the fetched order' do
          session.prepare_for_settlement!

          expect(session.reload).to have_attributes(paypal_capture_status: 'COMPLETED', paypal_capture_id: '6F473251BB811841E')
        end

        it 'overwrites the stored order fields with the fetched ones' do
          session.prepare_for_settlement!

          expect(session.reload.external_data).to include('status' => captured_data['status'], 'payer' => captured_data['payer'])
        end
      end
    end

    context 'when the capture is pending' do
      let(:external_data) { pending_data }

      it 'fetches the PayPal order again' do
        session.prepare_for_settlement!

        expect(session.payment_method).to have_received(:fetch_paypal_order).once
      end

      context 'when the order still shows the capture as pending' do
        let(:gateway_order) { double(data: double(as_json: pending_data)) }

        it 'returns the session: a pending capture settles as a pending payment' do
          expect(session.prepare_for_settlement!).to eq(session)
        end
      end
    end

    context 'when the capture is already settled' do
      it 'does not fetch the PayPal order' do
        session.prepare_for_settlement!

        expect(session.payment_method).not_to have_received(:fetch_paypal_order)
      end

      it 'returns the session' do
        expect(session.prepare_for_settlement!).to eq(session)
      end
    end

    # Core settles a webhook as paid whatever the order shows, so a capture that
    # holds no funds must stop here.
    %w[DECLINED FAILED].each do |status|
      context "when the stored capture is already #{status}" do
        let(:external_data) do
          captured_data.tap { |data| data['purchase_units'][0]['payments']['captures'][0]['status'] = status }
        end

        it 'raises without fetching the PayPal order' do
          expect { session.prepare_for_settlement! }.to raise_error(Spree::Core::GatewayError, /#{status}/)

          expect(session.payment_method).not_to have_received(:fetch_paypal_order)
        end
      end

      context "when the fetched capture is #{status}" do
        let(:external_data) { created_data }
        let(:gateway_order) do
          double(data: double(as_json: captured_data.tap { |data| data['purchase_units'][0]['payments']['captures'][0]['status'] = status }))
        end

        it 'raises' do
          expect { session.prepare_for_settlement! }.to raise_error(Spree::Core::GatewayError, /#{status}/)
        end
      end
    end

    context 'when the fetched order has no capture' do
      let(:external_data) { created_data }
      let(:gateway_order) { double(data: double(as_json: created_data)) }

      it 'raises' do
        expect { session.prepare_for_settlement! }.to raise_error(Spree::Core::GatewayError, /no capture/)
      end
    end
  end
end
