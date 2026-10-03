# spree-paypal_merchant

PayPal Checkout for Spree 5.6+, as a single payment method covering the PayPal
wallet, Apple Pay, and Card Fields.

Published gem: **`spree-paypal_merchant`**  
Require: **`spree/paypal_merchant`**  
Constant: **`Spree::PaypalMerchant`**

This is not the official `spree_paypal_checkout` gem. It started from that
extension (VAT `AMOUNT_MISMATCH` guard, storefront-owned address) and adds
Apple Pay as a funding source of the same gateway.

## What it is

- One `Spree::PaypalMerchant::Gateway` payment method.
- Checkout goes through Spree's **Store API v3 payment sessions**
  (`POST /api/v3/store/carts/:id/payment_sessions` → complete).
- The storefront owns the address. The gem pins it with
  `SET_PROVIDED_ADDRESS` so PayPal does not re-collect it.
- Amount breakdown sends **only `additional_tax_total`**. Sending full
  `tax_total` double-counts included VAT and trips PayPal `AMOUNT_MISMATCH`.
- Talks to PayPal via the official
  [`paypal-server-sdk`](https://github.com/paypal/PayPal-Ruby-Server-SDK) gem
  (`~> 2.3`).

Apple Pay is not a second payment method and not a Spree Integration. It is
a `payment_source.apple_pay` on the same Checkout order.

## Installation

```ruby
gem 'spree-paypal_merchant'
```

```bash
bundle install
bin/rails g spree:paypal_merchant:install
```

The generator copies the migrations. Pass `--auto-run-migrations` to skip the
prompt.

Then add a **PayPal** payment method in admin and set:

| Preference | Purpose |
|---|---|
| `client_id` / `client_secret` | REST app credentials from the PayPal Developer Dashboard |
| `webhook_secret` | PayPal webhook ID (used as the verify-webhook `webhook_id`) |
| `test_mode` | Sandbox vs live |
| `enable_apple_pay` | Offer Apple Pay on the storefront (default on) |
| `enable_card_fields` | Offer Card Fields on the storefront (default on) |

Webhook URL is the standard Spree v3 payments webhook:

```text
https://<store>/api/v3/webhooks/payments/<prefixed-payment-method-id>
```

## Apple Pay

1. Enable Apple Pay on the PayPal business account.
2. Register every storefront domain (and subdomain) that will show the button
   in the [PayPal Apple Pay domain
   registration](https://developer.paypal.com/docs/checkout/apm/apple-pay/)
   dashboard.
3. Headless storefronts load the PayPal JS SDK with `components=applepay`
   and render Apple's `ApplePaySession`. The gem records
   `payment_source.apple_pay` as
   `Spree::PaypalMerchant::PaymentSources::ApplePay`.
4. Safari + HTTPS only.

## Developing

```bash
bundle install
bundle exec rake test_app
bundle exec rspec
```

## License

MIT. Derived from [spree/spree_paypal_checkout](https://github.com/spree/spree_paypal_checkout)
(Vendo Connect Inc.), re-namespaced and extended by Aypex.
