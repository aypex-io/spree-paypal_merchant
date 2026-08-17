# frozen_string_literal: true

class CreateSpreePaypalPlatformOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :spree_paypal_platform_orders do |t|
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

    add_index :spree_paypal_platform_orders, %i[order_id paypal_id], unique: true
    add_index :spree_paypal_platform_orders, :paypal_id, unique: true
  end
end
