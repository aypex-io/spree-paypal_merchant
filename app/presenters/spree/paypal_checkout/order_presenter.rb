# frozen_string_literal: true

require 'paypal_server_sdk'

module Spree
  module PaypalCheckout
    ##
    # Builds a PayPal Orders API create-order payload from a Spree order.
    #
    # The storefront owns the address: we send `purchase_units[].shipping`
    # from `order.ship_address` and pin it with `SET_PROVIDED_ADDRESS` so
    # PayPal does not re-collect it. The amount breakdown sends only
    # `additional_tax_total` — sending full `tax_total` double-counts
    # included VAT and trips PayPal `AMOUNT_MISMATCH`.
    #
    class OrderPresenter
      PAYPAL_ITEM_NAME_MAX_LENGTH = 127

      ##
      # @param order [Spree::Order]
      #
      def initialize(order)
        @order = order
      end

      attr_reader :order

      ##
      # @return [Hash] body ready for `client.orders.create_order`
      #
      def to_json(*_args)
        {
          'body' => PaypalServerSdk::OrderRequest.new(
            intent: PaypalServerSdk::CheckoutPaymentIntent::CAPTURE,
            purchase_units: [purchase_unit],
            payment_source: payment_source
          )
        }
      end

      private

      def purchase_unit
        args = {
          amount: amount_with_breakdown,
          items: items
        }
        args[:shipping] = shipping_details if shipping_details

        PaypalServerSdk::PurchaseUnitRequest.new(**args)
      end

      # NOTE: the breakdown only sends additional (non-included) tax — sending
      # the full tax_total double-counts VAT on tax-inclusive markets and
      # trips AMOUNT_MISMATCH. Do not change to order.tax_total.
      def amount_with_breakdown
        PaypalServerSdk::AmountWithBreakdown.new(
          currency_code: order.currency.upcase,
          value: order.total.to_s,
          breakdown: PaypalServerSdk::AmountBreakdown.new(
            item_total: paypal_money(order.item_total),
            shipping: paypal_money(order.ship_total),
            tax_total: paypal_money(order.additional_tax_total),
            discount: paypal_money((order.promo_total || 0).abs)
          )
        )
      end

      def paypal_money(amount)
        PaypalServerSdk::Money.new(
          currency_code: order.currency.upcase,
          value: amount.to_s
        )
      end

      def items
        order.line_items.map do |line_item|
          PaypalServerSdk::Item.new(
            name: line_item.name.to_s[0...PAYPAL_ITEM_NAME_MAX_LENGTH],
            unit_amount: paypal_money(line_item.price),
            quantity: line_item.quantity.to_s,
            sku: line_item.sku,
            category: line_item.variant.digital? ? PaypalServerSdk::ItemCategory::DIGITAL_GOODS : PaypalServerSdk::ItemCategory::PHYSICAL_GOODS
          )
        end
      end

      def shipping_details
        address = order.ship_address
        return nil if address.blank?

        PaypalServerSdk::ShippingDetails.new(
          name: PaypalServerSdk::ShippingName.new(full_name: address.full_name),
          address: PaypalServerSdk::Address.new(
            country_code: address.country&.iso,
            address_line_1: address.address1,
            address_line_2: address.address2.presence,
            admin_area_2: address.city,
            admin_area_1: region_code(address),
            postal_code: address.zipcode
          )
        )
      end

      def region_code(address)
        address.state&.abbr.presence || address.state_name.presence
      end

      def payment_source
        PaypalServerSdk::PaymentSource.new(
          paypal: PaypalServerSdk::PaypalWallet.new(
            experience_context: PaypalServerSdk::PaypalWalletExperienceContext.new(
              brand_name: order.store&.name,
              shipping_preference: shipping_preference,
              user_action: PaypalServerSdk::PaypalExperienceUserAction::PAY_NOW
            )
          )
        )
      end

      def shipping_preference
        if order.ship_address.present?
          PaypalServerSdk::PaypalWalletContextShippingPreference::SET_PROVIDED_ADDRESS
        else
          PaypalServerSdk::PaypalWalletContextShippingPreference::NO_SHIPPING
        end
      end
    end
  end
end
