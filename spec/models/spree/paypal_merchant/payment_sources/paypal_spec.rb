# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Spree::PaypalMerchant::PaymentSources::Paypal do
  subject(:source) { described_class.new(account_id: 'RX8ZD67CZ67RU', email: 'buyer@example.com') }

  describe '.display_name' do
    it 'returns PayPal' do
      expect(described_class.display_name).to eq('PayPal')
    end
  end

  describe '#display_payment_info' do
    it 'includes the account id' do
      expect(source.display_payment_info).to eq('PayPal · RX8ZD67CZ67RU')
    end
  end

  describe '#actions' do
    it 'allows credit and void' do
      expect(source.actions).to eq(%w[credit void])
    end
  end
end
