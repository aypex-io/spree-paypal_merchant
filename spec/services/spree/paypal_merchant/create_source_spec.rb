# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::CreateSource do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:user) { create(:user) }
  let(:order) { create(:order_with_line_items, store: store, user: user) }

  describe '#call' do
    context 'with a PayPal wallet source' do
      let(:paypal_payment_source) do
        {
          'paypal' => {
            'email_address' => 'sb-fxqy4743082799@personal.example.com',
            'account_id' => 'RX8ZD67CZ67RU',
            'account_status' => 'VERIFIED',
            'name' => {
              'given_name' => 'John',
              'surname' => 'Doe'
            }
          }
        }
      end

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order).call }

      it 'creates a PayPal payment source' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::Paypal, :count).by(1)
      end

      it 'sets the wallet attributes' do
        expect(subject.email).to eq('sb-fxqy4743082799@personal.example.com')
      end

      it 'reuses the existing source for the same PayPal account' do
        described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order).call
        expect { subject }.not_to change(Spree::PaypalMerchant::PaymentSources::Paypal, :count)
      end

      context 'when a guest later signs in' do
        let(:guest_order) { create(:order_with_line_items, store: store, user: nil) }

        it 'associates the user to the existing source' do
          source = described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: guest_order).call
          expect(source.user).to be_nil

          source = described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order, user: user).call
          expect(source.user).to eq(user)
        end
      end
    end

    context 'with an Apple Pay source' do
      let(:paypal_payment_source) do
        {
          'apple_pay' => {
            'id' => 'APPLEPAY-TXN-1',
            'name' => 'Jane Apple',
            'email_address' => 'jane@example.com',
            'card' => {
              'brand' => 'VISA',
              'last_digits' => '4242',
              'type' => 'CREDIT'
            }
          }
        }
      end

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order).call }

      it 'creates an Apple Pay payment source' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::ApplePay, :count).by(1)
      end

      it 'stores the card brand and last digits' do
        expect(subject.card_brand).to eq('VISA')
      end

      it 'uses the Apple Pay transaction id as the profile id' do
        expect(subject.gateway_payment_profile_id).to eq('APPLEPAY-TXN-1')
      end
    end

    context 'with a Card Fields source' do
      let(:paypal_payment_source) do
        {
          'card' => {
            'id' => 'CARD-1',
            'brand' => 'MASTERCARD',
            'last_digits' => '4444',
            'type' => 'CREDIT',
            'name' => 'Card Holder'
          }
        }
      end

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order).call }

      it 'creates a card payment source' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::Card, :count).by(1)
      end
    end

    context 'with an empty PayPal wallet hash' do
      let(:paypal_payment_source) { { 'paypal' => {} } }

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, order: order).call }

      it 'creates a PayPal payment source instead of raising' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::Paypal, :count).by(1)
      end
    end

    context 'with an unknown wallet' do
      it 'raises ArgumentError' do
        expect do
          described_class.new(
            paypal_payment_source: { 'venmo' => { 'user_name' => 'x' } },
            gateway: gateway,
            order: order
          ).call
        end.to raise_error(ArgumentError, /Unsupported PayPal payment source/)
      end
    end
  end
end
