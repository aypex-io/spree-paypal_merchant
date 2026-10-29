# Changelog

## 6.0.0

Ports the gem to Spree 6. The major version tracks Spree's. Spree 5.6 stays
on 5.2.x, on the `5-2-stable` branch. To upgrade, see "Upgrading from 5.2" in
the README.

The storefront contract is unchanged. The Store API type is still
`paypal_merchant`, and the payment session's `external_data` and the payment
method's `public_preferences` keep their keys.

### Requirements

- Spree `~> 6.0` and Ruby 3.3 or newer.
- The `spree_admin` dependency is gone. Spree 6 has no Rails admin; its
  dashboard builds the settings form from the gateway's preferences.
- `faraday` (`~> 2.0`) and `net-http-persistent` (`~> 4.0`) are declared. The
  gem uses both directly; before, they came only through `paypal-server-sdk`.

### Checkout

- Sessions belong to the cart. The amount is the cart total less store
  credit and gift cards. A zero amount raises `Spree::Core::GatewayError`.
- A session's amount can't change once its PayPal order exists. Updating a
  session with a different amount raises `Spree::Core::GatewayError` (a 422
  from the Store API) telling the storefront to create a new session, and
  `external_data` sent by the client is not stored. The payment records the
  amount PayPal captured, not the session's. Before, a client could change the
  amount, and a cart with store credit could be placed as paid in full while
  PayPal took less and the store credit went unspent.
- A payment source Spree refuses no longer blocks settlement. Spree keeps a
  source's profile id unique per source type, not per payment method, so a
  PayPal account that already had a source under another PayPal method (a
  second store, a recreated method) made settlement fail after PayPal took
  the money, and every retry failed the same way. The payment now settles
  without a source, and the refusal is logged.
- The storefront's confirm call and PayPal's webhook settle through Spree 6's
  shared path, in either order, and produce one payment. A webhook that arrives
  first reads PayPal's order, creates the payment and completes the cart.
- Settlement reads the capture, not the order. PayPal can report an order as
  `COMPLETED` whose capture was declined, as can happen with Card Fields.

  | Capture status | Result |
  |---|---|
  | `COMPLETED` | A captured payment |
  | `PENDING` | A pending payment; the `COMPLETED` event completes it later |
  | `DECLINED`, `FAILED`, none | The session fails; no payment is created |

  5.2.0 treated a pending capture as paid.
- `PAYMENT.CAPTURE.PENDING` (an eCheck, say) leaves the Spree payment pending.
  `PAYMENT.CAPTURE.COMPLETED` completes it.
- A webhook settles only when PayPal's order shows the capture `COMPLETED`,
  `PENDING` or `PARTIALLY_REFUNDED`. If PayPal's order can't be read, or shows
  none of these, the event is dropped. Spree does not retry it and PayPal does not resend it. See the
  README.
- `CHECKOUT.ORDER.APPROVED` is ignored. An approved order holds no capture.
- A webhook for a checkout settled under 5.x is ignored, so it can't create a
  second payment.
- A session that can no longer be used is never captured. Confirming one that
  was canceled or failed, or whose cart is already a placed order, is refused.
  This stops a stale browser tab from paying twice.
- Creating a session cancels the cart's earlier open PayPal sessions. It
  raises if one of them is already completed.
- If a capture gets no clear answer from PayPal, the session stays open. A
  retry reads the order first, so a capture that went through is settled, not
  repeated.
- PayPal captures at checkout, whatever the store's default capture method is.
  A payment method whose own capture method is `on_dispatch` or `manual` is
  refused. The gateway's capture method is always `checkout`, so a store that
  defaults to `on_dispatch` or `manual` never captures a PayPal payment on
  dispatch, and never ships an unpaid PayPal order as one left for staff.
- Canceling a payment session is refused while PayPal's capture is `PENDING`,
  `COMPLETED` or `PARTIALLY_REFUNDED`, because money has moved or is on its
  way. Otherwise it cancels.
- The gateway customer profile is looked up by the owner's customer. An owner
  with no customer (a guest) gets none.

### Refunds and cancels

- A refund reads the capture id from the payment. A payment taken on 5.x
  refunds as before, through its response code.
- Refund amounts follow the currency's decimals, so a yen refund has none.
- When a refund's outcome is unknown (a timeout or connection error), the
  refund fails with a message telling the admin to check PayPal before
  retrying. PayPal may have issued it.
