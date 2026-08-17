# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Creates the Spree::Payment for a captured legacy PayPal order.
    #
    class CreatePayment
      ##
      # @param paypal_order [Spree::PaypalCheckout::Order]
      # @param order [Spree::Order, NilClass]
      # @param gateway [Spree::PaypalCheckout::Gateway, NilClass]
      # @param amount [Numeric, NilClass]
      #
      def initialize(paypal_order:, order: nil, gateway: nil, amount: nil)
        @paypal_order = paypal_order
        @order = order || paypal_order.order
        @gateway = gateway || paypal_order.gateway
        @amount = amount || paypal_order.amount
      end

      ##
      # @return [Spree::Payment]
      #
      def call
        source = CreateSource.new(
          paypal_payment_source: paypal_order.payment_source,
          gateway: gateway,
          order: order
        ).call

        payment = order.payments.find_or_initialize_by(
          payment_method_id: gateway.id,
          response_code: paypal_order.paypal_payment_id,
          amount: amount
        )

        payment.source = source if source.present?
        payment.state = 'completed'
        payment.save!
        payment
      end

      private

      attr_reader :order, :gateway, :paypal_order, :amount
    end
  end
end
