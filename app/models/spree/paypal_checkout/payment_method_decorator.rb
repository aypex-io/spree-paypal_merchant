# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Adds a paypal_checkout scope and predicate onto {Spree::PaymentMethod}.
    #
    module PaymentMethodDecorator
      ##
      # @param base [Class]
      # @return [void]
      #
      def self.prepended(base)
        base.scope :paypal_checkout, lambda {
          where(type: Spree::PaypalCheckout.gateway_type_names)
        }
      end

      ##
      # @return [TrueClass, FalseClass]
      #
      def paypal_checkout?
        Spree::PaypalCheckout.gateway_type_names.include?(type)
      end
    end
  end
end

Spree::PaymentMethod.prepend(Spree::PaypalCheckout::PaymentMethodDecorator)
