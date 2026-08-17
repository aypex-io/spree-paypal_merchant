# frozen_string_literal: true

module Spree
  class PaymentSessions::PaypalPlatform < PaymentSession
    ##
    # @return [String]
    #
    def paypal_order_id
      external_id
    end

    ##
    # @return [String, NilClass]
    #
    def paypal_capture_id
      external_data&.dig('purchase_units', 0, 'payments', 'captures', 0, 'id')
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
    # Creates or finds the Spree::Payment for this session.
    #
    # Defers creation until paypal_capture_id is present so response_code
    # is always the capture ID (required for refunds via Gateway#credit).
    #
    # @param metadata [Hash]
    # @return [Spree::Payment, NilClass]
    #
    def find_or_create_payment!(metadata = {})
      return unless persisted?
      return payment if payment.present?
      return unless paypal_capture_id

      order.with_lock do
        existing_payment = order.payments.where(
          payment_method: payment_method,
          response_code: paypal_capture_id
        ).first

        return existing_payment if existing_payment.present?

        source = create_payment_source!

        order.payments.create!(
          payment_method: payment_method,
          amount: amount,
          response_code: paypal_capture_id,
          source: source,
          skip_source_requirement: true,
          private_metadata: metadata
        )
      end
    end

    private

    def create_payment_source!
      return nil if paypal_payment_source.blank?

      Spree::PaypalPlatform::CreateSource.new(
        paypal_payment_source: paypal_payment_source,
        gateway: payment_method,
        order: order
      ).call
    end
  end
end