- A refund that PayPal reports as `FAILED` or `CANCELLED` fails. A `PENDING`
  refund is recorded.
- Canceling a completed payment refunds it through Spree's refund workflow,
  unless told to keep the money.
- Void and cancel refuse a payment PayPal may still complete (checkout,
  pending or processing state), with a "still processing" message. Capture
  settles it as PayPal did, or refund it once PayPal completes it.
- Capture in the dashboard reads PayPal and never captures again. A
  `COMPLETED` capture completes the payment, and a denied or declined one fails
  it. While PayPal is still processing the capture, or can't be read, Capture
  says so and leaves the payment pending, so it can be pressed again. It takes
  the whole payment only, since PayPal captured it all at checkout.
- Spree's checkout processing can't authorize or purchase with this gateway.
  It fails, saying PayPal payments are taken through a payment session.
  Before, it raised `ActiveModel::UnknownAttributeError`.
- Canceling an order with Spree's default (`refund_payments: false`) marks a
  completed PayPal payment void in Spree while PayPal keeps the money. Refund
  it before canceling, or refund it in PayPal. A failed, void or invalid payment cancels in Spree
  with no PayPal call.
- Void always fails. PayPal payments are captured at checkout, so there is
  nothing to void: refund the payment instead.

### Order payload

- Every discount counts, promotion and manual.
- A free-shipping discount goes in PayPal's `shipping_discount`.
- Fees go in `handling`.
- Amounts are rounded with Spree's currency rules, so a unit price with four
  decimals is sent with the currency's own.
- Line items are left out when they don't add up to the item total. The buyer
  sees no itemised list in PayPal for that order only. With two-decimal prices
  it never happens.
- When the breakdown can't balance, or has a negative figure, only the amount
  is sent.
- The breakdown still sends only `additional_tax_total`.

### Timeouts and retries

- Every Orders and Payments API request has a 15-second timeout. The
  gem's own webhook-verification and token requests time out after 5 seconds
  to connect and 10 to read.
- PayPal reads (GET) are retried up to 3 times. Only GET and PUT are
  retried, and the client says so explicitly.
- Creating, capturing and refunding are never re-sent automatically.
- A PayPal server error whose body isn't JSON (an HTML 502 page, say) is
  treated like a timeout: PayPal may have acted. A refund fails with the
  message to check PayPal before retrying, a confirm leaves the session open,
  and Capture leaves the payment pending. Before, the SDK's `TypeError`
  escaped, and the refund failed with a generic error.
- The webhook signature check treats more transient failures as a failed
  check: a reset connection, a TLS error, a broken HTTP exchange. Spree answers
  401 and PayPal sends the event again. The Card Fields token request handles
  the same failures by creating the session without a token.
- A PayPal error with no message of its own is reported with PayPal's issue
  descriptions.

### Payment sources

- The PayPal, Apple Pay and card sources store their fields in `metadata`
  (Spree 6 merged `private_metadata` into it). The accessors keep their names.
- A PayPal wallet with no PayPal account id is keyed by the cart's (or
  order's) prefixed id instead of the order number, so a 5.x source of that
  kind isn't reused.

### Removed

- The 5.x checkout flow: `Spree::PaypalMerchant::Order`, `CreatePayment`,
  `CaptureOrder`, the order's `paypal_id`, and the gateway's `find_order`. It
  had no routes. The gateway's `authorize`, `purchase` and `capture` are
  rewritten for Spree 6 (see "Refunds and cancels").
- The ERB admin views and the `*_partial_name` hooks.
- `Spree::PaypalMerchant::Base`, an abstract model class nothing inherits from
  any more.
- The `spree_paypal_merchant_orders` table stays, and no migration drops it in
  this release.

### Known limitations

- PayPal treats HUF and TWD as zero-decimal currencies, but Spree formats them
  with two decimals, so those currencies aren't supported.
- Multi-seller checkouts, where one payment covers several orders, aren't
  tested.
- A payment the storefront confirmed on a cart it never completed isn't
  placed by PayPal's later webhook. It has to be placed by hand.
- If the webhook settles first and completing the cart then fails, Spree rolls
  the payment back and the event is dropped. The storefront's confirm call
  settles it instead.

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
