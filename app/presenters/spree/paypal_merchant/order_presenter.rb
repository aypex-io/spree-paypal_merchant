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
    # An express order is the exception: the buyer picks the address and the
    # delivery in PayPal's popup. It asks PayPal to collect the address
    # (`GET_FROM_FILE`), sends none of its own, and offers the cart's delivery
    # rates as PayPal shipping options ({#shipping_options}).
    #
    # Every amount is written the way PayPal reads it: exactly the currency's
    # decimal places (`Spree::Money::Rounding.format`), so a yen amount has
    # none and a dinar amount has three.
    #
    class OrderPresenter
      PAYPAL_ITEM_NAME_MAX_LENGTH = 127
      PAYPAL_SHIPPING_LABEL_MAX_LENGTH = 127
      BREAKDOWN_FIELDS = %i[item_total shipping handling tax_total shipping_discount discount].freeze

      ##
      # @param owner [Spree::Cart, Spree::Order] a cart during checkout, an order
      #   after it
      # @param amount [Numeric, NilClass] what PayPal should charge; defaults to
      #   the owner's total. Less than the total when a gift card or store credit
      #   pays part of it.
      # @param express [Boolean] an express order: the buyer picks the address
      #   and the delivery in PayPal rather than in the storefront
      #
      def initialize(owner, amount: nil, express: false)
        @owner = owner
        @amount = amount
        @express = express
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

      ##
      # What PayPal charges, with the breakdown it checks the charge against
      # when one can be sent (see {#purchase_unit}). An update of an express
      # order's amount sends the same.
      #
      # @return [PaypalServerSdk::AmountWithBreakdown]
      #
      def purchase_amount
        value = format_amount(charge_amount)
        return PaypalServerSdk::AmountWithBreakdown.new(currency_code: currency_code, value: value) if amount_alone?

        PaypalServerSdk::AmountWithBreakdown.new(currency_code: currency_code, value: value, breakdown: breakdown)
      end

      ##
      # The delivery choices an express order offers in PayPal's popup: the
      # rates of the cart's one fulfillment, the selected rate selected. Each
      # is keyed on its delivery method's prefixed id, which outlives the rate:
      # Spree recreates rates whenever it rebuilds the cart's delivery.
      #
      # PayPal checks the selected option against the breakdown's shipping and
      # refuses the order when they differ, so there are none unless the
      # breakdown is sent and the selected rate is what it charges for
      # delivery. There are none either when the cart has no rate selected, or
      # is split across fulfillments (PayPal's options are one list for the
      # order). With none, PayPal offers no choice, and the cart's own delivery
      # is what is charged.
      #
      # @return [Array<PaypalServerSdk::ShippingOption>] always empty unless express
      #
      def shipping_options
        @shipping_options ||= express? ? offered_shipping_options : []
      end

      private

      def express?
        @express == true
      end

      def purchase_unit
        # PayPal accepts an amount on its own. That is all we send when the
        # breakdown and items can't describe the charge: a gift card or store
        # credit pays part of the order (they always sum to the full total), or
        # the breakdown doesn't add up to the amount (PayPal would refuse it).
        # An express order counts the gift card or store credit as a discount
        # instead ({#credit_discount}), so only the second applies to it.
        args = { amount: purchase_amount }
        args[:items] = items unless amount_alone?
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

      def amount_alone?
        (partial_charge? && !express?) || !breakdown_balances?
      end

      # NOTE: the breakdown only sends additional (non-included) tax — sending
      # the full tax_total double-counts VAT on tax-inclusive markets and
      # trips AMOUNT_MISMATCH. Do not change to owner.tax_total.
      def breakdown
        @breakdown ||= PaypalServerSdk::AmountBreakdown.new(
          item_total: paypal_money(owner.item_total),
          shipping: paypal_money(owner.delivery_total),
          handling: handling,
          tax_total: paypal_money(owner.additional_tax_total),
          shipping_discount: shipping_discount,
          discount: paypal_money(line_item_discount_rows_total + credit_discount)
        )
      end

      # PayPal checks item_total + shipping + handling + tax_total -
      # shipping_discount - discount against the amount, to the minor unit, and
      # refuses the order when they differ; it also refuses a negative figure.
      # Spree's own totals add up, so this only fails when a total is out of
      # step with the rest.
      def breakdown_balances?
        return false if BREAKDOWN_FIELDS.any? { |field| breakdown_value(field).negative? }

        charges = %i[item_total shipping handling tax_total].sum { |field| breakdown_value(field) }
        discounts = %i[shipping_discount discount].sum { |field| breakdown_value(field) }
        charges - discounts == format_amount(charge_amount).to_d
      end

      # What a gift card or store credit pays, which an express order counts as
      # a discount so the breakdown adds up to the part PayPal charges: an
      # express order needs its breakdown, which PayPal checks the selected
      # shipping option against. Any other order sends the amount alone instead.
      def credit_discount
        express? ? owner.total.to_d - charge_amount.to_d : 0
      end

      def breakdown_value(field)
        (breakdown.public_send(field)&.value || 0).to_d
      end

      # A free-shipping promotion discounts a delivery, not an item: PayPal's
      # `shipping_discount`. Left out when there is none, like `handling`.
      def shipping_discount
        discount = paypal_money(fulfillment_discount_rows_total)
        discount unless discount.value.to_d.zero?
      end

      # NOTE: these two figures sum the owner's discount rows, promotion and
      # manual alike. Do not change them to owner.discount_total: that counts
      # promotion rows only, while the owner's total takes off every row, so a
      # manual discount would unbalance the breakdown.
      #
      # Discount rows attach to a line item or to a fulfillment. One grouped
      # query reads both sums, once per presenter.
      def line_item_discount_rows_total
        discount_rows_totals.fetch(false, 0).abs
      end

      def fulfillment_discount_rows_total
        discount_rows_totals.fetch(true, 0).abs
      end

      # @return [Hash{Boolean => BigDecimal}] sums keyed on whether the rows
      #   attach to a fulfillment; a key with no rows is absent
      def discount_rows_totals
        @discount_rows_totals ||= owner.discounts.group(Arel.sql('fulfillment_id IS NOT NULL')).sum(:amount)
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
        paypal_items.sum { |item| item.unit_amount.value.to_d * item.quantity.to_i } == breakdown_value(:item_total)
      end

      def shipping_details
        return express_shipping_details if express?

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

      # An express order sends no address (PayPal collects it), only the
      # delivery choices, when there are any.
      def express_shipping_details
        PaypalServerSdk::ShippingDetails.new(options: shipping_options) if shipping_options.any?
      end

      def offered_shipping_options
        return [] unless breakdown_balances?

        rates = delivery_rates
        selected_rate = rates.find(&:selected?)
        return [] unless selected_rate && format_amount(selected_rate.cost).to_d == breakdown_value(:shipping)

        rates.map { |rate| shipping_option(rate, selected: rate.equal?(selected_rate)) }
      end

      # The rates of the owner's fulfillment; none unless it has exactly one.
      def delivery_rates
        fulfillments = owner.fulfillments.to_a
        return [] unless fulfillments.one?

        fulfillments.first.delivery_rates.includes(:delivery_method).to_a
      end

      def shipping_option(rate, selected:)
        PaypalServerSdk::ShippingOption.new(
          id: rate.delivery_method.prefixed_id,
          label: rate.name.to_s[0...PAYPAL_SHIPPING_LABEL_MAX_LENGTH],
          type: PaypalServerSdk::ShippingType::SHIPPING,
          amount: paypal_money(rate.cost),
          selected: selected
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
        if express?
          PaypalServerSdk::PaypalWalletContextShippingPreference::GET_FROM_FILE
        elsif owner.ship_address.present?
          PaypalServerSdk::PaypalWalletContextShippingPreference::SET_PROVIDED_ADDRESS
        else
          PaypalServerSdk::PaypalWalletContextShippingPreference::NO_SHIPPING
        end
      end
    end
  end
end
