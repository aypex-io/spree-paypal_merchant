# frozen_string_literal: true

# Must be after_initialize: spree_core assigns (does not append to)
# config.spree.payment_methods in its own after_initialize, and a
# file-scope registration here would be silently clobbered.
Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << Spree::PaypalMerchant::Gateway
end
