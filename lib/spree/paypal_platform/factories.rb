# frozen_string_literal: true

FactoryBot.define do
  factory :paypal_platform_gateway, class: 'Spree::PaypalPlatform::Gateway' do
    name { 'PayPal Checkout' }
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

  factory :paypal_platform_payment_source, class: 'Spree::PaypalPlatform::PaymentSources::Paypal' do
    association :payment_method, factory: :paypal_platform_gateway
    gateway_payment_profile_id { 'PAY-CUSTOMER-ID' }
  end

  factory :paypal_platform_apple_pay_source, class: 'Spree::PaypalPlatform::PaymentSources::ApplePay' do
    association :payment_method, factory: :paypal_platform_gateway
    gateway_payment_profile_id { 'APPLEPAY-TOKEN-1' }
    card_brand { 'VISA' }
    last_digits { '4242' }
  end

  factory :paypal_platform_payment_session, class: 'Spree::PaymentSessions::PaypalPlatform' do
    association :order, factory: :order
    association :payment_method, factory: :paypal_platform_gateway
    amount { order.total }
    currency { order.currency }
    status { 'pending' }
    external_id { "PAYPAL-ORDER-#{SecureRandom.hex(8).upcase}" }
    external_data do
      JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/paypal_order.json')))
    end

    factory :completed_paypal_platform_payment_session do
      status { 'completed' }
      external_data do
        JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/captured_paypal_order.json')))
      end
    end
  end

  factory :paypal_platform_order, class: 'Spree::PaypalPlatform::Order' do
    paypal_id { 'PAY-ORDER-ID' }
    order { create(:order) }
    payment_method { create(:paypal_platform_gateway) }
    amount { order.total }
    data { JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/paypal_order.json'))) }

    factory :captured_paypal_platform_order do
      data { JSON.parse(File.read(Spree::PaypalPlatform::Engine.root.join('spec/fixtures/captured_paypal_order.json'))) }
    end
  end
end
