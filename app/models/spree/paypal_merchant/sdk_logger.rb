# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Hands the PayPal SDK's request and response lines to the Rails log.
    #
    # Given no logger, the SDK writes each line to standard output, outside
    # the app's log level and format. It calls #log with a template such as
    # "Request {method} {url}" and the values that fill it; a plain Logger
    # would print the template unfilled.
    #
    # @example
    #   PaypalServerSdk::LoggingConfiguration.new(logger: Spree::PaypalMerchant::SdkLogger.new, log_level: Logger::DEBUG)
    #
    class SdkLogger
      PREFIX = '[spree-paypal_merchant]'
      PLACEHOLDER = /\{([\w-]+)\}/

      ##
      # @param logger [Logger] where the lines go
      #
      def initialize(logger = Rails.logger)
        @logger = logger
      end

      ##
      # @param level [Integer] the Logger severity to write at
      # @param message [String] the SDK's template, with {name} placeholders
      # @param params [Hash{String, Symbol => Object}] the placeholder values
      # @return [true]
      #
      def log(level, message, params = {})
        @logger.add(level) { "#{PREFIX} #{fill(message, params)}" }
      end

      private

      def fill(message, params)
        message.gsub(PLACEHOLDER) do
          key = Regexp.last_match(1)
          params.fetch(key) { params[key.to_sym] }
        end
      end
    end
  end
end
