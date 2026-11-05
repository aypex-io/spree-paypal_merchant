# frozen_string_literal: true

##
# Whether Spree asks the payment method before it lets a payment be voided.
#
# Spree 6.0.2 made Spree::Payment#can_void? (which decides whether the
# dashboard offers Void) ask the payment method's +can_void?(payment)+. Before
# that it went by the payment's status alone.
#
module PaymentVoidHook
  def self.asks_payment_method?
    payment_method = Spree::PaymentMethod.new
    payment_method.define_singleton_method(:can_void?) { |_payment| false }

    !Spree::Payment.new(status: 'completed', payment_method: payment_method).can_void?
  end
end
