# frozen_string_literal: true

# Bundler auto-requires a gem by its *name*, so `gem "spree-paypal_platform"`
# issues `require "spree-paypal_platform"`. The real entry point is
# `spree/paypal_platform` (matching Spree::PaypalPlatform).
require 'spree/paypal_platform'
