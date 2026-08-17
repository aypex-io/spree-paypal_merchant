# Changelog

All notable changes to this project are documented in this file.

## 5.1.1

One migration: create `spree_paypal_platform_orders`. Removed the leftover
checkout-table / STI rewrite / rename migrations from 5.1.0.

## 5.1.0

Full internal rename to `Spree::PaypalPlatform`.

- Require path is `spree/paypal_platform`. There is no `spree/paypal_checkout`
  require and no `Spree::PaypalCheckout` constant.
- Engine name, table prefix, payment-session STI, admin partials, and
  `method_type` are all `spree_paypal_platform`.
- Migration renames `spree_paypal_checkout_orders` →
  `spree_paypal_platform_orders` and rewrites remaining STI type strings.
- Install generator: `bin/rails g spree:paypal_platform:install`.

## 5.0.1

Published name is **`spree-paypal_platform`**. RubyGems rejected
`spree-paypal_platform` as too similar to the official
`spree_paypal_platform`. Require path and constants are unchanged
(`spree/paypal_platform` → `Spree::PaypalPlatform`).

## 5.0.0

First Aypex release. Intended published name `spree-paypal_platform` was
never accepted by RubyGems; see 5.0.1.

### Audit follow-up

- Do not log PayPal request bodies; client logging is WARN without bodies/headers.
- Webhook verify now checks HTTP status and is specced for signed and unsigned paths.
- `#authorize` raises `NotImplementedError`.
- `#void` / `#credit` / `#cancel` specs restored; `CaptureOrder` no longer uses the `money` gem.
- Unique index on `spree_paypal_platform_orders.paypal_id`.
- Payment sources share `#display_payment_info`; OAuth/token HTTP responses must be 2xx.

- Port of the `aypex-io/spree_paypal_platform` `tongkat-fitness` fork into
  `Spree::PaypalPlatform`, published as `spree-paypal_platform`.
- Store API v3 payment sessions only. No `/api/v2/storefront/paypal_orders`.
- Official `paypal-server-sdk` `~> 2.3`.
- Apple Pay and Card Fields recorded as payment sources on the same gateway.
- Keeps the VAT `AMOUNT_MISMATCH` guard (additional tax only) and
  `SET_PROVIDED_ADDRESS` storefront-owned shipping.
- STI alias + rewrite migration for hosts coming from
  `SpreePaypalCheckout::Gateway`.
