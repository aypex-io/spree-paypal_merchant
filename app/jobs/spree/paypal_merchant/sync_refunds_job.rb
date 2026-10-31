# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Records in Spree the refunds made in PayPal for one payment
    # ({SyncRefunds}). Enqueued when PayPal reports a refund.
    #
    # Runs on the queue Spree's own payment webhook job uses, after the same
    # wait. Tries again a few times while PayPal cannot be read, and while a
    # refund made in Spree waits for PayPal's answer. A payment that is gone
    # is dropped. Anything it gives up on is logged with the rake task that
    # records it by hand.
    #
    class SyncRefundsJob < Spree::BaseJob
      ##
      # How long after PayPal's event the sync runs, as for Spree's own
      # payment webhooks.
      #
      WAIT = 30.seconds

      ##
      # How to record a payment's PayPal refunds by hand.
      #
      BY_HAND = "record them with bin/rails 'spree:paypal_merchant:sync_refunds[<order number>]'"

      queue_as Spree.queues.payment_webhooks

      retry_on SyncRefunds::PaypalUnavailable, wait: :polynomially_longer, attempts: 5

      retry_on SyncRefunds::RefundInProgress, wait: 30.seconds, attempts: 5 do |_job, error|
        Rails.logger.warn("[spree-paypal_merchant] PayPal refunds not synced: #{error.message}. Once it settles, #{BY_HAND}.")
      end

      # PayPal refused to show the payment's order or capture. Asking again
      # changes nothing.
      discard_on Spree::Core::GatewayError do |_job, error|
        Rails.logger.warn("[spree-paypal_merchant] PayPal refunds not synced: #{error.message}. Once resolved, #{BY_HAND}.")
      end

      discard_on ActiveRecord::RecordNotFound

      ##
      # @param payment_id [Integer] a payment of a {Gateway}
      # @return [SyncRefunds::Result]
      #
      def perform(payment_id:)
        payment = Spree::Payment.find(payment_id)
        Spree::Current.store = payment.payment_method.store

        SyncRefunds.new(payment: payment).call
      end
    end
  end
end
