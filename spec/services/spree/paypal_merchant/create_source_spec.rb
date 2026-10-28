# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::CreateSource do
  let(:store) { create(:store) }
  let(:gateway) { create(:paypal_merchant_gateway, store: store) }
  let(:user) { create(:user) }
  let(:order) { create(:order_with_line_items, store: store, customer: user) }

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

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order).call }

      it 'creates a PayPal payment source' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::Paypal, :count).by(1)
      end

      it 'sets the wallet attributes' do
        expect(subject.email).to eq('sb-fxqy4743082799@personal.example.com')
      end

      it 'reuses the existing source for the same PayPal account' do
        described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order).call
        expect { subject }.not_to change(Spree::PaypalMerchant::PaymentSources::Paypal, :count)
      end

      context 'when the owner is a cart' do
        let(:customer) { create(:user) }
        let(:cart) { create(:cart, store: store, customer: customer) }

        subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: cart).call }

        it 'assigns the cart\'s customer' do
          expect(subject.customer).to eq(customer)
        end

        context 'with a guest cart' do
          let(:cart) { create(:cart, store: store, customer: nil) }

          it 'builds a source for a guest cart' do
            expect { subject }.not_to raise_error
            expect(subject.customer).to be_nil
          end

          it 'keys the fallback profile id on the cart when PayPal sends no account id' do
            source = described_class.new(
              paypal_payment_source: { 'paypal' => {} }, gateway: gateway, owner: cart
            ).call

            expect(source.gateway_payment_profile_id).to eq("paypal-#{cart.prefixed_id}")
          end
        end
      end

      context 'without an owner' do
        it 'falls back to a guest profile id' do
          source = described_class.new(paypal_payment_source: { 'paypal' => {} }, gateway: gateway).call

          expect(source.gateway_payment_profile_id).to eq('paypal-guest')
        end
      end

      context 'when a guest later signs in' do
        let(:guest_order) { create(:order_with_line_items, store: store, customer: nil) }

        it 'associates the customer to the existing source' do
          source = described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: guest_order).call
          expect(source.customer).to be_nil

          source = described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order, customer: user).call
          expect(source.customer).to eq(user)
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

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order).call }

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

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order).call }

      it 'creates a card payment source' do
        expect { subject }.to change(Spree::PaypalMerchant::PaymentSources::Card, :count).by(1)
      end
    end

    context 'with an empty PayPal wallet hash' do
      let(:paypal_payment_source) { { 'paypal' => {} } }

      subject { described_class.new(paypal_payment_source: paypal_payment_source, gateway: gateway, owner: order).call }

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
            owner: order
          ).call
        end.to raise_error(ArgumentError, /Unsupported PayPal payment source/)
      end
    end
  end
end
