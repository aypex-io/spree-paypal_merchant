# frozen_string_literal: true

module Spree
  module PaypalCheckout
    module PaymentSources
      ##
      # A PayPal wallet account captured as a Spree payment source.
      #
      class Paypal < ::Spree::PaymentSource
        store_accessor :private_metadata, :email, :name, :account_status, :account_id

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
          'PayPal'
        end

        ##
        # Human-readable wallet line for admin and order emails.
        #
        # @return [String]
        #
        def display_payment_info
          ['PayPal', account_id].compact.join(' · ')
        end
      end
    end
  end
end
