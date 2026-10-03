# frozen_string_literal: true

module Spree
  module PaypalMerchant
    module PaymentSources
      ##
      # An Advanced Credit and Debit Card (Card Fields) payment.
      #
      class Card < ::Spree::PaymentSource
        store_accessor :private_metadata,
                       :card_brand,
                       :last_digits,
                       :card_type,
                       :name

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
          'Card'
        end

        ##
        # Human-readable card line for admin and order emails.
        #
        # @return [String]
        #
        def display_payment_info
          parts = [card_brand.to_s.titleize.presence, last_digits].compact
          parts.join(' · ').presence || 'Card'
        end
      end
    end
  end
end
