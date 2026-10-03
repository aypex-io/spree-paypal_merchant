# frozen_string_literal: true

module Spree
  module PaypalMerchant
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
        base.has_many :paypal_merchant_orders,
                      class_name: 'Spree::PaypalMerchant::Order',
                      dependent: :destroy,
                      foreign_key: :order_id
      end
    end
  end
end

Spree::Order.prepend(Spree::PaypalMerchant::OrderDecorator)
