# frozen_string_literal: true

module Spree
  module PaypalPlatform
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
        base.has_many :paypal_platform_orders,
                      class_name: 'Spree::PaypalPlatform::Order',
                      dependent: :destroy,
                      foreign_key: :order_id
      end
    end
  end
end

Spree::Order.prepend(Spree::PaypalPlatform::OrderDecorator)
