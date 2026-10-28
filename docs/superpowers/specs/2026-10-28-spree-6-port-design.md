# Spree 6 port — design

**Status:** proposed · **Target release:** 6.0.0 · **Date:** 2026-10-28

## Intent

`spree-paypal_merchant` 5.2.0 installs on Spree 6.0.0 but every PayPal
checkout fails on it. Spree 6 moved checkout onto carts, settles payment
sessions through one shared path for both the storefront confirm call and
the gateway webhook, consolidated metadata columns, changed the refund and
cancel contracts, and removed the Rails admin. This release ports the gem to
that model so a Spree 6 store can take PayPal (wallet, Card Fields, Apple Pay
via PayPal) exactly as it can on 5.6 today.

The reference implementation is Spree's own Stripe provider
(`spree/providers/stripe` in the Spree monorepo at `v6.0.0`). Where this
document says "as Stripe does", it means that code.

## Goals

- Checkout works on Spree 6 through both settlement routes, in either order:
  the storefront confirm call (`complete_payment_session`) and the PayPal
  webhook (`Spree::Payments::HandleWebhook`). Whichever arrives first settles
  the payment; the other is a no-op. No route can leave money captured with
  no payment or no placed order.
- Refunds and cancellations from Spree 6 (dashboard, API, workflows) reach
  PayPal correctly, including for payments taken before the upgrade.
- The storefront contract does not change: the payment session's
  `external_data` keeps the same keys (`id`, `status`, `client_token`,
  `enable_apple_pay`, `enable_card_fields`, …), the Store API type stays
  `paypal_merchant`, and `public_preferences` stays on the payment method
  serializer. A storefront that works with 5.2.0 works with 6.0.0 unchanged.
- No deprecation warnings under Spree 6.0.0 (Spree's test setup raises on
  them), so the gem keeps working on 6.1, where the deprecated bridges are
  removed.
- CI proves it on a matrix of Spree and Ruby versions.

## Non-goals

- Authorize-now, capture-later (`capture_method` of `on_dispatch` or
  `manual`). The gem captures at checkout, as 5.2.0 does; it refuses the
  other capture methods clearly instead of half-supporting them.
- Special handling for `PENDING` captures (e.g. eCheck, review) beyond what
  Spree 6 already gives an authorized payment: see decision D2.
- Multi-seller ("grouped") checkouts, where one payment covers several
  orders. Single-seller stores are the target; grouped checkouts are not
  tested and may need follow-up work.
- A dashboard plugin (custom settings UI, setup guide panel). Spree 6 builds
  the settings form from the gateway's preferences; that is enough for 6.0.0.
