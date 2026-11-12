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
- The payment session's `external_data.client_id` is the client id to load
  PayPal's JS SDK with. It comes from the payment method, so the SDK always
  belongs to the same PayPal app (sandbox or live) as the order, and one
  storefront build can serve a sandbox and a live backend.
- PayPal **captures at checkout**, whatever capture method the store defaults
  to. Authorize now, capture later is not supported: a payment method whose own
  capture method is `on_dispatch` or `manual` is refused. Spree never captures a
  PayPal payment on dispatch, and never treats one as left for staff to collect.
- A payment session's amount is fixed once its PayPal order exists. Changing
  it is refused: the storefront creates a new session instead. The payment
  records the amount PayPal captured.
- The storefront's confirm call and PayPal's webhook settle through the same
  Spree path, in either order. Whichever arrives first creates the payment, and
  the other never creates a second one. On Spree 6.0.4 and later, a webhook
  that arrives second still places the cart if nothing has placed it yet.
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

Then connect PayPal in the dashboard under **Settings → Integrations**. The
**[setup guide](docs/setup.md)** walks store staff through it: the PayPal app,
the webhook address and events, and testing in the sandbox. The card's
**Setup guide** link opens it too. The preferences it sets:

| Preference | Purpose |
|---|---|
| `client_id` / `client_secret` | REST app credentials from the PayPal Developer Dashboard. `client_id` is public and sent to storefronts with the payment method; `client_secret` never is |
| `webhook_secret` | PayPal webhook ID (used as the verify-webhook `webhook_id`) |
| `test_mode` | Sandbox vs live |
| `enable_apple_pay` | Offer Apple Pay on the storefront (default on) |
| `enable_card_fields` | Offer Card Fields on the storefront (default on) |
| `enable_express_checkout` | Offer PayPal express checkout (PayPal's button on the cart) on the storefront (default on). A storefront switch only: the gem exposes it but does not enforce it |

Webhook URL is the standard Spree v3 payments webhook. PayPal only accepts an
absolute `https://` URL:

```text
https://<store>/api/v3/webhooks/payments/<prefixed-payment-method-id>
```

The gateway's `webhook_url` builds it from the store's URL. When the Spree API
is served from another host than the store's URL (a headless storefront on its
own domain, say), give PayPal the **API host** instead:

```text
https://<api host>/api/v3/webhooks/payments/<prefixed-payment-method-id>
```

Subscribe it to these events. Others, such as `CHECKOUT.ORDER.APPROVED`, are
ignored.

