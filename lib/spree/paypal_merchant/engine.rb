# frozen_string_literal: true

module Spree
  module PaypalMerchant
    ##
    # Rails engine for the PayPal Checkout payment method.
    #
    class Engine < ::Rails::Engine
      require 'spree/core'
      isolate_namespace Spree

      # Decorators reopen existing constants, so Zeitwerk must not autoload them.
      initializer 'spree_paypal_merchant.ignore_decorators_from_zeitwerk', before: :setup_main_autoloader do
        Rails.autoloaders.main.ignore(
          File.join(File.dirname(__FILE__), '../../../app/**/*_decorator*.rb')
        )
      end

      # engine_name generates route-helper prefixes and must be a valid Ruby
      # identifier, so it cannot contain a dash.
      engine_name 'spree_paypal_merchant'

      config.generators do |g|
        g.test_framework :rspec
      end

      ##
      # Loads the gem's decorators. Called on every reload in development.
      #
      # @return [void]
      #
      def self.activate
        Dir.glob(File.join(File.dirname(__FILE__), '../../../app/**/*_decorator*.rb')).each do |c|
          Rails.configuration.cache_classes ? require(c) : load(c)
        end
      end

      config.to_prepare(&method(:activate).to_proc)
    end
  end
end
