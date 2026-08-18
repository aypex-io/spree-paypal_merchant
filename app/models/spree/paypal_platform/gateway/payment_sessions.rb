# frozen_string_literal: true

require 'net/http'

module Spree
  module PaypalPlatform
    class Gateway < ::Spree::Gateway
      ##
      # Payment-session lifecycle used by Spree 5 storefronts.
      #
      module PaymentSessions
        extend ActiveSupport::Concern

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
          Spree::PaymentSessions::PaypalPlatform
        end

        ##
        # Creates a PayPal order and persists a payment session.
        #
        # Also requests a Card Fields client token. Failure is non-fatal —
        # the wallet / Apple Pay buttons still work without it.
        #
        # @param order [Spree::Order]
        # @param amount [Numeric, NilClass]
        # @param external_data [Hash]
        # @return [Spree::PaymentSessions::PaypalPlatform, NilClass]
        #
        def create_payment_session(order:, amount: nil, **_unused)
          total = amount.presence || order.total_minus_store_credits

          return nil if total.zero?

          protect_from_error do
            order_presenter = OrderPresenter.new(order)
            paypal_response = client.orders.create_order(order_presenter.to_json)

            session_data = paypal_response.data.as_json

            session_data['enable_apple_pay'] = apple_pay_enabled?
            session_data['enable_card_fields'] = card_fields_enabled?

            if card_fields_enabled?
              client_token = generate_client_token
              session_data['client_token'] = client_token if client_token.present?
            end

            payment_session_class.create!(
              order: order,
              payment_method: self,
              amount: total,
              currency: order.currency,
              status: 'pending',
              external_id: paypal_response.data.id,
              customer: order.user,
              external_data: session_data
            )
          end
        end

        ##
        # @param payment_session [Spree::PaymentSessions::PaypalPlatform]
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
        # Captures the PayPal order and creates the Spree payment.
        #
        # Does not complete the order — that is handled by Carts::Complete.
        #
        # @param payment_session [Spree::PaymentSessions::PaypalPlatform]
        # @param params [Hash]
        # @return [void]
        #
        def complete_payment_session(payment_session:, **_unused)
          paypal_order_id = payment_session.external_id
          lookup = { 'id' => paypal_order_id, 'prefer' => 'return=representation' }

          fetched = client.orders.get_order(lookup)
          response =
            if fetched.data.status == 'COMPLETED'
              fetched
            else
              client.orders.capture_order(lookup)
            end

          payment_session.update!(external_data: response.data.as_json)

          payment_session.order.with_lock do
            if response.data.status == 'COMPLETED'
              payment_session.process if payment_session.can_process?

              payment = payment_session.find_or_create_payment!

              if payment.present? && !payment.completed?
                payment.started_processing! if payment.checkout?
                payment.complete! if payment.can_complete?
              end

              create_profile(payment) if payment&.source.present?

              payment_session.complete unless payment_session.completed?
            elsif payment_session.can_fail?
              payment_session.fail
            end
          end
        rescue PaypalServerSdk::APIException => e
          payment_session.fail if payment_session.can_fail?
          raise Spree::Core::GatewayError, "PayPal API error: #{e.message}"
        end

        ##
        # Parses an incoming PayPal webhook into a payment-session action.
        #
        # @param raw_body [String]
        # @param headers [Hash]
        # @return [Hash, NilClass]
        #
        def parse_webhook_event(raw_body, headers)
          verify_webhook_signature!(raw_body, headers)

          event = JSON.parse(raw_body).with_indifferent_access
          event_type = event[:event_type]
          resource = event[:resource] || {}

          paypal_order_id = extract_order_id_from_webhook(event_type, resource)
          return nil unless paypal_order_id

          payment_session = Spree::PaymentSessions::PaypalPlatform.find_by(
            payment_method: self,
            external_id: paypal_order_id
          )
          return nil unless payment_session

          case event_type
          when 'CHECKOUT.ORDER.APPROVED'
            { action: :authorized, payment_session: payment_session, metadata: { paypal_event: event } }
          when 'PAYMENT.CAPTURE.COMPLETED'
            { action: :captured, payment_session: payment_session, metadata: { paypal_event: event } }
          when 'PAYMENT.CAPTURE.DENIED', 'PAYMENT.CAPTURE.DECLINED'
            { action: :failed, payment_session: payment_session, metadata: { paypal_event: event } }
          when 'PAYMENT.CAPTURE.REVERSED', 'PAYMENT.CAPTURE.REFUNDED'
            { action: :canceled, payment_session: payment_session, metadata: { paypal_event: event } }
          end
        end

        private

        def extract_order_id_from_webhook(event_type, resource)
          case event_type
          when /\ACHECKOUT\.ORDER\./
            resource['id']
          when /\APAYMENT\.CAPTURE\./
            resource.dig('supplementary_data', 'related_ids', 'order_id')
          end
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
          Rails.logger.warn("[spree-paypal_platform] client token generation failed: #{e.message}")
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