- Dropping the legacy `spree_paypal_merchant_orders` table (see "Legacy
  flow").
- Supporting Spree 5.6 in the same release.

## Anti-goals

- A port that passes tests but can capture a buyer's money without creating a
  payment or completing the order (the webhook-first race).
- Changing anything a storefront depends on.
- Losing the ability to refund orders placed before the upgrade.

## Constraints

- **Versions:** `spree ~> 6.0`, Ruby `>= 3.3`. Drop the `spree_admin`
  dependency (it has no 6.x release). Development: `spree_dev_tools
  >= 1.0.0.beta2`.
- **Public repository:** code, docs, commits and PR text stay generic.
- **Settlement rules from core:** provider I/O happens in
  `prepare_for_settlement!` or before `settle_payment!`, never inside the
  owner lock; `payment_source_for_settlement` and `apply_settlement_metadata`
  must not call PayPal.
- **Payment ↔ session link:** core finds a session's payment through
  `Spree::Payment#response_code == PaymentSession#external_id` (the PayPal
  **order** ID). This is not optional.

## Versioning and branches

- This release is **6.0.0**, matching Spree's major version.
- Before the port merges, cut a **`5-2-stable`** branch from the current
  `main` (`41a65ec`, 5.2.0). Spree 5.6 fixes go there and release as 5.2.x.
- `main` becomes the Spree 6 line.

## Design

### 1. Dependencies, CI, release

- Gemspec: `spree ~> 6.0`; remove `spree_admin`. Keep `paypal-server-sdk ~> 2.3`.
- Gemfile: a `SPREE_VERSION` pin (unset resolves the newest release the
  gemspec allows), as in `spree-fixed_amt_discount`.
- CI: a matrix of Spree `6.0.0` and latest × Ruby `3.3` and `4.0`,
  `fail-fast: false`, lint in its own job, each job printing the versions it
  resolved, a weekly schedule and `workflow_dispatch`. If branch protection
  requires a check by name, add a summary job with that name that passes only
  when lint and every matrix job pass (`if: always()`).
- Remove the Spree 5 compatibility spec and any 5.x-only branches in code.

### 2. Payment session: settle through core

`Spree::PaymentSessions::PaypalMerchant`:

- **Remove** the `find_or_create_payment!` override. Core's version keys the
  payment on `external_id` (the PayPal order ID), creates it on the session's
  owner (cart or order), and handles the confirm/webhook race.
- **`prepare_for_settlement!`**: if `external_data` does not already hold a
  capture with a final status (see D2), fetch the order from PayPal
  (`get_order`, `prefer: return=representation`) and store it in
  `external_data`. Return `self`. This is the step the webhook path relies on;
  today it is a no-op, which is why a webhook-first capture produces no
  payment.
- **`payment_source_for_settlement`**: build the payment source from
  `external_data['payment_source']` via `CreateSource` (no PayPal I/O).
  Return nil when there is no source, as today.
- **`apply_settlement_metadata`**: call `super`, then record
  `paypal_capture_id` (from `external_data`) in `payment.metadata`.
- Keep the read helpers (`paypal_order_id`, `paypal_capture_id`,
  `paypal_payer`, `paypal_payment_source`, `accepted?`).
- Use `owner`, never `order`: during checkout the session belongs to a cart
  and `order` is nil.

### 3. Gateway session lifecycle

`Gateway::PaymentSessions`:

- **`create_payment_session(order:, …)`**: `order:` is the owner (usually a
  cart). Create the session with `owner:` and `customer: owner.customer`.
  The amount is `owner.total_minus_store_credits`.
  - **Zero amount:** raise `Spree::Core::GatewayError` instead of returning
    nil (the API controller calls `.persisted?` on the result), as Stripe
    does.
  - **Capture method:** refuse with `Spree::Core::GatewayError` only when
    the method's own `capture_method` is explicitly `on_dispatch` or
    `manual`; a store-level default never stops PayPal (see D4).
  - **Open sessions:** retire the owner's open PayPal sessions first (see
    D1).
- **`update_payment_session`**: unchanged in behaviour.
- **`complete_payment_session(payment_session:, params: {})`**:
  0. Refuse a session that can no longer be used (see D1).
  1. Fetch the PayPal order.
  2. If it isn't `COMPLETED`, run the existing amount check (refuse a stale
     amount), then capture it.
  3. Store the response in `external_data`.
  4. Read the **capture** status (see D2). If it's `COMPLETED` or
     `PENDING`: `process`, then `settle_payment!(captured:)` (true for
     `COMPLETED`, false for `PENDING`), then create the gateway customer
     profile, then `complete`.
  5. Otherwise (`DECLINED`, `FAILED`, no capture), `fail`.

  It must not complete the order; `Carts::Complete` owns that. PayPal API
  errors still fail the session and raise `Spree::Core::GatewayError`.
- **`cancel_payment_session(payment_session:)`**: implement it. Fetch the
  PayPal order:
  - **`COMPLETED`:** raise `Spree::Core::GatewayError`, because money has
    moved.
  - **Not completed:** cancel the session and return true. With CAPTURE
    intent, no money can move until this gem calls capture.

  A timeout or outage is raised as itself, not as a refusal (core's
  contract).
- **`parse_webhook_event`**:
  - **Stop mapping `CHECKOUT.ORDER.APPROVED`**; return nil. Under Spree 6 an
    `:authorized` action settles and completes the session, which with no
    capture leaves the session completed with no payment.
  - **Keep the other mappings:** `PAYMENT.CAPTURE.COMPLETED` → `:captured`;
    `DENIED`/`DECLINED` → `:failed`; `REVERSED`/`REFUNDED` → `:canceled`.
  - **Keep signature verification as is.**

### 4. Refunds, cancel, void

`Gateway`:

- **Amounts:** `self.accepts_money_amounts = true`, so `credit` receives a
  `Spree::Money`. Without it, Spree 6 sends hundredths and warns, and that
  bridge is removed in 6.1.
