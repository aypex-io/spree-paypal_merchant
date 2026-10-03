# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Adds a paypal_merchant scope and predicate onto {Spree::PaymentMethod}.
    #
    module PaymentMethodDecorator
      ##
      # @param base [Class]
      # @return [void]
      #
      def self.prepended(base)
        base.scope :paypal_merchant, lambda {
          where(type: Spree::PaypalMerchant.gateway_type_names)
        }
      end

      ##
      # @return [TrueClass, FalseClass]
      #
      def paypal_merchant?
        Spree::PaypalMerchant.gateway_type_names.include?(type)
      end
    end
  end
end

Spree::PaymentMethod.prepend(Spree::PaypalMerchant::PaymentMethodDecorator)
