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

  describe 'metadata storage' do
    it 'stores its attributes in metadata' do
      payment_method = create(:paypal_merchant_gateway)
      created = described_class.create!(
        payment_method: payment_method,
        gateway_payment_profile_id: 'RX8ZD67CZ67RU',
        email: 'buyer@example.com',
        name: 'John Doe',
        account_status: 'VERIFIED',
        account_id: 'RX8ZD67CZ67RU'
      )

      reloaded = described_class.find(created.id)

      expect(reloaded).to have_attributes(
        email: 'buyer@example.com',
        name: 'John Doe',
        account_status: 'VERIFIED',
        account_id: 'RX8ZD67CZ67RU'
      )
      expect(reloaded.metadata).to include('email' => 'buyer@example.com', 'account_id' => 'RX8ZD67CZ67RU')
    end
  end
end