- **`credit(money, source, response_code, options)`**: refund the capture.
  - **Capture ID:** take it from the payment's
    `metadata['paypal_capture_id']`. The payment is reachable through the
    refund in `options[:originator]`.
  - **Legacy fallback:** when there is no metadata, use `response_code`
    itself as the capture ID. Payments taken on 5.x stored the capture ID
    there.
  - **Amount:** format it to the currency's decimals with
    `Spree::Money::Rounding.to_currency`.
- **`cancel(response_code, payment = nil, refund: true)`**: as Stripe does.
  - **Completed payment:** refund it through `Spree.refund_create_workflow`
    with `Spree::RefundReason.order_canceled_reason(store)`, unless
    `refund: false`; raise on a failed result.
  - **Not completed:** succeed without calling PayPal. There is no
    authorization to void with CAPTURE intent.
- **`void`**: return a failure that explains PayPal payments are captured at
  checkout and must be refunded.
- **Customer profile:** look up `gateway_customers` by `customer`, not
  `user`, and skip it when the owner has no customer.

### 5. Payment sources

Replace `store_accessor :private_metadata` with `store_accessor :metadata`
on the PayPal, Apple Pay and Card sources (Spree 6 consolidated the two
columns; its migration carries existing values over). Accessor names stay
the same.

### 6. Order presenter (PayPal amount breakdown)

- **Field names:** use Spree 6's names: `delivery_total`, `discount_total`,
  and `owner.customer` where the user was read.
- **Fees:** add `fee_total` to the breakdown, as PayPal's `handling`. Spree
  6's total includes fees, and leaving them out risks PayPal's
  `AMOUNT_MISMATCH`.
- **Tax:** keep sending only `additional_tax_total`, as 5.2.0 does. That is
  already consistent with Spree 6's market-level `tax_inclusive` setting.
- **Decimals:** format every amount to the currency's decimals. Spree 6 unit
  prices can carry four decimals, and PayPal rejects them.

### 7. Legacy flow and admin

- **Delete the pre-session flow:**
  - `Spree::PaypalMerchant::Order`, `CreatePayment`, `CaptureOrder`;
  - the order decorator (`paypal_id` store accessor and the
    `paypal_merchant_orders` association);
  - `Gateway#authorize`, `#purchase`, `#capture` and `#find_order`.

  It has no routes, and it targets `Spree::Order` before placement, which
  Spree 6 no longer has.
- **Keep the table:** the `spree_paypal_merchant_orders` table and its
  migrations stay, and no migration drops it in 6.0.0. A later release can
  drop it once nobody needs its rows.
- **Delete the ERB views:** the admin views and the `*_partial_name` hooks,
  plus the Rails storefront partial. Spree 6 has no Rails admin; the
  dashboard renders settings from preferences.
- **Keep:** the store decorator (`paypal_merchant_gateway`), the payment
  method decorator (scope and `paypal_merchant?`), the serializer decorator
  (`public_preferences`), and gateway registration. Check each still loads
  and behaves on Spree 6.

### 8. Upgrade path for stores

Document in the CHANGELOG and README:

- Bump the gem to `~> 6.0` as part of the Spree 6 upgrade.
- No data migration of the gem's own: STI types are unchanged; Spree's
  migrations move source metadata; old payments refund through the
  `response_code` fallback.
- The webhook in the PayPal dashboard stays the same URL. It no longer needs
  `CHECKOUT.ORDER.APPROVED`.
- Spree 5.6 stores stay on 5.2.x.

## Decisions from design review

Raised by a review of this design. Each is the author's call, made to serve
the goals and anti-goals above; the reasoning is given so it can be
challenged.

- **D1 — Never capture for a session that can no longer be used.**
  - **The gap:** Spree 6's confirm workflow skips only sessions that are
    already completed. `CancelUnusedSessionsJob` cancels a placed order's
    leftover sessions, but with CAPTURE intent PayPal has nothing to void.
    So a stale second browser tab could still capture.
  - **The guard:** `complete_payment_session` refuses with
    `Spree::Core::GatewayError` when the session is canceled or failed, or
    when its owner is already a placed order.
  - **Retire open sessions:** `create_payment_session` retires a cart's
    open PayPal sessions before creating a new one (as Stripe's
    `replace_open_sessions` does). It raises if one of them is already
    completed.
