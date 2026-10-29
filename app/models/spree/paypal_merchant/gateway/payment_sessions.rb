# frozen_string_literal: true

require 'net/http'

module Spree
  module PaypalMerchant
    class Gateway < ::Spree::Gateway
      ##
      # Payment-session lifecycle used by Spree 6 storefronts. Sessions belong
      # to a cart during checkout, and settle through Spree's shared
      # settlement path ({Spree::PaymentSession#settle_payment!}).
      #
      module PaymentSessions
        extend ActiveSupport::Concern

        ##
        # Client-error statuses PayPal can send whether or not it acted on the
        # request: rejected credentials, a request timeout, a rate limit.
        #
        AMBIGUOUS_CLIENT_ERROR_STATUSES = [401, 408, 429].freeze

        ##
        # The webhook events the gem settles, and the action Spree 6 takes for
        # each. Anything else, such as CHECKOUT.ORDER.APPROVED, is ignored: an
        # approved order holds no capture, so settling it would complete the
        # session with no payment.
        #
        # A pending capture settles as a payment that is not completed yet; the
        # COMPLETED event then completes that same payment.
        #
        WEBHOOK_ACTIONS = {
          'PAYMENT.CAPTURE.COMPLETED' => :captured,
          'PAYMENT.CAPTURE.PENDING' => :authorized,
          'PAYMENT.CAPTURE.DENIED' => :failed,
          'PAYMENT.CAPTURE.DECLINED' => :failed,
          'PAYMENT.CAPTURE.REVERSED' => :canceled,
          'PAYMENT.CAPTURE.REFUNDED' => :canceled
        }.freeze

        ##
        # @return [TrueClass, FalseClass]
        #
        def session_required?
          true
        end

        ##
        # @return [Class]
        #
        def payment_session_class
          Spree::PaymentSessions::PaypalMerchant
        end

        ##
        # Creates a PayPal order and persists a payment session for it.
        #
        # The owner's earlier PayPal sessions are canceled first, so a stale
        # tab cannot pay for the same cart a second time.
        #
        # Also requests a Card Fields client token. Failure is non-fatal —
        # the wallet / Apple Pay buttons still work without it.
        #
        # @param order [Spree::Cart, Spree::Order] the session's owner; a cart during checkout
        # @param amount [Numeric, NilClass] defaults to the owner's total less store credits
        # @return [Spree::PaymentSessions::PaypalMerchant]
        # @raise [Spree::Core::GatewayError] when nothing is due, this method is
        #   set to capture later, the owner has already paid with PayPal, or
        #   PayPal fails
        #
        def create_payment_session(order:, amount: nil, **_unused)
          owner = order
          total = amount.presence || owner.total_minus_store_credits

          raise Spree::Core::GatewayError, 'PayPal cannot take a payment of zero' unless total.to_d.positive?

          ensure_captures_at_checkout!

          protect_from_error do
            retire_open_sessions(owner)

            order_presenter = OrderPresenter.new(owner, amount: total)
            paypal_response = client.orders.create_order(order_presenter.to_json)

            session_data = paypal_response.data.as_json

            session_data['enable_apple_pay'] = apple_pay_enabled?
            session_data['enable_card_fields'] = card_fields_enabled?

            if card_fields_enabled?
              client_token = generate_client_token
              session_data['client_token'] = client_token if client_token.present?
            end

            payment_session_class.create!(
              owner: owner,
              payment_method: self,
              amount: total,
              currency: owner.currency,
              status: 'pending',
              external_id: paypal_response.data.id,
              customer: owner.customer,
              external_data: session_data
            )
          end
        end

        ##
        # @param payment_session [Spree::PaymentSessions::PaypalMerchant]
        # @param amount [Numeric, NilClass]
        # @param external_data [Hash]
        # @return [TrueClass, FalseClass, NilClass]
        #
        def update_payment_session(payment_session:, amount: nil, external_data: {})
          attrs = {}
          attrs[:amount] = amount if amount.present?

          attrs[:external_data] = (payment_session.external_data || {}).merge(external_data.stringify_keys) if external_data.present?

          payment_session.update!(attrs) if attrs.any?
        end

        ##
        # Captures the PayPal order and settles its payment on the session's
        # owner, through Spree's shared settlement path.
        #
        # Reads the capture, not the order (PayPal can report an order as
        # COMPLETED whose capture was declined):
        # - COMPLETED settles a captured payment;
        # - PENDING settles a payment that stays pending until PayPal's
        #   capture webhook;
        # - anything else, or no capture, fails the session with no payment.
        #
        # Does not complete the cart — that is handled by Carts::Complete.
        #
        # Only a refusal from PayPal fails the session. When the outcome is
        # unknown (no answer, a server error, a rate limit), PayPal may have
        # captured anyway, so the session stays pending: a retry reads the
        # order first and settles a capture that went through.
        #
        # @param payment_session [Spree::PaymentSessions::PaypalMerchant]
        # @param params [Hash] not used
        # @return [Spree::PaymentSessions::PaypalMerchant]
        # @raise [Spree::Core::GatewayError] when the session can no longer be
        #   used, the amount due has changed, PayPal refuses, or the outcome
        #   is unknown
        #
        def complete_payment_session(payment_session:, **_unused)
          ensure_session_completable!(payment_session)

          response = fetch_paypal_order(payment_session.external_id)
          if payment_session_class.paypal_capture_in(response.data.as_json).blank?
            ensure_amount_matches!(payment_session, response)
            response = capture_paypal_order(payment_session.external_id)
          end

          payment_session.store_paypal_order!(response.data.as_json)

          case payment_session.paypal_capture_status
          when 'COMPLETED' then settle_session!(payment_session, captured: true)
          when 'PENDING' then settle_session!(payment_session, captured: false)
          else payment_session.fail if payment_session.can_fail?
          end

          payment_session
        rescue PaypalServerSdk::APIException => e
          payment_session.fail if paypal_refusal?(e) && payment_session.can_fail?
          raise Spree::Core::GatewayError, "PayPal API error: #{e.message}"
        rescue *CONNECTION_ERRORS => e
          raise Spree::Core::GatewayError, "PayPal connection error: #{e.message}"
        end

        ##
        # Cancels a session nobody is going to complete.
        #
        # With CAPTURE intent no money moves until this gateway captures, so a
        # PayPal order without a paid capture can be dropped. One whose capture
        # is COMPLETED or PENDING has been paid, and is refused.
        #
        # A timeout, an outage or rejected credentials is raised as itself, not
        # as a refusal, so the caller can ask again.
        #
        # @param payment_session [Spree::PaymentSessions::PaypalMerchant]
        # @return [TrueClass, FalseClass] whether the session was canceled
        # @raise [Spree::Core::GatewayError] when the PayPal order has been paid
        #
        def cancel_payment_session(payment_session:)
          response = fetch_paypal_order(payment_session.external_id)
          capture = payment_session_class.paypal_capture_in(response.data.as_json)

          if payment_session_class::PAID_CAPTURE_STATUSES.include?(capture&.dig('status'))
            raise Spree::Core::GatewayError, 'PayPal has already taken payment for this session'
          end

          payment_session.cancel
        rescue PaypalServerSdk::APIException => e
          # PayPal has no such order for these credentials, so it can never be paid.
          raise unless e.response_code == 404

          payment_session.cancel
        end

        ##
        # Reads a PayPal order, including its captures.
        #
        # @param paypal_order_id [String]
        # @return [PaypalServerSdk::ApiResponse]
        #
        def fetch_paypal_order(paypal_order_id)
          client.orders.get_order('id' => paypal_order_id, 'prefer' => 'return=representation')
        end

        ##
        # Parses an incoming PayPal webhook into a payment-session action.
        #
        # Returns nil, so nothing is enqueued, for an event the gem does not
        # settle ({WEBHOOK_ACTIONS}), for a PayPal order that has no session
        # with this method, and for a session settled before Spree 6 (see
        # {#settled_before_spree_6?}).
        #
        # @param raw_body [String]
        # @param headers [Hash]
        # @return [Hash, NilClass]
        # @raise [Spree::PaymentMethod::WebhookSignatureError] when the signature is invalid
        #
        def parse_webhook_event(raw_body, headers)
          verify_webhook_signature!(raw_body, headers)

          event = JSON.parse(raw_body).with_indifferent_access
          action = WEBHOOK_ACTIONS[event[:event_type]]
          return nil unless action

          resource = event[:resource] || {}
          paypal_order_id = resource.dig('supplementary_data', 'related_ids', 'order_id')
          return nil unless paypal_order_id

          payment_session = Spree::PaymentSessions::PaypalMerchant.find_by(payment_method: self, external_id: paypal_order_id)
          return nil unless payment_session
          return nil if settled_before_spree_6?(payment_session, resource['id'])

          # Names the event only: a caller merges this into the payment's metadata.
          metadata = { paypal_event_id: event[:id], paypal_event_type: event[:event_type] }
          { action: action, payment_session: payment_session, metadata: metadata }
        end

        private

        ##
        # PayPal captures at checkout. Only this method's own capture method
        # can refuse it: a store-wide default never switches PayPal off.
        #
        # @raise [Spree::Core::GatewayError]
        #
        def ensure_captures_at_checkout!
          return if capture_method.blank? || capture_method == 'checkout'

          raise Spree::Core::GatewayError,
                "PayPal captures at checkout; capture method #{capture_method} is not supported"
        end

        ##
        # Cancels the owner's earlier PayPal sessions before a new one opens.
        # A completed session means the owner already has its payment, so
        # nothing is replaced.
        #
        # @param owner [Spree::Cart, Spree::Order]
        # @raise [Spree::Core::GatewayError] when the owner has already paid
        #
        def retire_open_sessions(owner)
          sessions = owner.payment_sessions.where(payment_method: self)
          raise Spree::Core::GatewayError, 'This cart has already been paid with PayPal' if sessions.exists?(status: 'completed')

          # A failed confirm leaves its PayPal order payable, so it is retired too.
          open_sessions = sessions.active.order(:id).to_a + sessions.where(status: 'failed').order(:id).to_a
          open_sessions.each { |payment_session| cancel_payment_session(payment_session: payment_session) }
        end

        ##
        # Never captures for a session that can no longer be used, such as one
        # a stale browser tab still holds: it was canceled, it failed, or its
        # owner has already been placed as an order.
        #
        # @raise [Spree::Core::GatewayError]
        #
        def ensure_session_completable!(payment_session)
          if payment_session.canceled? || payment_session.failed?
            raise Spree::Core::GatewayError, "PayPal payment session is #{payment_session.status} and can no longer be completed"
          end
          return if payment_session.order.blank?

          raise Spree::Core::GatewayError, 'PayPal payment session belongs to an order that has already been placed'
        end

        ##
        # Captures the PayPal order. When PayPal says it is already captured
        # (a double-submitted confirm, or a retry after an unanswered capture),
        # the order is read back instead, so that capture settles like any other.
        #
        # @param paypal_order_id [String]
        # @return [PaypalServerSdk::ApiResponse]
        #
        def capture_paypal_order(paypal_order_id)
          client.orders.capture_order('id' => paypal_order_id, 'prefer' => 'return=representation')
        rescue PaypalServerSdk::ErrorException => e
          raise unless paypal_issue?(e, 'ORDER_ALREADY_CAPTURED')

          fetch_paypal_order(paypal_order_id)
        end

        ##
        # Whether PayPal definitely refused the request. A server error, or a
        # client error in {AMBIGUOUS_CLIENT_ERROR_STATUSES}, leaves the outcome
        # unknown.
        #
        # @param error [PaypalServerSdk::APIException]
        # @return [TrueClass, FalseClass]
        #
        def paypal_refusal?(error)
          status = error.response_code.to_i
          status.between?(400, 499) && AMBIGUOUS_CLIENT_ERROR_STATUSES.exclude?(status)
        end

        ##
        # @param error [PaypalServerSdk::ErrorException]
        # @param issue [String] a PayPal error issue code
        # @return [TrueClass, FalseClass]
        #
        def paypal_issue?(error, issue)
          details = error.details
          details.is_a?(Array) && details.any? { |detail| detail.respond_to?(:issue) && detail.issue == issue }
        end

        ##
        # Settles the session's payment, then completes the session.
        #
        # @param captured [TrueClass, FalseClass] false leaves the payment pending
        #
        def settle_session!(payment_session, captured:)
          payment_session.process if payment_session.can_process?

          payment = payment_session.settle_payment!(captured: captured)
          create_profile(payment) if payment.present?

          payment_session.complete unless payment_session.completed?
        end

        ##
        # Refuses to capture a PayPal order whose amount no longer matches what
        # is due — e.g. a gift card was applied, or the cart changed, after the
        # PayPal order was created. Capturing would take the stale amount; the
        # storefront recreates the session instead.
        #
        # @raise [Spree::Core::GatewayError]
        #
        def ensure_amount_matches!(payment_session, fetched)
          value = fetched.data.as_json.dig('purchase_units', 0, 'amount', 'value')
          return if value.blank?

          due = payment_session.owner.total_minus_store_credits
          return if value.to_d == due.to_d

          payment_session.fail if payment_session.can_fail?
          raise Spree::Core::GatewayError,
                "PayPal order amount #{value} does not match the amount due #{due}"
        end

        ##
        # Whether the session was settled before Spree 6. Payments taken on
        # 5.x are keyed on the PayPal capture id, not the order id, so Spree 6
        # cannot link them to their session, and an event delivered late would
        # settle the order a second time.
        #
        # @param payment_session [Spree::PaymentSessions::PaypalMerchant]
        # @param capture_id [String, NilClass] the capture the event is about
        # @return [TrueClass, FalseClass]
        #
        def settled_before_spree_6?(payment_session, capture_id)
          return false unless payment_session.completed? && capture_id.present?

          payment_session.owner.payments.exists?(payment_method: self, response_code: capture_id)
        end

        def verify_webhook_signature!(raw_body, headers)
          if preferred_webhook_secret.blank?
            return if Rails.env.local?

            raise Spree::PaymentMethod::WebhookSignatureError,
                  'PayPal webhook_secret is not configured'
          end

          transmission_id = headers['HTTP_PAYPAL_TRANSMISSION_ID'] || headers['PAYPAL-TRANSMISSION-ID']
          transmission_time = headers['HTTP_PAYPAL_TRANSMISSION_TIME'] || headers['PAYPAL-TRANSMISSION-TIME']
          cert_url = headers['HTTP_PAYPAL_CERT_URL'] || headers['PAYPAL-CERT-URL']
          auth_algo = headers['HTTP_PAYPAL_AUTH_ALGO'] || headers['PAYPAL-AUTH-ALGO']
          transmission_sig = headers['HTTP_PAYPAL_TRANSMISSION_SIG'] || headers['PAYPAL-TRANSMISSION-SIG']

          raise Spree::PaymentMethod::WebhookSignatureError, 'Missing PayPal webhook headers' unless transmission_id && transmission_sig

          token = obtain_access_token

          uri = URI("#{api_base}/v1/notifications/verify-webhook-signature")

          payload = {
            auth_algo: auth_algo,
            cert_url: cert_url,
            transmission_id: transmission_id,
            transmission_sig: transmission_sig,
            transmission_time: transmission_time,
            webhook_id: preferred_webhook_secret,
            webhook_event: JSON.parse(raw_body)
          }

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 10
          request = Net::HTTP::Post.new(uri.path, {
                                          'Content-Type' => 'application/json',
                                          'Authorization' => "Bearer #{token}"
                                        })
          request.body = payload.to_json

          response = http.request(request)
          raise Spree::PaymentMethod::WebhookSignatureError, "Webhook verification failed: HTTP #{response.code}" unless http_success?(response)

          result = JSON.parse(response.body)

          raise Spree::PaymentMethod::WebhookSignatureError, 'Invalid webhook signature' unless result['verification_status'] == 'SUCCESS'
        rescue Spree::PaymentMethod::WebhookSignatureError
          raise
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError, Errno::ECONNREFUSED => e
          raise Spree::PaymentMethod::WebhookSignatureError, "Webhook verification failed: #{e.message}"
        end

        def obtain_access_token
          uri = URI("#{api_base}/v1/oauth2/token")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 10
          request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/x-www-form-urlencoded' })
          request.basic_auth(preferred_client_id, preferred_client_secret)
          request.body = 'grant_type=client_credentials'

          response = http.request(request)
          return nil unless http_success?(response)

          JSON.parse(response.body)['access_token']
        end

        ##
        # Short-lived client token for Card Fields. Returns nil on failure.
        #
        # @return [String, NilClass]
        #
        def generate_client_token
          token = obtain_access_token
          return nil if token.blank?

          uri = URI("#{api_base}/v1/identity/generate-token")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 5
          http.read_timeout = 10
          request = Net::HTTP::Post.new(uri.path, {
                                          'Content-Type' => 'application/json',
                                          'Accept-Language' => 'en_US',
                                          'Authorization' => "Bearer #{token}"
                                        })

          response = http.request(request)
          return nil unless http_success?(response)

          JSON.parse(response.body)['client_token']
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, JSON::ParserError, Errno::ECONNREFUSED => e
          Rails.logger.warn("[spree-paypal_merchant] client token generation failed: #{e.message}")
          nil
        end

        def api_base
          preferred_test_mode ? 'https://api-m.sandbox.paypal.com' : 'https://api-m.paypal.com'
        end

        def http_success?(response)
          response.code.to_i.between?(200, 299)
        end
      end
    end
  end
end
