# frozen_string_literal: true

module Spree
  module Api
    module V3
      ##
      # Exposes non-secret payment-method preferences to the storefront.
      #
      module PaymentMethodSerializerDecorator
        def self.prepended(base)
          base.attribute :public_preferences, &:public_preferences
        end
      end
    end
  end
end

Spree::Api::V3::PaymentMethodSerializer.prepend(
  Spree::Api::V3::PaymentMethodSerializerDecorator
)
