# frozen_string_literal: true

class RenamePaypalCheckoutOrdersToPaypalPlatform < ActiveRecord::Migration[7.2]
  LEGACY_TO_CURRENT = {
    'SpreePaypalCheckout::Gateway' => 'Spree::PaypalPlatform::Gateway',
    'SpreePaypalCheckout::PaymentSources::Paypal' => 'Spree::PaypalPlatform::PaymentSources::Paypal',
    'SpreePaypalCheckout::Order' => 'Spree::PaypalPlatform::Order',
    'Spree::PaypalCheckout::Gateway' => 'Spree::PaypalPlatform::Gateway',
    'Spree::PaypalCheckout::PaymentSources::Paypal' => 'Spree::PaypalPlatform::PaymentSources::Paypal',
    'Spree::PaypalCheckout::PaymentSources::ApplePay' => 'Spree::PaypalPlatform::PaymentSources::ApplePay',
    'Spree::PaypalCheckout::PaymentSources::Card' => 'Spree::PaypalPlatform::PaymentSources::Card',
    'Spree::PaypalCheckout::Order' => 'Spree::PaypalPlatform::Order'
  }.freeze

  def up
    if table_exists?(:spree_paypal_checkout_orders) && !table_exists?(:spree_paypal_platform_orders)
      rename_table :spree_paypal_checkout_orders, :spree_paypal_platform_orders
    end

    rewrite_column(:spree_payment_methods, :type)
    rewrite_column(:spree_payment_sources, :type) if column_exists?(:spree_payment_sources, :type)
  end

  def down
    if table_exists?(:spree_paypal_platform_orders) && !table_exists?(:spree_paypal_checkout_orders)
      rename_table :spree_paypal_platform_orders, :spree_paypal_checkout_orders
    end

    rewrite_column(:spree_payment_methods, :type, invert_mapping)
    rewrite_column(:spree_payment_sources, :type, invert_mapping) if column_exists?(:spree_payment_sources, :type)
  end

  private

  def invert_mapping
    {
      'Spree::PaypalPlatform::Gateway' => 'SpreePaypalCheckout::Gateway',
      'Spree::PaypalPlatform::PaymentSources::Paypal' => 'SpreePaypalCheckout::PaymentSources::Paypal',
      'Spree::PaypalPlatform::Order' => 'SpreePaypalCheckout::Order'
    }
  end

  def rewrite_column(table, column, mapping = LEGACY_TO_CURRENT)
    mapping.each do |from, to|
      execute "UPDATE #{table} SET #{column} = #{quote(to)} WHERE #{column} = #{quote(from)}"
    end
  end
end
