# frozen_string_literal: true

module Spree
  module PaypalPlatform
    ##
    # A persisted PayPal Orders API response, used by the legacy
    # `/api/v2/storefront/paypal_orders` flow.
    #
    # Payment-session hosts do not write this table; they keep the same
    # payload on `Spree::PaymentSession#external_data`.
    #
    class Order < Base
      class NotCapturedError < StandardError; end
      class AlreadyCapturedError < StandardError; end

      belongs_to :order, class_name: 'Spree::Order'
      belongs_to :payment_method, class_name: 'Spree::PaymentMethod'
      alias gateway payment_method

      before_validation :set_amount_from_order, on: :create

      validates :paypal_id, presence: true, uniqueness: true
      validates :data, presence: true
      validates :amount, numericality: { greater_than: 0 }, presence: true

      store_accessor :data, :payer, :purchase_units, :payment_source, :status

      ##
      # Create a Spree::Payment for this captured PayPal order.
      #
      # @return [Spree::Payment]
      # @raise [NotCapturedError] when the PayPal order is not COMPLETED
      #
      def create_payment!
        raise NotCapturedError unless completed?

        CreatePayment.new(
          order: order,
          paypal_order: self,
          gateway: payment_method,
          amount: amount
        ).call
      end

      ##
      # Capture the PayPal order via the Orders API.
      #
      # @return [Spree::PaypalPlatform::Order]
      # @raise [AlreadyCapturedError] when already COMPLETED
      #
      def capture!
        raise AlreadyCapturedError if completed?

        CaptureOrder.new(paypal_order: self).call
      end

      ##
      # Capture ID from the stored payload. Only present after capture.
      #
      # @return [String, NilClass]
      #
      def paypal_payment_id
        @paypal_payment_id ||= data.dig('purchase_units', 0, 'payments', 'captures', 0, 'id')
      end

      ##
      # Fresh PayPal order from the API.
      #
      # @return [PaypalServerSdk::ApiResponse]
      #
      def paypal_order
        @paypal_order ||= gateway.client.orders.get_order({ 'id' => paypal_id })
      end

      ##
      # @return [TrueClass, FalseClass]
      #
      def completed?
        status == 'COMPLETED'
      end

      private

      def set_amount_from_order
        self.amount ||= order&.total
      end
    end
  end
end
