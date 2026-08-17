# frozen_string_literal: true

require 'spree_core'
require 'paypal_server_sdk'
require 'spree/paypal_checkout/version'
require 'spree/paypal_checkout/engine'

module Spree
  module PaypalCheckout
    ##
    # Table prefix for models nested under this module.
    #
    # Must live on the module, not on {Base}. ActiveRecord walks
    # `module_parents` for `table_name_prefix` and finds `Spree` first
    # (`"spree_"`) unless this closer parent defines it.
    #
    # @return [String]
    #
    def self.table_name_prefix
      'spree_paypal_checkout_'
    end

    ##
    # STI type names that count as this gem's gateway.
    #
    # Includes the historical `SpreePaypalCheckout::Gateway` string from the
    # official / forked gem so existing payment-method rows keep matching
    # after a host switches gems, even before the type-rewrite migration
    # runs.
    #
    # @return [Array<String>]
    #
    def self.gateway_type_names
      (
        [Gateway.name, 'SpreePaypalCheckout::Gateway'] + Gateway.descendants.map(&:name)
      ).uniq
    end
  end
end

# Historical top-level namespace from `spree_paypal_checkout`. Existing
# `spree_payment_methods.type` / `spree_payment_sources.type` rows store
# `SpreePaypalCheckout::…`; this alias lets those strings constantize
# onto the new classes.
SpreePaypalCheckout = Spree::PaypalCheckout
