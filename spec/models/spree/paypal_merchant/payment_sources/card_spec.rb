# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::PaymentSources::Card do
  subject(:source) { described_class.new(card_brand: 'MASTERCARD', last_digits: '4444') }

  describe '.display_name' do
    it 'returns Card' do
      expect(described_class.display_name).to eq('Card')
    end
  end

  describe '#display_payment_info' do
    it 'includes the brand and last digits' do
      expect(source.display_payment_info).to eq('Mastercard · 4444')
    end
  end

  describe '#actions' do
    it 'allows credit and void' do
      expect(source.actions).to eq(%w[credit void])
    end
  end
end
