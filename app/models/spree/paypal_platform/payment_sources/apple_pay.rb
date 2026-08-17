# frozen_string_literal: true

module Spree
  module PaypalPlatform
    module PaymentSources
      ##
      # An Apple Pay wallet used through PayPal Checkout.
      #
      # PayPal returns `payment_source.apple_pay` on the captured order.
      # The card brand / last digits (when present) are stored so admin
      # can show "Apple Pay · Visa 4242" rather than a bare wallet name.
      #
      class ApplePay < ::Spree::PaymentSource
        store_accessor :private_metadata,
                       :card_brand,
                       :last_digits,
                       :card_type,
                       :name,
                       :email

        ##
        # @return [Array<String>]
        #
        def actions
          %w[credit void]
        end

        ##
        # @return [String]
        #
        def self.display_name
          'Apple Pay'
        end

        ##
        # Human-readable wallet line for admin and order emails.
        #
        # @return [String]
        #
        def display_payment_info
          parts = ['Apple Pay']
          parts << card_brand.to_s.titleize if card_brand.present?
          parts << last_digits if last_digits.present?
          parts.join(' · ')
        end
      end
    end
  end
end
