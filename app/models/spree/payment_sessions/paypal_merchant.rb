# frozen_string_literal: true

module Spree
  class PaymentSessions::PaypalMerchant < PaymentSession
    ##
    # Capture statuses that will not change again: the funds moved, or they never will.
    # Anything else (PENDING, or no capture yet) still needs to be re-read from PayPal.
    #
    SETTLED_CAPTURE_STATUSES = %w[COMPLETED DECLINED FAILED].freeze

    ##
    # @return [String]
    #
    def paypal_order_id
      external_id
    end

    ##
    # The first capture of the first purchase unit.
    #
    # @return [Hash, NilClass]
    #
    def paypal_capture
      external_data&.dig('purchase_units', 0, 'payments', 'captures', 0)
    end

    ##
    # @return [String, NilClass]
    #
    def paypal_capture_id
      paypal_capture&.dig('id')
    end

    ##
    # @return [String, NilClass]
    #
    def paypal_capture_status
      paypal_capture&.dig('status')
    end

    ##
    # @return [TrueClass, FalseClass]
    #
    def capture_settled?
      SETTLED_CAPTURE_STATUSES.include?(paypal_capture_status)
    end

    ##
    # @return [Hash, NilClass]
    #
    def paypal_payer
      external_data&.dig('payer')
    end

    ##
    # @return [Hash, NilClass]
    #
    def paypal_payment_source
      external_data&.dig('payment_source')
    end

    ##
    # @return [TrueClass, FalseClass]
    #
    def accepted?
      external_data&.dig('status') == 'COMPLETED'
    end

    ##
    # @return [TrueClass, FalseClass]
    #
    def successful?
      accepted?
    end

    ##
    # Reads the PayPal order before settlement, so the settlement lock holds
    # across no PayPal I/O. Skipped once the capture has reached a final status.
    #
    # @return [Spree::PaymentSessions::PaypalMerchant] self
    #
    def prepare_for_settlement!
      return self if capture_settled?

      response = payment_method.fetch_paypal_order(external_id)
      update!(external_data: response.data.as_json)
      self
    end

    ##
    # Builds the wallet, Apple Pay, or card source from the PayPal order.
    # Runs inside the settlement lock, so it reads only what
    # {#prepare_for_settlement!} already stored.
    #
    # @return [Spree::PaymentSource, NilClass]
    #
    def payment_source_for_settlement
      return nil if paypal_payment_source.blank?

      Spree::PaypalMerchant::CreateSource.new(
        paypal_payment_source: paypal_payment_source,
        gateway: payment_method,
        owner: owner
      ).call
    end

    ##
    # Keeps the PayPal capture id on the payment: refunds are issued against
    # the capture, while the payment itself is keyed on the PayPal order id.
    #
    # @param payment [Spree::Payment]
    # @param metadata [Hash]
    # @return [void]
    #
    def apply_settlement_metadata(payment, metadata)
      super
      capture_id = paypal_capture_id
      payment.metadata['paypal_capture_id'] = capture_id if capture_id.present?
    end
  end
end
