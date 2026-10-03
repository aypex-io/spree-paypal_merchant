# frozen_string_literal: true

# Upgrades a host from spree-paypal_platform. Renames the orders table (and
# its default-named indexes) and rewrites stored STI class names, otherwise
# PaymentMethod.all raises SubclassNotFound. A no-op on a fresh install.
class RenameSpreePaypalPlatformToPaypalMerchant < ActiveRecord::Migration[7.2]
  TYPES = {
    spree_payment_methods: {
      'Spree::PaypalPlatform::Gateway' => 'Spree::PaypalMerchant::Gateway'
    },
    spree_payment_sources: {
      'Spree::PaypalPlatform::PaymentSources::Paypal' => 'Spree::PaypalMerchant::PaymentSources::Paypal',
      'Spree::PaypalPlatform::PaymentSources::ApplePay' => 'Spree::PaypalMerchant::PaymentSources::ApplePay',
      'Spree::PaypalPlatform::PaymentSources::Card' => 'Spree::PaypalMerchant::PaymentSources::Card'
    },
    spree_payment_sessions: {
      'Spree::PaymentSessions::PaypalPlatform' => 'Spree::PaymentSessions::PaypalMerchant'
    }
  }.freeze

  def up
    if table_exists?(:spree_paypal_platform_orders) && !table_exists?(:spree_paypal_merchant_orders)
      rename_table :spree_paypal_platform_orders, :spree_paypal_merchant_orders
    end

    TYPES.each { |table, mapping| rewrite(table, mapping) }
  end

  def down
    if table_exists?(:spree_paypal_merchant_orders) && !table_exists?(:spree_paypal_platform_orders)
      rename_table :spree_paypal_merchant_orders, :spree_paypal_platform_orders
    end

    TYPES.each { |table, mapping| rewrite(table, mapping.invert) }
  end

  private

  def rewrite(table, mapping)
    return unless table_exists?(table) && column_exists?(table, :type)

    mapping.each do |from, to|
      execute "UPDATE #{table} SET type = #{quote(to)} WHERE type = #{quote(from)}"
    end
  end
end
