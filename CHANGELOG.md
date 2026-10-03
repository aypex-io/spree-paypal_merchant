# Changelog

## 5.2.0

Renamed from `spree-paypal_platform`. Same code, new name.

| | Before | After |
|---|---|---|
| Gem | `spree-paypal_platform` | `spree-paypal_merchant` |
| Require | `spree/paypal_platform` | `spree/paypal_merchant` |
| Constant | `Spree::PaypalPlatform` | `Spree::PaypalMerchant` |
| Table | `spree_paypal_platform_orders` | `spree_paypal_merchant_orders` |
| Store API type | `paypal_platform` | `paypal_merchant` |
| Generator | `spree:paypal_platform:install` | `spree:paypal_merchant:install` |

To upgrade, swap the gem in the Gemfile and run
`bin/rails g spree:paypal_merchant:install`. It copies
`RenameSpreePaypalPlatformToPaypalMerchant`, which renames the table and
rewrites stored STI class names (payment methods, payment sources, payment
sessions). Map the `paypal_merchant` Store API type in the storefront
*before* deploying the backend.

Entries below use the old name.

## 5.1.5

- Gift cards and store credit: the PayPal order is created for the amount
  due (`total_minus_store_credits`), not the full order total. Before, PayPal
  charged the full total while Spree recorded the gift card as paying part
  of it, so the customer paid twice for that part. A partial charge is sent
  as a plain amount, without the breakdown and items that sum to the full
  total.
- Completing a session refuses to capture when the PayPal order amount no
  longer matches the amount due (e.g. a gift card was applied, or the cart
  changed, after the PayPal order was created). The session fails and the
  storefront creates a new one.

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
