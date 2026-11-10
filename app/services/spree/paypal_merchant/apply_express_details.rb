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
    # choice, and its amount was priced with the cart's own delivery, so that
    # delivery is selected again, where the new address is still offered it.
    # Where it is not, Spree's default stays, and the gateway's amount check
    # decides.
    #
    # The address and the delivery are written together, holding the cart's
    # row lock, or not at all: a refusal rolls the address back, and no other
    # request ever sees PayPal's address with Spree's default delivery. Two
    # confirms of one PayPal order (a double submit, or a retry) take turns,
    # and the second finds the details written and changes nothing.
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
      # Does nothing when the cart already holds the details.
      #
      # @return [void]
      # @raise [Spree::Core::GatewayError] when Spree refuses the address, or
      #   the delivery chosen in PayPal is not offered for it; the cart is
      #   left as it was
      #
      def call
        owner.with_lock do
          next if already_written?

          kept_delivery_method = selected_delivery_method
          write_address
          shipping_options.empty? ? keep_delivery(kept_delivery_method) : select_chosen_delivery
        end
      end

      private

      attr_reader :owner, :paypal_order

      # Whether the cart already holds this PayPal order's details, as a
      # second confirm or a retry finds them: the email, the address (shared
      # by the bill address), and the delivery chosen in PayPal.
      def already_written?
        email.nil? && address_written? && chosen_delivery_selected?
      end

      def address_written?
        address = owner.ship_address
        return false if address.nil? || address.quick_checkout? || owner.bill_address_id != address.id

        address_key(address.attributes.symbolize_keys) == address_key(shipping_address)
      end

      # An address's fields as Spree stores them: the postcode without spaces
      # or dashes, and the region as its code wherever the country has one.
      # The phone counts only when PayPal sends one, as only then is it
      # written.
      def address_key(fields)
        country_code = fields[:country_code].to_s.upcase
        region = fields[:state_code].presence ||
                 Spree::IsoData.subdivision_code(country_code, fields[:state_name]) ||
                 fields[:state_name].presence

        [
          *fields.values_at(:first_name, :last_name, :address1, :address2, :city).map(&:presence),
          Spree::Address.normalize_postal_code(fields[:postal_code]),
          country_code,
          region,
          (fields[:phone].presence if paypal_phone.present?)
        ]
      end

      def chosen_delivery_selected?
        return true if shipping_options.empty?

        delivery_method = sole_fulfillment&.selected_delivery_rate&.delivery_method
        delivery_method.present? && delivery_method.prefixed_id == chosen_option_id
      end

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
        attributes[:phone] = paypal_phone if paypal_phone.present?
        attributes
      end

      def paypal_phone
        payer.dig('phone', 'phone_number', 'national_number')
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

      # The cart's delivery method, read before the address is written.
      def selected_delivery_method
        sole_fulfillment&.selected_delivery_rate&.delivery_method
      end

      def select_chosen_delivery
        raise Spree::Core::GatewayError, DELIVERY_UNAVAILABLE_MESSAGE unless select_delivery(chosen_option_id)
      end

      # PayPal offered no choice: the delivery the cart had before, if the
      # new address is still offered it.
      def keep_delivery(delivery_method)
        select_delivery(delivery_method.prefixed_id) if delivery_method
      end

      # Selects the rate of the delivery method an option names, on the cart
      # as the address left it.
      #
      # @return [Spree::DeliveryRate, NilClass] the rate, or nil when the
      #   method is not offered
      def select_delivery(option_id)
        owner.reload
        fulfillment = sole_fulfillment
        rate = fulfillment && rate_for_option(fulfillment, option_id)
        return if rate.nil?

        fulfillment.selected_delivery_rate_id = rate.id
        owner.recalculate_totals!
        rate
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
