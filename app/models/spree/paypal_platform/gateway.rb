# frozen_string_literal: true

require 'net/http'

module Spree
  module PaypalPlatform
    ##
    # PayPal Checkout payment method.
    #
    # One method covers the PayPal wallet, Apple Pay, and Card Fields. Extra
    # wallets are recorded as {PaymentSources} on the same gateway rather than
    # as separate payment methods.
    #
    class Gateway < ::Spree::Gateway
      include PaymentSessions

      GatewayResponse = Struct.new(:success, :message, :params, :authorization) do
        alias_method :success?, :success
      end

      preference :client_id, :string
      preference :client_secret, :password
      preference :webhook_secret, :string
      preference :test_mode, :boolean, default: true
      preference :enable_apple_pay, :boolean, default: true

      validates :preferred_client_id, :preferred_client_secret, presence: true

      ##
      # @return [Class]
      #
      def provider_class
        self.class
      end

      ##
      # Default source class for admin "previous cards" lookups. Actual
      # captured payments may also be {PaymentSources::ApplePay} or
      # {PaymentSources::Card}.
      #
      # @return [Class]
      #
      def payment_source_class
        PaymentSources::Paypal
      end

      ##
      # @return [TrueClass]
      #
      def payment_profiles_supported?
        true
      end

      ##
      # @return [String]
      #
      def default_name
        'PayPal'
      end

      ##
      # @return [String]
      #
      def method_type
        'spree_paypal_platform'
      end

      ##
      # @return [String]
      #
      def payment_icon_name
        'paypal'
      end

      ##
      # @return [String]
      #
      def description_partial_name
        'spree_paypal_platform'
      end

      ##
      # @return [String]
      #
      def configuration_guide_partial_name
        'spree_paypal_platform'
      end

      ##
      # @return [String]
      #
      def source_partial_name
        'paypal_platform'
      end

      ##
      # Whether the storefront should offer Apple Pay for this method.
      #
      # Domain registration with PayPal is still required; this flag only
      # advertises the capability.
      #
      # @return [TrueClass, FalseClass]
      #
      def apple_pay_enabled?
        preferred_enable_apple_pay
      end

      ##
      # @return [String, NilClass]
      #
      def webhook_url
        return nil unless store

        "#{store.url_or_custom_domain}/api/v3/webhooks/payments/#{prefixed_id}"
      end

      ##
      # Persist a gateway-customer profile for a signed-in buyer.
      #
      # @param payment [Spree::Payment]
      # @return [Spree::GatewayCustomer, NilClass]
      #
      def create_profile(payment)
        user = payment.order.user
        return if user.blank?
        return if payment.source.blank?
        return unless payment.source.is_a?(PaymentSources::Paypal)

        paypal_account_id = payment.source.account_id
        return if paypal_account_id.blank?

        payment.payment_method.gateway_customers.find_or_create_by(user: user, profile_id: paypal_account_id)
      end

      ##
      # @return [PaypalServerSdk::Client]
      #
      def client
        @client ||= PaypalServerSdk::Client.new(
          client_credentials_auth_credentials: PaypalServerSdk::ClientCredentialsAuthCredentials.new(
            o_auth_client_id: preferred_client_id,
            o_auth_client_secret: preferred_client_secret
          ),
          environment: preferred_test_mode ? PaypalServerSdk::Environment::SANDBOX : PaypalServerSdk::Environment::PRODUCTION,
          logging_configuration: PaypalServerSdk::LoggingConfiguration.new(
            log_level: Logger::WARN,
            request_logging_config: PaypalServerSdk::RequestLoggingConfiguration.new(
              log_body: false
            ),
            response_logging_config: PaypalServerSdk::ResponseLoggingConfiguration.new(
              log_headers: false
            )
          )
        )
      end

      ##
      # @raise [NotImplementedError] always — authorize-then-capture is unused
      #
      def authorize(_amount_in_cents, _payment_source, _gateway_options = {})
        raise NotImplementedError, 'PayPal Checkout captures in one step; use #purchase'
      end

      ##
      # Purchase is authorize + capture in one step.
      #
      # @param amount_in_cents [Integer]
      # @param payment_source [#paypal_id]
      # @param gateway_options [Hash]
      # @return [GatewayResponse]
      #
      def purchase(amount_in_cents, payment_source, gateway_options = {})
        capture(amount_in_cents, payment_source.paypal_id, gateway_options)
      end

      ##
      # Capture a previously created PayPal order.
      #
      # @param amount_in_cents [Integer]
      # @param paypal_id [String] PayPal order ID
      # @param gateway_options [Hash]
      # @return [GatewayResponse]
      #
      def capture(_amount_in_cents, paypal_id, gateway_options = {})
        protect_from_error do
          order = find_order(gateway_options[:order_id])
          return failure('Order not found') unless order

          response = client.orders.capture_order({
                                                   'id' => paypal_id,
                                                   'prefer' => 'return=representation'
                                                 })

          if response.data.status == 'COMPLETED'
            success(response.data.id, response.data.as_json)
          else
            failure('Failed to capture PayPal payment', response.data)
          end
        end
      end

      ##
      # Void a PayPal authorization.
      #
      # @param authorization [String]
      # @param _source [Object]
      # @param gateway_options [Hash]
      # @return [GatewayResponse]
      #
      def void(authorization, _source, _gateway_options = {})
        protect_from_error do
          response = client.payments.void_payment({
                                                    'authorization_id' => authorization,
                                                    'prefer' => 'return=representation'
                                                  })

          success(authorization, response.data.as_json)
        end
      end

      ##
      # Refund a captured PayPal payment.
      #
      # @param amount_in_cents [Integer]
      # @param _payment_source [Object]
      # @param paypal_payment_id [String]
      # @param gateway_options [Hash]
      # @return [GatewayResponse]
      #
      def credit(amount_in_cents, _payment_source, paypal_payment_id, gateway_options = {})
        refund_originator = gateway_options[:originator]
        order = refund_originator.respond_to?(:order) ? refund_originator.order : refund_originator

        return failure('Order not found') unless order

        protect_from_error do
          payload = {
            capture_id: paypal_payment_id,
            amount: {
              value: (amount_in_cents / 100.0).to_s,
              currency_code: order.currency.upcase
            }
          }.deep_stringify_keys

          response = client.payments.refund_captured_payment(payload)

          success(response.data.id, response.data.as_json)
        end
      end

      ##
      # Cancel a payment: refund if captured, otherwise void.
      #
      # @param authorization [String]
      # @param payment [Spree::Payment, NilClass]
      # @return [GatewayResponse]
      #
      def cancel(authorization, payment = nil)
        protect_from_error do
          if payment&.completed?
            amount = payment.credit_allowed
            return success(authorization, {}) if amount.zero?

            refund = payment.refunds.create!(
              amount: amount,
              reason: Spree::RefundReason.order_canceled_reason,
              refunder_id: payment.order.canceler_id
            )

            success(payment.response_code, refund.response.params)
          else
            response = client.payments.void_payment({
                                                      'authorization_id' => authorization,
                                                      'prefer' => 'return=representation'
                                                    })

            success(authorization, response.data.as_json)
          end
        end
      end

      private

      def find_order(order_id)
        return nil unless order_id

        order_number, _payment_number = order_id.split('-')
        Spree::Order.find_by(number: order_number)
      end

      def protect_from_error
        yield
      rescue PaypalServerSdk::APIException => e
        raise Spree::Core::GatewayError, "PayPal API error: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
        raise Spree::Core::GatewayError, "PayPal connection error: #{e.message}"
      end

      def success(authorization, response)
        GatewayResponse.new(true, 'Transaction successful', response, authorization)
      end

      def failure(message, response = {})
        GatewayResponse.new(false, message, response, nil)
      end
    end
  end
end
