# spree-paypal_merchant

PayPal Checkout for Spree 6, as a single payment method covering the PayPal
wallet, Apple Pay, and Card Fields.

Published gem: **`spree-paypal_merchant`**  
Require: **`spree/paypal_merchant`**  
Constant: **`Spree::PaypalMerchant`**

This is not the official `spree_paypal_checkout` gem. It started from that
extension (VAT `AMOUNT_MISMATCH` guard, storefront-owned address) and adds
Apple Pay as a funding source of the same gateway.

## Requirements

Spree 6 (`spree ~> 6.0`) and Ruby 3.3 or newer. Spree 5.6 uses the 5.2.x
releases, on the `5-2-stable` branch.

## What it is

- One `Spree::PaypalMerchant::Gateway` payment method.
- Checkout goes through Spree's **Store API v3 payment sessions**
  (`POST /api/v3/store/carts/:id/payment_sessions` → complete).
- The storefront owns the address. The gem pins it with
  `SET_PROVIDED_ADDRESS` so PayPal does not re-collect it.
- PayPal **captures at checkout**, whatever capture method the store defaults
  to. Authorize now, capture later is not supported: a payment method whose own
  capture method is `on_dispatch` or `manual` is refused.
- The storefront's confirm call and PayPal's webhook settle through the same
  Spree path, in either order. Whichever arrives first creates the payment; the
  other changes nothing.
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

Then add a **PayPal** payment method in the admin dashboard and set:

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

Subscribe it to these events. Others, such as `CHECKOUT.ORDER.APPROVED`, are
ignored.

| Event | What the gem does |
|---|---|
| `PAYMENT.CAPTURE.COMPLETED` | Settles the payment as captured |
| `PAYMENT.CAPTURE.PENDING` | Settles it as pending (an eCheck, say); `COMPLETED` completes it later |
| `PAYMENT.CAPTURE.DENIED`, `PAYMENT.CAPTURE.DECLINED` | Fails the payment session |
| `PAYMENT.CAPTURE.REVERSED`, `PAYMENT.CAPTURE.REFUNDED` | Cancels the payment session, when the event names the PayPal order |

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

## Upgrading from 5.2

Bump the gem to `~> 6.0` as part of your Spree 6 upgrade.

- **No data migration of the gem's own.** Payment methods, sources and
  sessions keep their types. Spree's migrations move the sources' metadata.
- **The webhook URL is unchanged.** `CHECKOUT.ORDER.APPROVED` is no longer
  needed; the gem ignores it.
- **PayPal captures at checkout, whatever the store default is.** A store whose
  default capture method is `on_dispatch` still captures PayPal at checkout. Only
  a PayPal payment method whose own capture method is `on_dispatch` or `manual`
  is refused.
- **Old payments refund as before.** A payment taken on 5.x refunds through the
  capture id stored on it.
- **The storefront contract is the same.** The Store API type,
  `external_data` keys and `public_preferences` are unchanged, so the gem asks
  nothing new of the storefront.
- **The 5.x checkout flow is gone.** `Spree::PaypalMerchant::Order`,
  `CreatePayment`, `CaptureOrder`, the order's `paypal_id`, and the gateway's
  `authorize`, `purchase`, `capture` and `find_order` are removed, along with
  the ERB admin views. Spree 6 has no Rails admin; its dashboard builds the
  settings form from the gateway's preferences. The `spree_paypal_merchant_orders`
  table stays.

Three things to know before you cut over:

1. **Webhooks are one-shot.** Spree 6 settles a payment webhook in a
   background job and does not retry a failed one. PayPal does not send it
   again, because Spree already answered 200. If the gem cannot read PayPal's
   order, or the order shows no completed or pending capture, that event is
   dropped. The storefront's confirm step, or a later PayPal event, settles the
   payment instead.
2. **Check for PayPal payments still pending** (an eCheck, say). The gem
   ignores events for checkouts settled under 5.x. After the upgrade, a pending
   capture that completes later won't update its Spree payment. Settle those
   payments by hand.
3. **A source's profile id can change.** A PayPal wallet with no PayPal account
   id is now keyed by the cart's (or order's) prefixed id instead of the order
   number. Such a source isn't reused, and a new one is created.

## Known limitations

- PayPal treats HUF and TWD as zero-decimal currencies, but Spree formats them
  with two decimals, so those currencies aren't supported.
- Multi-seller checkouts, where one payment covers several orders, aren't
  tested.

## Developing

```bash
bundle install
bundle exec rake test_app
bundle exec rspec
```

Specs run against PostgreSQL (set `DATABASE_URL`). To test one Spree version,
set `SPREE_VERSION`, for example `SPREE_VERSION=6.0.0 bundle update spree`. CI
runs Spree 6.0.0 and the newest release, each on Ruby 3.3 and 4.0.

## License

MIT. Derived from [spree/spree_paypal_checkout](https://github.com/spree/spree_paypal_checkout)
(Vendo Connect Inc.), re-namespaced and extended by Aypex.
