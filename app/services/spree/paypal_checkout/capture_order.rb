# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Captures a legacy {Order} via the PayPal Orders API and completes
    # the Spree checkout.
    #
    class CaptureOrder
      ##
      # @param paypal_order [Spree::PaypalCheckout::Order]
      #
      def initialize(paypal_order:)
        @paypal_order = paypal_order
        @order = paypal_order.order
        @gateway = paypal_order.gateway
        @amount = paypal_order.amount
      end

      attr_reader :paypal_order, :order, :gateway, :amount

      ##
      # @return [Spree::PaypalCheckout::Order]
      #
      def call
        return paypal_order if order.completed? || order.canceled?

        gateway_response = gateway.capture(
          (amount.to_d * 100).to_i,
          paypal_order.paypal_id,
          { order_id: order.number }
        )

        order.with_lock do
          paypal_order.update!(data: gateway_response.params)
          paypal_order.create_payment!
          Spree::Dependencies.checkout_complete_service.constantize.call(order: order)
        end

        paypal_order
      end
    end
  end
end
