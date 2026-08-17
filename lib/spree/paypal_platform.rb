# frozen_string_literal: true

require 'spree_core'
require 'paypal_server_sdk'
require 'spree/paypal_platform/version'
require 'spree/paypal_platform/engine'

module Spree
  module PaypalPlatform
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
      'spree_paypal_platform_'
    end

    ##
    # STI type names that count as this gem's gateway.
    #
    # @return [Array<String>]
    #
    def self.gateway_type_names
      ([Gateway.name] + Gateway.descendants.map(&:name)).uniq
    end
  end
end