- **D2 — "COMPLETED" means the capture, not just the order.**
  - **Why:** PayPal can report an order as `COMPLETED` whose capture was
    declined, which is common with Card Fields. Settlement must read the
    capture inside the order (`purchase_units[0].payments.captures[0].status`).
  - **The rule:**

    | Capture status | Action |
    |---|---|
    | `COMPLETED` | `settle_payment!(captured: true)` |
    | `PENDING` | `settle_payment!(captured: false)`: Spree 6 keeps the payment pending until the `PAYMENT.CAPTURE.COMPLETED` webhook settles it as captured. This is safer than 5.2.0, which treated a pending capture as paid. |
    | `DECLINED` or `FAILED` | fail the session; no payment is created |

  - **Fetch condition:** `prepare_for_settlement!` fetches the order unless
    `external_data` already holds a capture with a final status.
- **D3 — Don't double-settle sessions completed under 5.x; no data
  migration.**
  - **The risk:** payments from 5.x carry the capture ID in `response_code`,
    so their sessions can't find them through Spree 6's
    `response_code == external_id` link. A late or redelivered
    `PAYMENT.CAPTURE.COMPLETED` webhook would then create a second payment.
  - **The guard:** `parse_webhook_event` returns nil when the session is
    already completed and its owner already has a payment for this method
    whose `response_code` is the event's capture ID.
  - **Why not rewrite old data:** a guard in the gem is reversible;
    rewriting payment rows isn't. Refunds keep the `response_code` fallback
    from section 4.
- **D4 — PayPal captures at checkout regardless of the store's default.**
  - **Why:** Spree 6 falls back to the store-level capture method when the
    payment method has none. Refusing PayPal whenever a store defaults to
    `on_dispatch` would silently switch it off after the upgrade.
  - **The rule:** the gateway always captures at checkout (as 5.2.0 does).
    It refuses only when its own `capture_method` is explicitly set to
    `on_dispatch` or `manual`. The upgrade notes say so.
- **D5 — Send line items only when they add up.**
  - **The problem:** each line's `unit_amount` is rounded to the currency's
    decimals. When `sum(unit_amount × quantity)` doesn't equal `item_total`
    (possible with four-decimal unit prices), PayPal rejects the order.
  - **The rule:** in that case omit the `items` list and keep the amount
    and breakdown, as partial charges already do. The buyer loses the
    itemised list in PayPal for that order only; with two-decimal prices it
    never happens.

## Testing

Write the tests first. Existing specs use VCR cassettes against the PayPal
sandbox. New flows may use cassettes or stubbed `PaypalServerSdk` responses;
that's the builder's choice. The suite must cover:

- **Sessions:**
  - creating a session for a cart (owner is the cart, customer set);
  - zero amount raises;
  - a non-checkout capture method raises.
- **Settlement:**
  - confirm-first: payment created on the cart, keyed on the PayPal order
    ID, capture ID in metadata, session completed, order not placed by the
    gateway;
  - webhook-first: `prepare_for_settlement!` fetches the order, then
    settlement and cart completion happen;
  - both routes, in either order, produce exactly one payment;
  - an `APPROVED` webhook does nothing.
- **Refunds and cancels:**
  - a refund reads the capture ID from metadata;
  - a refund of a 5.x payment uses `response_code`;
  - JPY amounts;
  - cancel refunds through the workflow, and respects `refund: false`;
  - `cancel_payment_session` raises on a completed order and cancels
    otherwise.
- **Presenter:** fees in the breakdown, four-decimal unit prices, renamed
  totals; items omitted when they don't reconcile (D5).
- **Review decisions:**
  - D1: confirm refuses a canceled or failed session and a placed owner;
    creating a session retires open ones and raises if one is completed.
  - D2: a `COMPLETED` capture settles as captured; `PENDING` settles as
    authorized and a later capture webhook completes it;
    `DECLINED`/`FAILED` fails the session with no payment, on both routes.
  - D3: a capture webhook for a session completed under 5.x creates no
    second payment.
  - D4: a store-level `on_dispatch` default doesn't stop PayPal; the
    method's own `on_dispatch`/`manual` is refused.
- **Payment sources:** metadata accessors round-trip.
- **Clean run:** no deprecation warnings.

Run the full suite on the CI matrix.

## Left to the builder

- Cassettes versus stubs, and how to record new cassettes.
- How to structure the presenter's currency formatting.
- Whether `cancel_payment_session` reuses the completion fetch helper.
- Exact error messages.
- Ordering of the work into commits.
