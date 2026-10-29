# frozen_string_literal: true

require 'faraday'
require 'net/http'

module Spree
  module PaypalMerchant
    ##
    # PayPal Checkout payment method.
    #
    # One method covers the PayPal wallet, Apple Pay, and Card Fields. Extra
    # wallets are recorded as {PaymentSources} on the same gateway rather than
    # as separate payment methods.
    #
    class Gateway < ::Spree::Gateway
      ##
      # PayPal could not be reached, or did not answer in time: the request
      # may or may not have arrived. The SDK's HTTP client raises the Faraday
      # errors; this gateway's own HTTP calls raise the Net ones.
      #
      CONNECTION_ERRORS = [
        Faraday::TimeoutError, Faraday::ConnectionFailed,
        Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED
      ].freeze

      ##
      # How many times the SDK repeats a request that PayPal answered with a
      # retryable status (such as 503) or that timed out. The SDK retries
      # only GET and PUT, never POST, so creating, capturing and refunding are
      # never sent twice. The wait between attempts is the SDK's default: 1
      # second, doubling.
      #
      MAX_RETRIES = 3

      ##
      # Seconds the SDK allows each attempt to open, send and read. It bounds a
      # hanging PayPal to about one old 60 second wait across the GET retries;
      # a capture that exceeds it is an ambiguous outcome that leaves the
      # session retryable.
      #
      REQUEST_TIMEOUT = 15

      ##
      # The statuses of a refund PayPal accepted but did not make. A PENDING
      # refund is on its way to the buyer, and is recorded.
      #
      FAILED_REFUND_STATUSES = %w[FAILED CANCELLED].freeze

      include PaymentSessions

      ##
      # Refunds arrive as a Spree::Money rather than hundredths, which is wrong
      # for a currency without two decimals and goes in Spree 6.1.
      #
      self.accepts_money_amounts = true

      preference :client_id, :string
      preference :client_secret, :password
      preference :webhook_secret, :string
      preference :test_mode, :boolean, default: true
      preference :enable_apple_pay, :boolean, default: true
      preference :enable_card_fields, :boolean, default: true

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
        'spree_paypal_merchant'
      end

      ##
      # @return [String]
      #
      def payment_icon_name
        'paypal'
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
      # Whether the storefront should offer Card Fields for this method.
      #
      # @return [TrueClass, FalseClass]
      #
      def card_fields_enabled?
        preferred_enable_card_fields
      end

      ##
      # @return [String, NilClass]
      #
      def webhook_url
        return nil unless store

        "#{store.url_or_custom_domain}/api/v3/webhooks/payments/#{prefixed_id}"
      end

      ##
      # Persist a gateway-customer profile for a signed-in buyer. Guests (an
      # owner with no customer) get none.
      #
      # @param payment [Spree::Payment] owned by a cart or an order
      # @return [Spree::GatewayCustomer, NilClass]
      #
      def create_profile(payment)
        customer = payment.owner&.customer
        return if customer.blank?
        return if payment.source.blank?
        return unless payment.source.is_a?(PaymentSources::Paypal)

        paypal_account_id = payment.source.account_id
        return if paypal_account_id.blank?

        payment.payment_method.gateway_customers.find_or_create_by(customer: customer, profile_id: paypal_account_id)
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
          timeout: REQUEST_TIMEOUT,
          max_retries: MAX_RETRIES,
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
      # PayPal payments are captured at checkout, so there is never an
      # authorization to void: a payment that holds money is refunded instead.
      #
      # This fails for every payment, including one PayPal is still processing
      # (a pending capture). Voiding that in Spree would leave the money
      # captured, with no payment to refund, if PayPal then completes it. The
      # message differs for that payment, telling the merchant to wait for it.
      # Spree passes the payment's prefixed id in the options, which is how
      # the gateway finds the payment.
      #
      # @param _response_code [String]
      # @param _source [Object]
      # @param options [Hash] Spree's gateway options for the payment
      # @return [Spree::PaymentResponse] always a failure
      #
      def void(_response_code, _source = nil, options = {})
        if payment_still_processing?(options)
          failure('PayPal is still processing this payment; refund it once PayPal completes it.')
        else
          failure('PayPal payments are captured at checkout; refund the payment instead.')
        end
      end

      ##
      # Refund a captured PayPal payment.
      #
      # A refusal, or an accepted request whose refund is FAILED or CANCELLED,
      # fails with PayPal's reason. A refund PayPal never confirmed,
      # because it answered with a server error or the request timed out,
      # fails with a message to check PayPal first: PayPal may have issued it,
      # and issuing it again would pay the buyer twice. The refund request is
      # sent once; the SDK never resends a POST.
      #
      # It returns a failure rather than raising. Spree::Refund raises a
      # GatewayError with the failure's message, which the refund workflow
      # reports and uses to discard the unrecorded refund; a
      # Spree::PaymentConnectionError would be replaced by a generic message.
      #
      # @param money [Spree::Money] the amount to refund
      # @param _source [Object]
      # @param response_code [String] the PayPal capture id, for a payment
      #   taken on 5.x; otherwise the capture id is on the payment's metadata
      # @param options [Hash] +:originator+ is the Spree::Refund
      # @return [Spree::PaymentResponse]
      #
      def credit(money, _source, response_code, options = {})
        response = client.payments.refund_captured_payment(
          'capture_id' => capture_id_for(response_code, options[:originator]),
          'amount' => {
            'value' => Spree::Money::Rounding.format(money.to_d, money.currency),
            'currency_code' => money.currency.iso_code
          }
        )

        refund = response.data
        return failure("PayPal did not issue the refund (status #{refund.status}).") if FAILED_REFUND_STATUSES.include?(refund.status.to_s)

        success(refund.id, refund.as_json)
      rescue PaypalServerSdk::APIException => e
        if paypal_refusal?(e)
          failure("PayPal declined the refund: #{paypal_error_text(e)}")
        else
          unconfirmed_refund("PayPal answered #{e.response_code}")
        end
      rescue *CONNECTION_ERRORS
        unconfirmed_refund('the connection to PayPal failed or timed out')
      end

      ##
      # Settle a payment for a canceled order: refund it if PayPal took the
      # money, unless told to keep it.
      #
      # The refund goes through Spree's refund workflow, which records it and
      # calls {#credit}. The payment has nothing to void at PayPal, and the
      # response carries no authorization, so Spree keeps the payment's
      # response code, the PayPal order id.
      #
      # @param _response_code [String]
      # @param payment [Spree::Payment, NilClass]
      # @param refund [TrueClass, FalseClass] whether captured money may be
      #   returned
      # @return [Spree::PaymentResponse]
      # @raise [Spree::Core::GatewayError] when the refund fails
      #
      def cancel(_response_code, payment = nil, refund: true)
        refund_in_full(payment) if refund && payment&.completed? && !payment.credit_allowed.zero?

        success(nil, {})
      end

      protected

      def public_preference_keys
        %i[enable_apple_pay enable_card_fields]
      end

      private

      # Turns a PayPal failure into the GatewayError Spree reports to the buyer.
      # Used by session creation; refunds report failures as responses instead.
      def protect_from_error
        yield
      rescue PaypalServerSdk::APIException => e
        raise Spree::Core::GatewayError, "PayPal API error: #{e.message}"
      rescue *CONNECTION_ERRORS => e
        raise Spree::Core::GatewayError, "PayPal connection error: #{e.message}"
      end

      # Whether Spree's void is for a payment of this gateway that is not
      # finished: PayPal may still complete it.
      def payment_still_processing?(options)
        prefixed_id = options.to_h[:payment_prefixed_id]
        return false if prefixed_id.blank?

        payment = Spree::Payment.where(payment_method_id: id).find_by_prefix_id(prefixed_id) # rubocop:disable Rails/DynamicFindBy
        payment.present? && (payment.pending? || payment.processing?)
      end

      def refund_in_full(payment)
        result = Spree.refund_create_workflow.call(
          payment: payment,
          reason: Spree::RefundReason.order_canceled_reason(payment.owner.store),
          refunder: payment.order&.canceler
        )

        raise Spree::Core::GatewayError, result.error.to_s if result.failure?
      end

      # The capture to refund: recorded on the payment at settlement, or for a
      # payment taken on 5.x, the response code.
      def capture_id_for(response_code, refund)
        recorded = refund.respond_to?(:payment) ? refund.payment&.metadata&.dig('paypal_capture_id') : nil
        recorded.presence || response_code
      end

      def paypal_error_text(error)
        details = error.respond_to?(:details) && error.details.is_a?(Array) ? error.details.filter_map { |detail| detail.try(:description) } : []

        [error.message, *details].map(&:to_s).compact_blank.uniq.join(' ')
      end

      def unconfirmed_refund(reason)
        failure("PayPal did not confirm the refund (#{reason}), so it may still have been issued. " \
                'Check the payment in PayPal before retrying.')
      end

      def success(authorization, response)
        Spree::PaymentResponse.new(true, 'Transaction successful', response, authorization: authorization)
      end

      def failure(message, response = {})
        Spree::PaymentResponse.new(false, message, response)
      end
    end
  end
end
