# frozen_string_literal: true

module Spree
  class PaymentSessions::PaypalMerchant < PaymentSession
    ##
    # Capture statuses that will not change again: the funds moved, or they never will.
    # Anything else (PENDING, or no capture yet) still needs to be re-read from PayPal.
    #
    SETTLED_CAPTURE_STATUSES = %w[COMPLETED DECLINED FAILED].freeze

    ##
    # Capture statuses where the buyer has paid: the funds moved, or are on their way.
    #
    PAID_CAPTURE_STATUSES = %w[COMPLETED PENDING].freeze

    ##
    # The first capture of the first purchase unit of a PayPal order.
    #
    # @param paypal_order [Hash, NilClass] a PayPal order as JSON
    # @return [Hash, NilClass]
    #
    def self.paypal_capture_in(paypal_order)
      paypal_order&.dig('purchase_units', 0, 'payments', 'captures', 0)
    end

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
      self.class.paypal_capture_in(external_data)
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
    # Whether the funds were captured. Reads the capture, not the order:
    # PayPal can report an order as COMPLETED whose capture was declined.
    #
    # @return [TrueClass, FalseClass]
    #
    def accepted?
      paypal_capture_status == 'COMPLETED'
    end

    ##
    # @return [TrueClass, FalseClass]
    #
    def successful?
      accepted?
    end

    ##
    # Stores a PayPal order read from PayPal on the session. The order's own
    # fields replace the stored ones; the keys the storefront put there
    # (+client_token+, +enable_apple_pay+, +enable_card_fields+) stay, because
    # the session can still be open when it is stored.
    #
    # @param paypal_order [Hash] a PayPal order as JSON
    # @return [void]
    #
    def store_paypal_order!(paypal_order)
      update!(external_data: (external_data || {}).merge(paypal_order))
    end

    ##
    # Reads the PayPal order before settlement, so the settlement lock holds
    # across no PayPal I/O. Skipped once the capture has reached a final status.
    #
    # Only core's webhook workflow calls this. It settles a captured event as
    # paid whatever the order shows, so a capture that holds no funds must stop
    # here: DECLINED, FAILED, or none at all. Nothing is created, and the
    # session stays as it was.
    #
    # @return [Spree::PaymentSessions::PaypalMerchant] self
    # @raise [Spree::Core::GatewayError] unless the capture is COMPLETED or PENDING
    #
    def prepare_for_settlement!
      store_paypal_order!(payment_method.fetch_paypal_order(external_id).data.as_json) unless capture_settled?

      return self if PAID_CAPTURE_STATUSES.include?(paypal_capture_status)

      raise Spree::Core::GatewayError,
            "PayPal order #{external_id} has #{paypal_capture_status ? "a #{paypal_capture_status} capture" : 'no capture'}; nothing to settle"
    end

    ##
    # Builds the wallet, Apple Pay, or card source from the PayPal order.
    # Runs inside the settlement lock, so it reads only what
    # {#prepare_for_settlement!} already stored.
    #
    # A source type the gem does not know is logged and skipped: the funds
    # are already captured, so the payment settles without a source.
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
    rescue ArgumentError
      Rails.logger.warn(
        "[spree-paypal_merchant] unsupported PayPal payment source (#{paypal_payment_source.keys.join(', ')}); " \
        "settling payment session #{id} without a source"
      )
      nil
    end

    ##
    # Keeps the PayPal capture id on the payment: refunds are issued against
    # the capture, while the payment itself is keyed on the PayPal order id.
    #
    # The payment's amount is the amount PayPal captured, not the session's,
    # so Spree records what PayPal took. Reads the capture already stored on
    # the session; no PayPal call.
    #
    # @param payment [Spree::Payment] unsaved
    # @param metadata [Hash]
    # @return [void]
    #
    def apply_settlement_metadata(payment, metadata)
      super
      capture_id = paypal_capture_id
      payment.metadata['paypal_capture_id'] = capture_id if capture_id.present?

      captured_value = paypal_capture&.dig('amount', 'value')
      payment.amount = captured_value.to_d if captured_value.present?
    end
  end
end
