# frozen_string_literal: true

module Spree
  module PaypalCheckout
    ##
    # Builds a {PaymentSources} record from a PayPal Orders `payment_source`.
    #
    # PayPal returns one of `paypal`, `apple_pay`, or `card` (Card Fields).
    # Unknown keys raise so a new wallet is not silently dropped.
    #
    class CreateSource
      ##
      # @param paypal_payment_source [Hash]
      # @param gateway [Spree::PaypalCheckout::Gateway]
      # @param order [Spree::Order, NilClass]
      # @param user [Spree::User, NilClass]
      #
      def initialize(paypal_payment_source:, gateway:, order: nil, user: nil)
        @paypal_payment_source = paypal_payment_source.with_indifferent_access
        @gateway = gateway
        @user = user || order&.user
        @order = order
      end

      ##
      # @return [Spree::PaymentSource]
      # @raise [ArgumentError] when the payload has no known wallet key
      #
      def call
        if paypal_payment_source[:paypal].present?
          create_paypal_source
        elsif paypal_payment_source[:apple_pay].present?
          create_apple_pay_source
        elsif paypal_payment_source[:card].present?
          create_card_source
        else
          raise ArgumentError, "Unsupported PayPal payment source: #{paypal_payment_source.keys.join(', ')}"
        end
      end

      private

      attr_reader :gateway, :user, :paypal_payment_source, :order

      def create_paypal_source
        wallet = paypal_payment_source[:paypal]
        source = PaymentSources::Paypal.find_or_initialize_by(
          payment_method: gateway,
          gateway_payment_profile_id: wallet[:account_id]
        )
        source.update!(
          user: user,
          email: wallet[:email_address],
          name: full_name(wallet[:name]),
          account_id: wallet[:account_id],
          account_status: wallet[:account_status]
        )
        source
      end

      def create_apple_pay_source
        wallet = paypal_payment_source[:apple_pay]
        card = wallet[:card] || {}
        profile_id = wallet[:id].presence ||
                     wallet[:token].presence ||
                     ['applepay', card[:brand], card[:last_digits]].compact.join('-')

        source = PaymentSources::ApplePay.find_or_initialize_by(
          payment_method: gateway,
          gateway_payment_profile_id: profile_id
        )
        source.update!(
          user: user,
          name: full_name(wallet[:name]).presence || wallet[:name],
          email: wallet[:email_address],
          card_brand: card[:brand],
          last_digits: card[:last_digits],
          card_type: card[:type]
        )
        source
      end

      def create_card_source
        card = paypal_payment_source[:card]
        profile_id = card[:id].presence || ['card', card[:brand], card[:last_digits]].compact.join('-')

        source = PaymentSources::Card.find_or_initialize_by(
          payment_method: gateway,
          gateway_payment_profile_id: profile_id
        )
        source.update!(
          user: user,
          name: card[:name],
          card_brand: card[:brand],
          last_digits: card[:last_digits],
          card_type: card[:type]
        )
        source
      end

      def full_name(name)
        return name if name.is_a?(String)
        return '' if name.blank?

        "#{name[:given_name]} #{name[:surname]}".strip
      end
    end
  end
end
