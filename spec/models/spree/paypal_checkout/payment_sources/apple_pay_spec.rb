# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalCheckout::PaymentSources::ApplePay do
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
end
