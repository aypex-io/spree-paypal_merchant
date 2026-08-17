# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Adds the legacy PayPal-order association onto {Spree::Order}.
    #
    module OrderDecorator
      ##
      # @param base [Class]
      # @return [void]
      #
      def self.prepended(base)
        base.store_accessor :private_metadata, :paypal_id
        base.has_many :paypal_checkout_orders,
                      class_name: 'Spree::PaypalCheckout::Order',
                      dependent: :destroy,
                      foreign_key: :order_id
      end
    end
  end
end

Spree::Order.prepend(Spree::PaypalCheckout::OrderDecorator)
