# Changelog

## 5.1.4

- `enable_card_fields` preference (checkbox, default on).
- Storefront sees `enable_apple_pay` and `enable_card_fields` on the payment
  method (`public_preferences`) and on the payment session `external_data`.
- Client token is not requested when Card Fields are disabled.

## 5.1.3

Remove the unused `apple_pay_domain` preference. Domain registration is
in the PayPal dashboard, not this field.

## 5.1.2

- Completing a session GETs the PayPal order first and skips capture when
  it is already `COMPLETED` (Apple Pay `confirmOrder`).
- `CreateSource` accepts an empty `payment_source.paypal` hash from the
  create-order echo so checkout can finish after PayPal has taken payment.

## 5.1.1

First release.

- `Spree::PaypalPlatform::Gateway` for Spree 5.6+
- PayPal wallet, Apple Pay, and Card Fields on one payment method
- Store API v3 payment sessions
- `SET_PROVIDED_ADDRESS` so the storefront owns shipping
- VAT-safe amount breakdown (`additional_tax_total` only)
- Official `paypal-server-sdk` `~> 2.3`
- One migration: create `spree_paypal_platform_orders`
