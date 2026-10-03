# frozen_string_literal: true

class CreateSpreePaypalMerchantOrders < ActiveRecord::Migration[7.2]
  def up
    # A host upgrading from spree-paypal_platform already has the table under
    # its old name; RenameSpreePaypalPlatformToPaypalMerchant moves it.
    return if table_exists?(:spree_paypal_platform_orders) || table_exists?(:spree_paypal_merchant_orders)

    create_table :spree_paypal_merchant_orders do |t|
      t.references :order, null: false
      t.references :payment_method, null: false
      t.string :paypal_id, null: false
      t.decimal :amount, null: false, precision: 10, scale: 2

      if t.respond_to? :jsonb
        t.jsonb :data
      else
        t.json :data
      end

      t.timestamps
    end

    add_index :spree_paypal_merchant_orders, %i[order_id paypal_id], unique: true
    add_index :spree_paypal_merchant_orders, :paypal_id, unique: true
  end

  def down
    drop_table :spree_paypal_merchant_orders, if_exists: true
  end
end
