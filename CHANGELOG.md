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
- A webhook settles only when PayPal's order shows the capture `COMPLETED` or
  `PENDING`. If PayPal's order can't be read, or shows neither, the event is
  dropped. Spree does not retry it and PayPal does not resend it. See the
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
  refused.
- Canceling a payment session is refused while PayPal's capture is `PENDING`
  or `COMPLETED`, because money has moved or is on its way. Otherwise it
  cancels.
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
  pending or processing state), with a "still processing" message. Refund it
  once PayPal completes it. A failed, void or invalid payment cancels in Spree
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

- Every PayPal request has a 15-second timeout.
- PayPal reads (GET) are retried up to 3 times.
- Creating, capturing and refunding are never re-sent automatically.

### Payment sources

- The PayPal, Apple Pay and card sources store their fields in `metadata`
  (Spree 6 merged `private_metadata` into it). The accessors keep their names.
- A PayPal wallet with no PayPal account id is keyed by the cart's (or
  order's) prefixed id instead of the order number, so a 5.x source of that
  kind isn't reused.

### Removed

- The 5.x checkout flow: `Spree::PaypalMerchant::Order`, `CreatePayment`,
  `CaptureOrder`, the order's `paypal_id`, and the gateway's `authorize`,
  `purchase`, `capture` and `find_order`. It had no routes.
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
