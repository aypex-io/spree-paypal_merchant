# frozen_string_literal: true

FactoryBot.define do
  factory :paypal_merchant_gateway, class: 'Spree::PaypalMerchant::Gateway' do
    # Names are unique per store, and several gateways can share one store.
    sequence(:name) { |n| "PayPal Checkout #{n}" }
    association :store, factory: :store
    preferences do
      {
        client_id: ENV.fetch('PAYPAL_CLIENT_ID', 'client_id_test'),
        client_secret: ENV.fetch('PAYPAL_CLIENT_SECRET', 'client_secret_test'),
        test_mode: true,
        enable_apple_pay: true,
        enable_card_fields: true
      }
    end
  end

  factory :paypal_merchant_payment_source, class: 'Spree::PaypalMerchant::PaymentSources::Paypal' do
    association :payment_method, factory: :paypal_merchant_gateway
    gateway_payment_profile_id { 'PAY-CUSTOMER-ID' }
  end

  factory :paypal_merchant_apple_pay_source, class: 'Spree::PaypalMerchant::PaymentSources::ApplePay' do
    association :payment_method, factory: :paypal_merchant_gateway
    gateway_payment_profile_id { 'APPLEPAY-TOKEN-1' }
    card_brand { 'VISA' }
    last_digits { '4242' }
  end

  factory :paypal_merchant_payment_session, class: 'Spree::PaymentSessions::PaypalMerchant' do
    association :cart, factory: :cart_with_line_items
    order { nil }
    # A payment settles only through a method in its owner's store.
    payment_method { association :paypal_merchant_gateway, store: (cart || order).store }
    amount { (cart || order).total }
    currency { (cart || order).currency }
    status { 'pending' }
    external_id { "PAYPAL-ORDER-#{SecureRandom.hex(8).upcase}" }
    external_data do
      JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/paypal_order.json')))
    end

    factory :completed_paypal_merchant_payment_session do
      status { 'completed' }
      external_data do
        JSON.parse(File.read(Spree::PaypalMerchant::Engine.root.join('spec/fixtures/captured_paypal_order.json')))
      end
    end
  end
end