| Event | What the gem does |
|---|---|
| `PAYMENT.CAPTURE.COMPLETED` | Settles the payment as captured |
| `PAYMENT.CAPTURE.PENDING` | Settles it as pending (an eCheck, say); `COMPLETED` completes it later |
| `PAYMENT.CAPTURE.DENIED`, `PAYMENT.CAPTURE.DECLINED` | Fails the payment session if it is still open. A payment already left pending by `PAYMENT.CAPTURE.PENDING` stays pending (no money was taken); use Capture in the dashboard: it reads PayPal and fails the payment if PayPal denied the capture (or completes it if PayPal completed it) |
| `PAYMENT.CAPTURE.REFUNDED` | Records the refund on the Spree payment (see [Refunds made in PayPal](#refunds-made-in-paypal)). PayPal sends it for refunds made from Spree too; those are not recorded twice |
| `PAYMENT.CAPTURE.REVERSED` | Cancels the payment session if it is still open and the event names the PayPal order. The event leaves a completed session and its payment as they are. But the refund sync records whatever PayPal lists as a `COMPLETED` refund of the capture, so if PayPal lists a reversal (after a chargeback, say) among the order's refunds, a later sync records it as a refund |

## In the dashboard

- **Capture** on a pending PayPal payment reads PayPal and settles the payment
  the way PayPal did. It completes the payment if PayPal completed the capture,
  and fails it if PayPal denied or declined it. It never captures again. While
  PayPal is still processing the capture, or can't be reached, Capture says so
  and the payment stays pending, so Capture can be pressed again. Capture takes
  the whole payment: PayPal captured it all at checkout.
- **Canceling an order** with Spree's default (`refund_payments: false`) marks
  a completed PayPal payment void in Spree while PayPal keeps the money. Refund
  the payment in the dashboard before canceling the order, or refund it in
  PayPal.
- **Void** always fails. A PayPal payment holds captured money, so refund it
  instead. On Spree 6.0.2 and later the dashboard doesn't offer Void on a
  completed PayPal payment at all. One that PayPal is still processing can't be
  voided or canceled; refund it once PayPal completes it.

## Refunds made in PayPal

A refund made in PayPal's own dashboard is recorded in Spree, so the order
stops showing as paid. When PayPal sends `PAYMENT.CAPTURE.REFUNDED`, the gem
queues `Spree::PaypalMerchant::SyncRefundsJob` (on Spree's payment webhook
queue, 30 seconds later) for the payment the refund is about. The job reads the
payment's refunds from PayPal, not from the event, and records each `COMPLETED`
one Spree doesn't have yet:

- as a Spree refund for PayPal's amount, with the PayPal refund id as its
  transaction id, so Spree never asks PayPal to refund it again. Its metadata
  says it was recorded from PayPal. The order's payment state and totals update
  as for a refund made in Spree.
- with the store's **Return processing** refund reason, the one Spree's refund
  workflow defaults to, or else the store's first reason by name, as the admin
  API defaults. The gem never creates a reason: with none, nothing is recorded
  and a warning is logged.

Refunds made from Spree already carry their PayPal refund id, so they are never
recorded twice, and the job runs again later while one is still waiting for
PayPal's answer. Not recorded, and logged: a refund PayPal hasn't completed, one
in another currency than the payment's, one for more than is left to refund,
and any refund of a payment that isn't completed (one Spree voided, say).
Payments taken on 5.x are synced too.

The sync records whatever PayPal lists as a `COMPLETED` refund of the
payment's capture. If PayPal lists a reversal there (after a chargeback, say),
the sync records it as a refund, though `PAYMENT.CAPTURE.REVERSED` itself
changes nothing.

Refunds recorded from PayPal don't run Spree's refund workflow, so its
callbacks (`:validate`, `:before_refund`, `:after_refund`) don't run for them.
App hooks registered there, such as a customer refund email, won't fire. The
`refund.created` and `payment.refunded` events do.

For refunds made before the webhook was set up, or ones the job gave up on,
run the same sync for one order's PayPal payments. It prints what it recorded
or skipped, and running it again records nothing new:

```bash
bin/rails 'spree:paypal_merchant:sync_refunds[R123456789]'
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

## Express checkout

Express checkout lets a buyer pay from the cart: PayPal collects the shipping
address and delivery choice, and the gem copies them onto the cart.

- **Create.** `create_payment_session` with `external_data: { express: true }`
  creates a PayPal order with `shipping_preference: GET_FROM_FILE`, so PayPal
  asks for the address. Shipping options are built from the cart's delivery
  rates; each option's id is the Spree delivery method's prefixed id. Gift card
  and store credit amounts count as a discount in PayPal's breakdown. Rates
  without a price are left out. PayPal takes at most 10 options, so a cart with
  more rates offers the selected rate and the first 9 others, cheapest first.
  If the breakdown can't balance, the order is created with the amount alone
  and no shipping options.
- **Update.** `update_payment_session` on a pending express session PATCHes the
  PayPal order from the cart: the amount is replaced and the shipping options
  are added. It refuses a session that isn't pending, a cart with no delivery,
  and an amount the cart doesn't owe. Sessions that aren't express still refuse
  amount changes.
- **Complete.** `complete_payment_session` on an express order PayPal hasn't
  captured writes PayPal's shipping name and address (as both ship and bill
  address), the payer's email (only if the cart has none) and phone onto the
  cart, and selects the delivery the buyer chose in PayPal. When PayPal offered
  no choice, the delivery the cart had is selected again, if the address is
  still offered it; otherwise Spree's default stays and the amount check
  decides. This happens atomically under the cart's row lock and is skipped if
  already applied. The existing amount check and the capture follow. If any
  step refuses, the session fails and nothing is captured.
- **Switch.** `enable_express_checkout` (default on) is exposed with the other
  public preferences so a storefront can hide the button. The gem does not
  enforce it.

If your store requires a phone number on addresses and the buyer's PayPal
account has none, express completion fails after the buyer has approved the
payment. Such stores should not require a phone number, or should keep express
checkout off.

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
  `external_data` keys and `public_preferences` are unchanged. One thing is
  refused: a session's amount can't be changed after it is created, so a
  storefront that updated it must create a new payment session instead.
- **The 5.x checkout flow is gone.** `Spree::PaypalMerchant::Order`,
  `CreatePayment`, `CaptureOrder`, the order's `paypal_id` and the gateway's
  `find_order` are removed, along with the ERB admin views. Spree 6 has no Rails
  admin; its dashboard builds the settings form from the gateway's preferences.
  The `spree_paypal_merchant_orders` table stays. The gateway's `authorize` and
  `purchase` now fail, since PayPal payments are taken through a payment
  session, and `capture` reads PayPal (see "In the dashboard").

Three things to know before you cut over:

1. **Webhooks are one-shot before Spree 6.0.4.** Spree 6 settles a payment
   webhook in a background job. PayPal does not send it again, because Spree
   already answered 200. If the gem cannot read PayPal's order, or the order
   shows no completed, pending or partly refunded capture, settling fails.
   Before 6.0.4 that event is dropped at once. From 6.0.4, Spree's job retries
   it five times with backoff and then raises, so the queue backend's own
   retries apply too (Sidekiq's default is 25 more over about three weeks). A
   capture PayPal declined is then read, and reported as an error, on every
   attempt. The storefront's confirm step, or a later PayPal event, settles the
   payment instead.
2. **Check PayPal for captures still pending** (an eCheck, say). Under 5.x a
   pending capture was recorded as a completed payment. After the upgrade the
   gem ignores later PayPal events for checkouts settled under 5.x, so if
   PayPal denies or reverses one of those captures, Spree won't change. Handle
   any that fail by hand.
3. **A source's profile id can change.** A PayPal wallet with no PayPal account
   id is now keyed by the cart's (or order's) prefixed id instead of the order
   number. Such a source isn't reused, and a new one is created.

## Logging

The PayPal SDK logs one line per request and one per response: the method, URL,
status and content type, never bodies or headers. The gem sends these lines to
the Rails log at `debug`, prefixed `[spree-paypal_merchant]`, so a production
log at `info` leaves them out. To see them, set the log level to `debug`.

## Known limitations

- PayPal treats HUF and TWD as zero-decimal currencies, but Spree formats them
  with two decimals, so those currencies aren't supported.
- Multi-seller checkouts, where one payment covers several orders, aren't
  tested.
- **Before Spree 6.0.4:** if the storefront confirms the payment but never
  completes the cart (the buyer closes the tab between the two calls), PayPal's
  later `COMPLETED` event doesn't place the cart. Spree's webhook placed a cart
  only when it was what settled the payment, so the payment sits on an unplaced
  cart and the order has to be placed by hand. Spree 6.0.4 places the cart from
  that event ([spree/spree#15133](https://github.com/spree/spree/pull/15133)).
- If the webhook settles first and completing the cart then fails (stock, a
  validation, tax), Spree rolls the payment back with it. Before Spree 6.0.4 the
  one-shot event is then dropped. From 6.0.4 it is retried: five times by
  Spree's job, then by the queue backend (see "Webhooks are one-shot before
  Spree 6.0.4" above). That recovers a passing failure such as a lock timeout.
  A lasting one, such as stock, keeps failing until the retries run out, and a
  late retry can place the cart once the cause is gone. Either way, the
  storefront's confirm call settles the payment instead.

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

The PayPal mark (`lib/spree/paypal_merchant/paypal-mark.svg`) is PayPal's
trademark, included only to identify the payment method in the Spree
dashboard, and is not covered by this gem's license.
