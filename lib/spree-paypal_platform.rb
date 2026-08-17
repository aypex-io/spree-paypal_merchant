# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-paypal_platform"`
# in a host Gemfile issues `require "spree-paypal_platform"`. The real entry
# point is `spree/paypal_checkout` (matching the Spree::PaypalCheckout
# namespace), so this shim keeps the default `Bundler.require` working.
require 'spree/paypal_checkout'
