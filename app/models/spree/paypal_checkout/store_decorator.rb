# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Looks up the store's active PayPal Checkout gateway.
    #
    module StoreDecorator
      ##
      # @return [Spree::PaypalCheckout::Gateway, NilClass]
      #
      def paypal_checkout_gateway
        @paypal_checkout_gateway ||= payment_methods.paypal_checkout.active.last
      end
    end
  end
end

Spree::Store.prepend(Spree::PaypalCheckout::StoreDecorator)
