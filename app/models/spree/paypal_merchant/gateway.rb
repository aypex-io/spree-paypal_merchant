# frozen_string_literal: true

require 'faraday'
require 'net/http'
require 'net/http/persistent'

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
      # errors (a failed TLS handshake is Faraday::SSLError, and its connection
      # pool can pass its own error through); this gateway's own HTTP calls
      # raise the Net ones.
      #
      CONNECTION_ERRORS = [
        Faraday::TimeoutError, Faraday::ConnectionFailed, Faraday::SSLError, Net::HTTP::Persistent::Error,
        Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED
      ].freeze

      ##
      # PayPal answered, but the SDK could not read the answer. For a server
      # error whose body is not JSON (an HTML 502 or 503 page, say), building
      # the SDK's error raises TypeError "Server responded with invalid JSON."
      # instead of an APIException. Like a lost connection, it leaves the
      # outcome unknown: PayPal may have acted. Matches in a rescue clause.
      #
      module UnreadableAnswer
        ##
        # @param error [Exception]
        # @return [TrueClass, FalseClass]
        #
        def self.===(error)
          error.is_a?(TypeError) && error.message.to_s.include?('invalid JSON')
        end
      end

      ##
      # Errors after which a request's outcome is unknown: PayPal was not
      # reached, did not answer in time, or answered unreadably.
      #
      UNKNOWN_OUTCOME_ERRORS = [*CONNECTION_ERRORS, UnreadableAnswer].freeze

      ##
      # How many times the SDK repeats a request that PayPal answered with a
      # retryable status (such as 503) or that timed out. Only GET and PUT are
      # retried (+retry_methods+, set on the client), never POST, so creating,
      # capturing and refunding are never sent twice. The wait between
      # attempts is the SDK's default: 1 second, doubling.
      #
      MAX_RETRIES = 3

      ##
      # The HTTP methods the SDK may repeat. Neither creates, captures nor
      # refunds anything.
      #
      RETRY_METHODS = %i[get put].freeze

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

      ##
      # What a merchant is told when they cancel or void a payment that PayPal
      # may still complete (a pending capture).
      #
      STILL_PROCESSING_MESSAGE = 'PayPal is still processing this payment; refund it once PayPal completes it.'

      ##
      # What a merchant is told when they capture a payment whose PayPal
      # capture is still pending.
      #
      CAPTURE_STILL_PROCESSING_MESSAGE = 'PayPal is still processing this payment; it completes when PayPal completes the capture.'

      ##
      # Why Spree's checkout processing cannot authorize or purchase with this
      # gateway.
      #
      SESSION_ONLY_MESSAGE = 'PayPal payments are taken through a PayPal payment session at checkout; there is nothing to authorize or purchase.'

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
      # PayPal captures at checkout, whatever the store's default. Spree reads
      # this to decide whether a pending payment is captured on dispatch or
      # left for staff to collect, and a PayPal payment is neither: its money
      # moves when PayPal completes the capture. Creating a session still
      # refuses a method whose own capture method is +on_dispatch+ or +manual+.
      #
      # @return [String] always +checkout+
      #
      def resolved_capture_method
        'checkout'
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
          retry_methods: RETRY_METHODS,
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
      # PayPal payments are taken through a payment session, never by Spree's
      # checkout processing, so there is nothing to authorize.
      #
      # Fails rather than raising: Spree claims the payment (processing)
      # before asking, and a raise would leave it there, where void and cancel
      # read it as a payment PayPal may still complete. A failure marks it
      # failed. No PayPal order stands behind it.
      #
      # @return [Spree::PaymentResponse] always a failure
      #
      def authorize(_money, _source, _options = {})
        failure(SESSION_ONLY_MESSAGE)
      end

      ##
      # As {#authorize}: there is nothing to purchase.
      #
      # @return [Spree::PaymentResponse] always a failure
      #
      def purchase(_money, _source, _options = {})
        failure(SESSION_ONLY_MESSAGE)
      end

      ##
      # Spree's Capture action, for a payment a pending PayPal capture left
      # pending. PayPal captured at checkout, so this never captures: it reads
      # the PayPal order and reports what PayPal did.
      #
      # - COMPLETED succeeds, and Spree completes the payment. No
      #   authorization is returned: Spree would write it over the payment's
      #   response code, the PayPal order id that links the payment to its
      #   session. The capture id is already on the payment's metadata.
      # - DECLINED or FAILED fails, and Spree fails the payment: no money moved.
      # - PENDING raises: PayPal is still processing it.
      # - Anything else raises: a capture PayPal refunded or never made, an
      #   amount other than the one PayPal captured (Spree would split the
      #   rest off as a payment PayPal never holds), or no answer PayPal's
      #   order can be read from.
      #
      # Spree claims the payment (processing) before it asks, and keeps that
      # status when the gateway raises, so every raise first puts the payment
      # back to pending. Capture can then be pressed again, and PayPal's
      # COMPLETED event still completes it.
      #
      # @param money [Spree::Money] the amount to capture
      # @param response_code [String] the PayPal order id
      # @param options [Hash] Spree's gateway options for the payment
      # @return [Spree::PaymentResponse]
      # @raise [Spree::Core::GatewayError] unless PayPal's capture is
      #   COMPLETED for the amount, DECLINED or FAILED
      #
      def capture(money, response_code, options = {})
        paypal_capture_outcome(money, response_code)
      rescue Spree::Core::GatewayError
        return_to_pending(options)
        raise
      end

      ##
      # PayPal payments are captured at checkout, so there is never an
      # authorization to void: a payment that holds money is refunded instead.
      #
      # This fails for every payment, including one PayPal may still complete
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
          failure(STILL_PROCESSING_MESSAGE)
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
      # and issuing it again would pay the buyer twice.
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
        return unissued_refund(refund) if FAILED_REFUND_STATUSES.include?(refund.status.to_s)

        success(refund.id, refund.as_json)
      rescue PaypalServerSdk::APIException => e
        if paypal_refusal?(e)
          failure("PayPal declined the refund: #{paypal_error_text(e)}")
        else
          unconfirmed_refund("PayPal answered #{e.response_code}")
        end
      rescue *UNKNOWN_OUTCOME_ERRORS => e
        unconfirmed_refund(unknown_outcome_reason(e))
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
      # A payment PayPal may still complete (checkout, pending or processing)
      # is not settled: Spree would void it, and PayPal could then complete it,
      # leaving captured money against a payment that cannot be refunded. It
      # raises instead, as a failed response would mark the payment failed. A
      # failed, voided or invalid payment holds nothing and succeeds.
      #
      # @param _response_code [String]
      # @param payment [Spree::Payment, NilClass]
      # @param refund [TrueClass, FalseClass] whether captured money may be
      #   returned
      # @return [Spree::PaymentResponse]
      # @raise [Spree::Core::GatewayError] when PayPal may still complete the
      #   payment, or the refund fails
      #
      def cancel(_response_code, payment = nil, refund: true)
        raise Spree::Core::GatewayError, STILL_PROCESSING_MESSAGE if payment&.can_complete?

        refund_in_full(payment) if refund && payment&.completed? && !payment.credit_allowed.zero?

        success(nil, {})
      end

      protected

      def public_preference_keys
        %i[enable_apple_pay enable_card_fields]
      end

      private

      # Turns a PayPal failure into the GatewayError Spree reports to the buyer.
      # Used by session creation and capture; refunds report failures as
      # responses instead.
      def protect_from_error
        yield
      rescue PaypalServerSdk::APIException => e
        raise Spree::Core::GatewayError, "PayPal API error: #{paypal_error_text(e)}"
      rescue *UNKNOWN_OUTCOME_ERRORS => e
        raise Spree::Core::GatewayError, unknown_outcome_message(e)
      end

      # What the buyer or merchant is told when PayPal's answer never came, or
      # could not be read.
      def unknown_outcome_message(error)
        case error
        when UnreadableAnswer then 'PayPal sent an answer that could not be read'
        else "PayPal connection error: #{error.message}"
        end
      end

      # The same, inside a refund's "did not confirm" message.
      def unknown_outcome_reason(error)
        case error
        when UnreadableAnswer then 'PayPal sent an answer that could not be read'
        else 'the connection to PayPal failed or timed out'
        end
      end

      # Reads the PayPal order behind a payment and turns its capture into
      # Spree's answer for {#capture}.
      def paypal_capture_outcome(money, paypal_order_id)
        paypal_capture = protect_from_error do
          payment_session_class.paypal_capture_in(fetch_paypal_order(paypal_order_id).data.as_json)
        end
        status = paypal_capture&.dig('status')

        case status
        when 'COMPLETED' then completed_capture(money, paypal_capture)
        when 'DECLINED', 'FAILED' then failure("PayPal did not take this payment (capture #{status}).")
        when 'PENDING' then raise Spree::Core::GatewayError, CAPTURE_STILL_PROCESSING_MESSAGE
        when nil then raise Spree::Core::GatewayError, 'PayPal shows no capture for this payment; check it in PayPal.'
        else raise Spree::Core::GatewayError, "PayPal shows this payment's capture as #{status}; check it in PayPal."
        end
      end

      def completed_capture(money, paypal_capture)
        captured = paypal_capture.dig('amount', 'value')
        if captured.present? && captured.to_d != money.to_d
          raise Spree::Core::GatewayError,
                "PayPal captured #{captured} #{paypal_capture.dig('amount', 'currency_code')}; capture that amount, the whole payment."
        end

        success(nil, paypal_capture)
      end

      # The payment Spree passed in its gateway options, if it is one of this
      # gateway's. Spree passes the payment's prefixed id for this.
      def own_payment(options)
        prefixed_id = options.to_h[:payment_prefixed_id]
        return if prefixed_id.blank?

        Spree::Payment.where(payment_method_id: id).find_by_prefix_id(prefixed_id) # rubocop:disable Rails/DynamicFindBy
      end

      # Whether Spree's void is for a payment of this gateway that PayPal may
      # still complete: one that is in checkout, pending or processing.
      def payment_still_processing?(options)
        own_payment(options)&.can_complete? || false
      end

      # Puts a payment Spree claimed for capture back to pending, as Spree's
      # claim has no undo when the gateway raises. Only a payment still
      # processing moves, so one a webhook completed meanwhile stays completed.
      def return_to_pending(options)
        payment = own_payment(options)
        return if payment.nil?

        Spree::Payment.where(id: payment.id, status: 'processing')
                      .update_all(status: 'pending', updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
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

      # PayPal's message, and the description of each issue it lists. The
      # SDK's error has a nil message when PayPal's body carries none; with no
      # description either, the HTTP status is all there is.
      def paypal_error_text(error)
        text = [error.message, *paypal_issue_descriptions(error)].map(&:to_s).compact_blank.uniq.join(' ')
        text.presence || "HTTP #{error.response_code}"
      end

      def paypal_issue_descriptions(error)
        details = error.try(:details)
        return [] unless details.is_a?(Array)

        details.filter_map { |detail| detail.try(:description) }
      end

      # The failure for a refund PayPal accepted and reports it did not make.
      # Spree reads params['message'] before the message, so the refund's own
      # JSON is passed for the log with the message set over it.
      def unissued_refund(refund)
        message = "PayPal did not issue the refund (status #{refund.status})."

        failure(message, refund.as_json.merge('message' => message))
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
