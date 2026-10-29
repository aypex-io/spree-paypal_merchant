# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::PaymentSources::ApplePay do
  subject(:source) do
    described_class.new(card_brand: 'VISA', last_digits: '4242')
  end

  describe '.display_name' do
    it 'returns Apple Pay' do
      expect(described_class.display_name).to eq('Apple Pay')
    end
  end

  describe '#display_payment_info' do
    it 'includes the brand and last digits' do
      expect(source.display_payment_info).to eq('Apple Pay · Visa · 4242')
    end
  end

  describe '#actions' do
    it 'allows credit and void' do
      expect(source.actions).to eq(%w[credit void])
    end
  end

  describe 'metadata storage' do
    it 'stores its attributes in metadata' do
      payment_method = create(:paypal_merchant_gateway)
      created = described_class.create!(
        payment_method: payment_method,
        gateway_payment_profile_id: 'APPLEPAY-TXN-1',
        card_brand: 'VISA',
        last_digits: '4242',
        card_type: 'CREDIT',
        name: 'Jane Apple',
        email: 'jane@example.com'
      )

      reloaded = described_class.find(created.id)

      expect(reloaded).to have_attributes(
        card_brand: 'VISA',
        last_digits: '4242',
        card_type: 'CREDIT',
        name: 'Jane Apple',
        email: 'jane@example.com'
      )
      expect(reloaded.metadata).to include('card_brand' => 'VISA', 'email' => 'jane@example.com')
    end
  end
end
