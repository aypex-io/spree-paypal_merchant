# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Looks up the store's active PayPal Checkout gateway.
    #
    module StoreDecorator
      ##
      # @return [Spree::PaypalMerchant::Gateway, NilClass]
      #
      def paypal_merchant_gateway
        @paypal_merchant_gateway ||= payment_methods.paypal_merchant.active.last
      end
    end
  end
end

Spree::Store.prepend(Spree::PaypalMerchant::StoreDecorator)
