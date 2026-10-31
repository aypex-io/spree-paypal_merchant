# frozen_string_literal: true

require 'spree_core'
require 'paypal_server_sdk'
require 'spree/paypal_merchant/version'
require 'spree/paypal_merchant/engine'

module Spree
  module PaypalMerchant
    ##
    # Table prefix for models nested under this module.
    #
    # Must live on this module. ActiveRecord walks `module_parents` for
    # `table_name_prefix` and finds `Spree` first (`"spree_"`) unless this
    # closer parent defines it.
    #
    # @return [String]
    #
    def self.table_name_prefix
      'spree_paypal_merchant_'
    end

    ##
    # STI type names that count as this gem's gateway.
    #
    # @return [Array<String>]
    #
    def self.gateway_type_names
      ([Gateway.name] + Gateway.descendants.map(&:name)).uniq
    end

    ##
    # The id a PayPal resource's link names. PayPal links a refund to its
    # capture, and a capture to its order, with an +up+ link such as
    # +https://api.paypal.com/v2/payments/captures/<id>+.
    #
    # @param links [Array<Hash>, NilClass] the resource's +links+, as JSON
    # @param rel [String] the link's relation, such as +up+
    # @param path [String] what precedes the id, such as +v2/payments/captures+
    # @return [String, NilClass] nil when no such link names an id
    #
    def self.linked_id(links, rel:, path:)
      pattern = %r{/#{Regexp.escape(path)}/([^/?#]+)\z}

      Array(links).each do |link|
        next unless link.respond_to?(:to_h) && link.to_h.with_indifferent_access[:rel] == rel

        id = link.to_h.with_indifferent_access[:href].to_s[pattern, 1]
        return id if id.present?
      end

      nil
    end
  end
end
