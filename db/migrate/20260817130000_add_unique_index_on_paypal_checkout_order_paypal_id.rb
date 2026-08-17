# frozen_string_literal: true

class AddUniqueIndexOnPaypalCheckoutOrderPaypalId < ActiveRecord::Migration[7.2]
  def change
    add_index :spree_paypal_checkout_orders, :paypal_id, unique: true
  end
end
