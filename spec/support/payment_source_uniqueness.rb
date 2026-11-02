# frozen_string_literal: true

##
# Whether Spree keeps a payment source's profile id unique per payment method.
#
# Spree 6.0.2 scoped it to the payment method. Before that it was unique per
# source type only, so the buyer's PayPal account could already hold a source
# under another PayPal method, and the gem settles the payment without one.
#
module PaymentSourceUniqueness
  def self.per_payment_method?
    Spree::PaymentSource.validators_on(:gateway_payment_profile_id).any? do |validator|
      validator.is_a?(ActiveRecord::Validations::UniquenessValidator) &&
        Array(validator.options[:scope]).include?(:payment_method_id)
    end
  end
end
