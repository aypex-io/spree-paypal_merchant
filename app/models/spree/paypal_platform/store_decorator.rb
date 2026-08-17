# frozen_string_literal: true

module Spree
  module PaypalPlatform
    ##
    # Looks up the store's active PayPal Checkout gateway.
    #
    module StoreDecorator
      ##
      # @return [Spree::PaypalPlatform::Gateway, NilClass]
      #
      def paypal_platform_gateway
        @paypal_platform_gateway ||= payment_methods.paypal_platform.active.last
      end
    end
  end
end

Spree::Store.prepend(Spree::PaypalPlatform::StoreDecorator)
