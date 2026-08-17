# frozen_string_literal: true

class RewriteSpreePaypalCheckoutStiTypes < ActiveRecord::Migration[7.2]
  # Hosts coming from the official / forked `spree_paypal_platform` gem store
  # `SpreePaypalCheckout::Gateway` (and `…::PaymentSources::Paypal`) in STI
  # type columns. The new gem aliases those constants, so checkout keeps
  # working before this migration runs; rewriting the strings makes the
  # alias optional for the next deploy.
  LEGACY_TO_CURRENT = {
    'SpreePaypalCheckout::Gateway' => 'Spree::PaypalPlatform::Gateway',
    'SpreePaypalCheckout::PaymentSources::Paypal' => 'Spree::PaypalPlatform::PaymentSources::Paypal',
    'SpreePaypalCheckout::Order' => 'Spree::PaypalPlatform::Order'
  }.freeze

  def up
    rewrite_column(:spree_payment_methods, :type)
    rewrite_column(:spree_payment_sources, :type) if column_exists?(:spree_payment_sources, :type)
  end

  def down
    rewrite_column(:spree_payment_methods, :type, LEGACY_TO_CURRENT.invert)
    rewrite_column(:spree_payment_sources, :type, LEGACY_TO_CURRENT.invert) if column_exists?(:spree_payment_sources, :type)
  end

  private

  def rewrite_column(table, column, mapping = LEGACY_TO_CURRENT)
    mapping.each do |from, to|
      reversible_update = "UPDATE #{table} SET #{column} = #{quote(to)} WHERE #{column} = #{quote(from)}"
      execute reversible_update
    end
  end
end
