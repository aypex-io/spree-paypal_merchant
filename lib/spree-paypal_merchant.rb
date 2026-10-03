# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-paypal_merchant"`
# issues `require "spree-paypal_merchant"`. The real entry point is
# `spree/paypal_merchant` (matching Spree::PaypalMerchant).
require 'spree/paypal_merchant'
