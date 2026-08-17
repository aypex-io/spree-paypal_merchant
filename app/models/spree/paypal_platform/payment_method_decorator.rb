# frozen_string_literal: true

module Spree
  module PaypalPlatform
    ##
    # Adds a paypal_platform scope and predicate onto {Spree::PaymentMethod}.
    #
    module PaymentMethodDecorator
      ##
      # @param base [Class]
      # @return [void]
      #
      def self.prepended(base)
        base.scope :paypal_platform, lambda {
          where(type: Spree::PaypalPlatform.gateway_type_names)
        }
      end

      ##
      # @return [TrueClass, FalseClass]
      #
      def paypal_platform?
        Spree::PaypalPlatform.gateway_type_names.include?(type)
      end
    end
  end
end

Spree::PaymentMethod.prepend(Spree::PaypalPlatform::PaymentMethodDecorator)
