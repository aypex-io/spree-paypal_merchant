# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Writes onto an express session's cart what the buyer gave PayPal, before
    # the PayPal order is captured: the name and address PayPal ships to, as
    # the cart's full shipping and billing address; the buyer's email, when
    # the cart has none; and the delivery the buyer chose in PayPal's popup.
    #
    # Everything is read from PayPal's own order, which the gateway fetched,
    # never from the client. The address is written the way the Store API
    # writes one ({Spree.carts_update_service}), so the cart is priced, taxed
    # and quoted delivery again for it. A new destination puts the delivery
    # back to Spree's default, so the buyer's choice is selected again
    # afterwards, by delivery method: an option's id is its delivery method's
    # prefixed id ({OrderPresenter#shipping_options}), while delivery rates
    # are recreated by every quote. A PayPal order with no options offered no
    # choice, and the cart keeps the delivery Spree selected.
    #
    # The amount is not checked here: the gateway compares PayPal's amount
    # with what the cart now owes before it captures.
    #
    class ApplyExpressDetails
      ##
      # Why the delivery the buyer chose cannot be selected again.
      #
      DELIVERY_UNAVAILABLE_MESSAGE = 'The delivery chosen in PayPal is not available for this address'

      ##
      # @param owner [Spree::Cart] the express session's cart
      # @param paypal_order [Hash] the approved PayPal order, as JSON
      #
      def initialize(owner:, paypal_order:)
        @owner = owner
        @paypal_order = paypal_order
      end

      ##
      # @return [void]
      # @raise [Spree::Core::GatewayError] when Spree refuses the address, or
      #   the delivery chosen in PayPal is not offered for it
      #
      def call
        write_address
        select_chosen_delivery
      end

      private

      attr_reader :owner, :paypal_order

      def write_address
        result = Spree.carts_update_service.call(
          cart: owner,
          params: { email: email, shipping_address: shipping_address, use_shipping: true }
        )
        raise Spree::Core::GatewayError, result.error.to_s if result.failure?
      end

      # PayPal's only when the cart has none: one the buyer gave the store wins.
      def email
        payer['email_address'] if owner.email.blank?
      end

      # A full address (+quick_checkout+ off), so Spree checks every field it
      # requires. A part of the name PayPal's shipping name lacks comes from
      # the payer's name.
      def shipping_address
        address = shipping['address'] || {}
        first_name, last_name = shipping.dig('name', 'full_name').to_s.split(' ', 2)
        phone = payer.dig('phone', 'phone_number', 'national_number')

        attributes = {
          first_name: first_name.presence || payer.dig('name', 'given_name'),
          last_name: last_name.presence || payer.dig('name', 'surname'),
          address1: address['address_line_1'],
          address2: address['address_line_2'],
          city: address['admin_area_2'],
          postal_code: address['postal_code'],
          country_code: address['country_code'],
          state_code: region_code(address['country_code'], address['admin_area_1']),
          state_name: address['admin_area_1'],
          quick_checkout: false
        }
        attributes[:phone] = phone if phone.present?
        attributes
      end

      # PayPal sends a region as a code or a name ("California"). Where the
      # country requires one, it becomes the subdivision's code. The name is
      # sent as well, for a country with no subdivisions; Spree drops it once
      # the address has a code. The same split as Spree's own wallet
      # addresses (SpreeStripe's +patch_wallet_address+).
      #
      # @return [String, NilClass]
      def region_code(country_code, region)
        country = Spree::Country.by_iso(country_code) if country_code.present?
        Spree::IsoData.subdivision_code(country.iso, region) if country&.states_required?
      end

      def select_chosen_delivery
        return if shipping_options.empty?

        owner.reload
        fulfillment = sole_fulfillment
        rate = fulfillment && rate_for_option(fulfillment, chosen_option_id)
        raise Spree::Core::GatewayError, DELIVERY_UNAVAILABLE_MESSAGE if rate.nil?

        fulfillment.selected_delivery_rate_id = rate.id
        owner.recalculate_totals!
      end

      # PayPal's options are one list for the order, so the gem offers them
      # only for a cart with one fulfillment.
      def sole_fulfillment
        fulfillments = owner.fulfillments.to_a
        fulfillments.first if fulfillments.one?
      end

      def rate_for_option(fulfillment, option_id)
        return if option_id.blank?

        fulfillment.delivery_rates.includes(:delivery_method).find { |rate| rate.delivery_method&.prefixed_id == option_id }
      end

      def chosen_option_id
        shipping_options.find { |option| option['selected'] }&.dig('id')
      end

      def shipping_options
        Array(shipping['options'])
      end

      def shipping
        paypal_order.dig('purchase_units', 0, 'shipping') || {}
      end

      def payer
        paypal_order['payer'] || {}
      end
    end
  end
end
