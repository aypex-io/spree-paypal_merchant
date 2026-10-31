# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Records in Spree the refunds PayPal holds for one of the gateway's
    # payments, such as a refund made in PayPal's dashboard, which never passes
    # through Spree.
    #
    # The refunds are read from PayPal, never from the event that prompted the
    # sync: PayPal's order for the payment lists the refunds of its capture.
    # Each COMPLETED one that no Spree::Refund on the payment holds (by its
    # PayPal refund id, as the refund's transaction id) is recorded the way
    # Spree's refund workflow records a refund, with the PayPal refund id
    # already set, so Spree never asks PayPal to refund it again. Running it
    # again records nothing new.
    #
    # Not recorded, and reported (logged as a warning where it needs a look):
    # - a refund already recorded, including one made in Spree;
    # - a refund PayPal has not completed (PENDING, FAILED, CANCELLED);
    # - a refund in another currency than the payment's;
    # - a refund for more than is left to refund on the payment;
    # - every refund, when the store has no refund reason;
    # - every refund, when the payment is not completed, or covers several
    #   orders.
    #
    class SyncRefunds
      ##
      # A refund made in Spree on the payment has no PayPal refund id yet:
      # Spree has asked PayPal for it and not stored PayPal's answer. The
      # refund PayPal reports may be that one, so nothing is recorded until it
      # settles.
      #
      class RefundInProgress < StandardError; end

      ##
      # PayPal could not be reached, did not answer in time, or answered with
      # an error that can pass. Reading it again later may succeed.
      #
      class PaypalUnavailable < StandardError; end

      ##
      # What a sync did.
      #
      # @!attribute [r] recorded
      #   @return [Array<Spree::Refund>] the refunds recorded, oldest first
      # @!attribute [r] skipped
      #   @return [Array<String>] why each PayPal refund, or the whole
      #     payment, was not recorded
      #
      Result = Data.define(:recorded, :skipped)

      ##
      # The relation a PayPal refund's link to its capture has, and the one a
      # capture's link to its order has.
      #
      UP = 'up'

      ##
      # @param payment [Spree::Payment] a payment of a {Gateway}
      # @raise [ArgumentError] when the payment is not one of a {Gateway}'s
      #
      def initialize(payment:)
        @payment = payment
        @gateway = payment.payment_method
        @skipped = []

        raise ArgumentError, "payment #{payment.number} is not a PayPal payment" unless gateway.is_a?(Gateway)
      end

      ##
      # Reads PayPal, then records what Spree is missing. PayPal is read
      # before the payment is locked, so the lock holds across no PayPal I/O.
      #
      # @return [Result]
      # @raise [RefundInProgress] when a refund made in Spree on the payment
      #   has no PayPal refund id yet
      # @raise [PaypalUnavailable] when PayPal cannot be read for now
      # @raise [Spree::Core::GatewayError] when PayPal refuses to show the
      #   payment's order or capture
      #
      def call
        why_not = why_payment_not_synced
        if why_not
          note(:warn, "PayPal refunds not synced for payment #{payment.number}: #{why_not}")
          return result([])
        end

        paypal_refunds = read_paypal_refunds
        recorded = payment.with_lock { record(paypal_refunds) }
        announce(recorded)

        result(recorded)
      end

      private

      attr_reader :payment, :gateway

      # As Spree's refund workflow: only a completed payment is refunded, and
      # a payment shared by a split checkout needs to be told which order a
      # refund puts right.
      def why_payment_not_synced
        return "it is #{payment.status}, and only a completed payment can be refunded" unless payment.completed?

        'it covers several orders, so the order each refund is for has to be chosen by hand' if payment.grouped?
      end

      # Runs inside the payment's lock, which Spree's refund workflow also
      # takes to create a refund. Two syncs for one payment (two partial
      # refunds reported together) take turns, and the second finds what the
      # first recorded.
      def record(paypal_refunds)
        ensure_no_refund_in_progress!

        unrecorded = paypal_refunds.select { |paypal_refund| unrecorded_and_completed?(paypal_refund) }
        return [] if unrecorded.empty?

        reason = refund_reason
        if reason.nil?
          unrecorded.each { |paypal_refund| skip(paypal_refund, 'the store has no refund reason; add one, then sync again') }
          return []
        end

        unrecorded.filter_map { |paypal_refund| record_refund(paypal_refund, reason) }
      end

      def ensure_no_refund_in_progress!
        return unless payment.refunds.exists?(transaction_id: [nil, ''])

        raise RefundInProgress, "Payment #{payment.number} has a refund made in Spree that PayPal has not confirmed yet"
      end

      def unrecorded_and_completed?(paypal_refund)
        if payment.refunds.exists?(transaction_id: paypal_refund['id'])
          note(:info, "#{describe(paypal_refund)} already recorded on payment #{payment.number}")
          false
        elsif paypal_refund['status'] != 'COMPLETED'
          skip(paypal_refund, "it is #{paypal_refund['status'] || 'without a status'} at PayPal", level: :info)
          false
        else
          true
        end
      end

      # Created as Spree's refund workflow creates a refund (its own order,
      # no refunder, no originator), with the PayPal refund id as the
      # transaction id that the workflow would otherwise get from PayPal.
      def record_refund(paypal_refund, reason)
        amount = paypal_refund.dig('amount', 'value').to_d
        currency = paypal_refund.dig('amount', 'currency_code')
        left = payment.credit_allowed

        return skip(paypal_refund, "the payment is in #{payment.currency}") if currency != payment.currency
        return skip(paypal_refund, 'PayPal shows no amount') unless amount.positive?
        return skip(paypal_refund, "only #{money(left)} is left to refund on the payment") if amount > left

        payment.refunds.create!(
          amount: amount,
          order: payment.order,
          reason: reason,
          transaction_id: paypal_refund['id'],
          metadata: provenance(paypal_refund)
        )
      end

      # What Spree::Refund#perform! and the refund workflow do once PayPal
      # has made a refund: the order's totals are summed again, and the
      # payment announces the refund. The refund's own created event has
      # already updated the order's payment state.
      def announce(recorded)
        return if recorded.empty?

        payment.order&.recalculate_totals!
        recorded.each { payment.publish_event('payment.refunded') }
      end

      # The reason Spree's refund workflow gives a refund named without one
      # ("Return processing"), or else the store's first by name, as Spree's
      # admin API does. Found, never created.
      def refund_reason
        reasons = Spree::RefundReason.where(store: payment.owner&.store || gateway.store)

        reasons.find_by(name: Spree::RefundReason::RETURN_PROCESSING_REASON) || reasons.first
      end

      def provenance(paypal_refund)
        {
          'recorded_from' => 'paypal',
          'paypal_refund_id' => paypal_refund['id'],
          'paypal_capture_id' => capture_id,
          'paypal_create_time' => paypal_refund['create_time']
        }.compact
      end

      # The refunds of the payment's capture, oldest first. PayPal's order
      # lists them by purchase unit; a refund that names no capture is the
      # capture's, as the gem makes one capture per PayPal order.
      def read_paypal_refunds
        paypal_order = gateway.fetch_paypal_order(paypal_order_id).data.as_json

        Array(paypal_order['purchase_units'])
          .flat_map { |purchase_unit| Array(purchase_unit.dig('payments', 'refunds')) }
          .select { |paypal_refund| [nil, capture_id].include?(PaypalMerchant.linked_id(paypal_refund['links'], rel: UP, path: 'v2/payments/captures')) }
          .sort_by { |paypal_refund| paypal_refund['create_time'].to_s }
      rescue PaypalServerSdk::APIException => e
        raise PaypalUnavailable, "PayPal answered #{e.response_code}" unless gateway.paypal_refusal?(e)

        raise Spree::Core::GatewayError, "PayPal refused to show payment #{payment.number} (HTTP #{e.response_code}): #{e.message}"
      rescue *Gateway::UNKNOWN_OUTCOME_ERRORS => e
        raise PaypalUnavailable, "PayPal could not be read: #{e.message}"
      end

      # The capture, as {Gateway#credit} finds it: on the metadata of a
      # payment settled on Spree 6, or the response code of one taken on 5.x.
      def capture_id
        @capture_id ||= payment.metadata['paypal_capture_id'].presence || payment.response_code
      end

      # A payment settled on Spree 6 holds the PayPal order id as its response
      # code. One taken on 5.x holds the capture id there instead, and
      # PayPal's capture names its order.
      def paypal_order_id
        return payment.response_code if payment.metadata['paypal_capture_id'].present?

        paypal_capture = gateway.fetch_paypal_capture(capture_id).data.as_json
        order_id = paypal_capture.dig('supplementary_data', 'related_ids', 'order_id').presence ||
                   PaypalMerchant.linked_id(paypal_capture['links'], rel: UP, path: 'v2/checkout/orders')
        return order_id if order_id.present?

        raise Spree::Core::GatewayError, "PayPal capture #{capture_id} names no PayPal order"
      end

      def skip(paypal_refund, why, level: :warn)
        note(level, "#{describe(paypal_refund)} not recorded on payment #{payment.number}: #{why}")
        nil
      end

      def note(level, message)
        @skipped << message
        Rails.logger.public_send(level, "[spree-paypal_merchant] #{message}")
      end

      def describe(paypal_refund)
        "PayPal refund #{paypal_refund['id']} of #{paypal_refund.dig('amount', 'value')} #{paypal_refund.dig('amount', 'currency_code')}"
      end

      def money(amount)
        "#{Spree::Money::Rounding.format(amount, payment.currency)} #{payment.currency}"
      end

      def result(recorded)
        Result.new(recorded: recorded, skipped: @skipped)
      end
    end
  end
end
