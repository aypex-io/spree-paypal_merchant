# Changelog

All notable changes to this project are documented in this file.

## 5.0.1

Published name is **`spree-paypal_platform`**. RubyGems rejected
`spree-paypal_checkout` as too similar to the official
`spree_paypal_checkout`. Require path and constants are unchanged
(`spree/paypal_checkout` → `Spree::PaypalCheckout`).

## 5.0.0

First Aypex release. Intended published name `spree-paypal_checkout` was
never accepted by RubyGems; see 5.0.1.

### Audit follow-up

- Do not log PayPal request bodies; client logging is WARN without bodies/headers.
- Webhook verify now checks HTTP status and is specced for signed and unsigned paths.
- `#authorize` raises `NotImplementedError`.
- `#void` / `#credit` / `#cancel` specs restored; `CaptureOrder` no longer uses the `money` gem.
- Unique index on `spree_paypal_checkout_orders.paypal_id`.
- Payment sources share `#display_payment_info`; OAuth/token HTTP responses must be 2xx.

- Port of the `aypex-io/spree_paypal_checkout` `tongkat-fitness` fork into
  `Spree::PaypalCheckout`, published as `spree-paypal_checkout`.
- Store API v3 payment sessions only. No `/api/v2/storefront/paypal_orders`.
- Official `paypal-server-sdk` `~> 2.3`.
- Apple Pay and Card Fields recorded as payment sources on the same gateway.
- Keeps the VAT `AMOUNT_MISMATCH` guard (additional tax only) and
  `SET_PROVIDED_ADDRESS` storefront-owned shipping.
- STI alias + rewrite migration for hosts coming from
  `SpreePaypalCheckout::Gateway`.
