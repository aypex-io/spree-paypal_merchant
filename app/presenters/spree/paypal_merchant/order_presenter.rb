# frozen_string_literal: true

require 'paypal_server_sdk'

module Spree
  module PaypalMerchant
    ##
    # Builds a PayPal Orders API create-order payload from a Spree cart or
    # order.
    #
    # The storefront owns the address: we send `purchase_units[].shipping`
    # from `owner.ship_address` and pin it with `SET_PROVIDED_ADDRESS` so
    # PayPal does not re-collect it. The amount breakdown sends only
    # `additional_tax_total` — sending full `tax_total` double-counts
    # included VAT and trips PayPal `AMOUNT_MISMATCH`.
    #
    # Every amount is written the way PayPal reads it: exactly the currency's
    # decimal places (`Spree::Money::Rounding.format`), so a yen amount has
    # none and a dinar amount has three.
    #
    class OrderPresenter
      PAYPAL_ITEM_NAME_MAX_LENGTH = 127

      ##
      # @param owner [Spree::Cart, Spree::Order] a cart during checkout, an order
      #   after it
      # @param amount [Numeric, NilClass] what PayPal should charge; defaults to
      #   the owner's total. Less than the total when a gift card or store credit
      #   pays part of it.
      #
      def initialize(owner, amount: nil)
        @owner = owner
        @amount = amount
      end

      attr_reader :owner

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
        # A gift card or store credit pays part of the order, so the breakdown
        # and items (which always sum to the full total) can't describe what
        # PayPal charges. PayPal accepts an amount on its own.
        args =
          if partial_charge?
            { amount: PaypalServerSdk::AmountWithBreakdown.new(currency_code: currency_code,
                                                               value: format_amount(charge_amount)) }
          else
            { amount: amount_with_breakdown, items: items }
          end
        args[:shipping] = shipping_details if shipping_details

        PaypalServerSdk::PurchaseUnitRequest.new(**args)
      end

      def currency_code
        owner.currency.upcase
      end

      def charge_amount
        @amount.presence || owner.total
      end

      def partial_charge?
        charge_amount.to_d != owner.total.to_d
      end

      # NOTE: the breakdown only sends additional (non-included) tax — sending
      # the full tax_total double-counts VAT on tax-inclusive markets and
      # trips AMOUNT_MISMATCH. Do not change to owner.tax_total.
      #
      # item_total + shipping + handling + tax_total - discount adds up to the
      # total, which PayPal checks to the minor unit.
      def amount_with_breakdown
        PaypalServerSdk::AmountWithBreakdown.new(
          currency_code: currency_code,
          value: format_amount(owner.total),
          breakdown: PaypalServerSdk::AmountBreakdown.new(
            item_total: paypal_money(owner.item_total),
            shipping: paypal_money(owner.delivery_total),
            handling: handling,
            tax_total: paypal_money(owner.additional_tax_total),
            discount: paypal_money(owner.discount_total&.abs)
          )
        )
      end

      # Fees (a handling or payment charge, say) are PayPal's `handling`. Left
      # out when there are none, so an ordinary payload has no empty line.
      def handling
        fees = paypal_money(owner.fee_total)
        fees unless fees.value.to_d.zero?
      end

      # An amount the way PayPal reads it: exactly the currency's decimal places.
      def format_amount(amount)
        Spree::Money::Rounding.format(amount, currency_code)
      end

      # A total a record has not set (nullable on orders) is nothing owed.
      def paypal_money(amount)
        PaypalServerSdk::Money.new(
          currency_code: currency_code,
          value: format_amount(amount || 0)
        )
      end

      # PayPal rejects an order whose items don't add up to the breakdown's
      # item total, so with items that can't, none are sent: the amount and
      # breakdown still describe the payment. They fail to add up when a unit
      # price has more decimals than the currency (3 x 1.2345 is sent as
      # 3 x 1.23, against a line total of 3.70).
      def items
        paypal_items = owner.line_items.map do |line_item|
          PaypalServerSdk::Item.new(
            name: line_item.name.to_s[0...PAYPAL_ITEM_NAME_MAX_LENGTH],
            unit_amount: paypal_money(line_item.price),
            quantity: line_item.quantity.to_s,
            sku: line_item.sku,
            category: line_item.variant.digital? ? PaypalServerSdk::ItemCategory::DIGITAL_GOODS : PaypalServerSdk::ItemCategory::PHYSICAL_GOODS
          )
        end

        paypal_items if items_add_up?(paypal_items)
      end

      def items_add_up?(paypal_items)
        paypal_items.sum { |item| item.unit_amount.value.to_d * item.quantity.to_i } == paypal_money(owner.item_total).value.to_d
      end

      def shipping_details
        address = owner.ship_address
        return nil if address.blank?

        PaypalServerSdk::ShippingDetails.new(
          name: PaypalServerSdk::ShippingName.new(full_name: address.full_name),
          address: PaypalServerSdk::Address.new(
            country_code: address.country_code,
            address_line_1: address.address1,
            address_line_2: address.address2.presence,
            admin_area_2: address.city,
            admin_area_1: region_code(address),
            postal_code: address.postal_code
          )
        )
      end

      def region_code(address)
        address.state_code.presence || address.state_name.presence
      end

      def payment_source
        PaypalServerSdk::PaymentSource.new(
          paypal: PaypalServerSdk::PaypalWallet.new(
            experience_context: PaypalServerSdk::PaypalWalletExperienceContext.new(
              brand_name: owner.store&.name,
              shipping_preference: shipping_preference,
              user_action: PaypalServerSdk::PaypalExperienceUserAction::PAY_NOW
            )
          )
        )
      end

      def shipping_preference
        if owner.ship_address.present?
          PaypalServerSdk::PaypalWalletContextShippingPreference::SET_PROVIDED_ADDRESS
        else
          PaypalServerSdk::PaypalWalletContextShippingPreference::NO_SHIPPING
        end
      end
    end
  end
end
