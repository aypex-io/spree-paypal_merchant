# frozen_string_literal: true

require 'spec_helper'
require Spree::PaypalMerchant::Engine.root.join('db/migrate/20250528095719_create_spree_paypal_merchant_orders')
require Spree::PaypalMerchant::Engine.root.join('db/migrate/20261003120000_rename_spree_paypal_platform_to_paypal_merchant')

RSpec.describe RenameSpreePaypalPlatformToPaypalMerchant do
  let(:connection) { ActiveRecord::Base.connection }
  let(:gateway) { create(:paypal_merchant_gateway) }
  let(:order) { create(:order_with_line_items) }

  def migrate(migration, direction)
    ActiveRecord::Migration.suppress_messages { migration.new.migrate(direction) }
  end

  context 'when upgrading from spree-paypal_platform' do
    let!(:paypal_order) { create(:paypal_merchant_order, order: order, payment_method: gateway) }
    let!(:source) { create(:paypal_merchant_payment_source, payment_method: gateway) }
    let!(:session) { create(:paypal_merchant_payment_session, order: order, payment_method: gateway) }

    before do
      # Old class names no longer load, so they can only be written raw.
      # rubocop:disable Rails/SkipsModelValidations
      gateway.update_column(:type, 'Spree::PaypalPlatform::Gateway')
      source.update_column(:type, 'Spree::PaypalPlatform::PaymentSources::Paypal')
      session.update_column(:type, 'Spree::PaymentSessions::PaypalPlatform')
      # rubocop:enable Rails/SkipsModelValidations
      connection.rename_table(:spree_paypal_merchant_orders, :spree_paypal_platform_orders)

      # The host copies both migrations in one go; the create must stand aside.
      migrate(CreateSpreePaypalMerchantOrders, :up)
      migrate(described_class, :up)
    end

    it 'keeps the PayPal order rows' do
      expect(Spree::PaypalMerchant::Order.find(paypal_order.id).paypal_id).to eq(paypal_order.paypal_id)
    end

    it 'drops the old table' do
      expect(connection.table_exists?(:spree_paypal_platform_orders)).to be(false)
    end

    it 'renames the indexes' do
      expect(connection.indexes(:spree_paypal_merchant_orders).map(&:name)).to all(include('paypal_merchant'))
    end

    it 'retypes the gateway' do
      expect(Spree::PaymentMethod.find(gateway.id)).to be_a(Spree::PaypalMerchant::Gateway)
    end

    it 'retypes the payment source' do
      expect(Spree::PaymentSource.find(source.id)).to be_a(Spree::PaypalMerchant::PaymentSources::Paypal)
    end

    it 'retypes the payment session' do
      expect(Spree::PaymentSession.find(session.id)).to be_a(Spree::PaymentSessions::PaypalMerchant)
    end

    it 'restores the old names on rollback' do
      migrate(described_class, :down)

      expect(Spree::PaymentMethod.where(id: gateway.id).pick(:type)).to eq('Spree::PaypalPlatform::Gateway')
    end
  end

  context 'when installed fresh' do
    let!(:paypal_order) { create(:paypal_merchant_order, order: order, payment_method: gateway) }

    before { migrate(described_class, :up) }

    it 'leaves the table alone' do
      expect(Spree::PaypalMerchant::Order.find(paypal_order.id)).to eq(paypal_order)
    end
  end
end
