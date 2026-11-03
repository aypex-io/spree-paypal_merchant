# Set up PayPal

Connect your PayPal business account to your Spree store in four steps. You
need a PayPal **business** account and admin access to the Spree dashboard. If
PayPal is listed under **Settings → Integrations** in the dashboard, the
extension is installed and you can start.

1. [Create a PayPal app](#1-create-a-paypal-app) and copy its Client ID and
   Secret.
2. [Add PayPal in Spree](#2-add-paypal-in-spree) with those two values.
3. [Add a webhook in PayPal](#3-add-a-webhook-in-paypal) so PayPal tells Spree
   about payments.
4. [Paste the Webhook ID into Spree](#4-paste-the-webhook-id-into-spree) and
   [test a payment](#5-test-a-payment).

## Sandbox or live?

PayPal has two separate environments:

- **Sandbox:** test money and test accounts. Use it on a test store, or before
  you go live.
- **Live:** real money.

Each environment has its own app, its own Client ID and Secret, and its own
webhook. Nothing carries over from one to the other, so you do these steps once
for each. Spree's **Test Mode** switch must match the environment the
credentials came from.

## 1. Create a PayPal app

1. Sign in to the [PayPal Developer Dashboard](https://developer.paypal.com/dashboard/)
   with your PayPal business account.
2. Open **Apps & Credentials** and choose **Sandbox** or **Live** at the top of
   the page.
3. Choose **Create App**. Give it a name you will recognise, such as your store's
   name, and choose the **Merchant** type.
4. On the app's page, copy the **Client ID** and the **Secret**. Keep the Secret
   private: anyone who has it can take payments on your account.
5. Under the app's features, turn on:
   - **Advanced Credit and Debit Card Payments**, to take cards at checkout
     without sending buyers to PayPal. On Live, PayPal must approve your account
     for card payments first.
   - **Apple Pay**, if you want to offer it. See [Apple Pay](#apple-pay).

## 2. Add PayPal in Spree

1. In the Spree dashboard, go to **Settings → Integrations** and open the
   **Payments** tab.
2. On the **PayPal** card, choose **Connect**. If the card shows **Configure**,
   PayPal is already added: choose **Configure** to change it.
3. Fill in the form:

   | Field | What to enter |
   |---|---|
   | **Name** | What buyers see at checkout, for example `PayPal`. |
   | **Description** | Optional. Some storefronts show it to buyers under the payment option, so write it for them. |
   | **When to charge customers** | Leave it on **Use the store setting**. PayPal always takes the payment at checkout, and Spree refuses **On dispatch** or **Manual** for PayPal. |
   | **Client Id** | The Client ID from step 1. |
   | **Client Secret** | The Secret from step 1. |
   | **Webhook signing secret** | Leave it empty for now. You fill it in at [step 4](#4-paste-the-webhook-id-into-spree). |
   | **Test Mode** | On for Sandbox credentials, off for Live. |
   | **Enable Apple Pay** | Offers Apple Pay at checkout. Needs [Apple Pay](#apple-pay) set up in PayPal. |
   | **Enable Card Fields** | Offers card payments at checkout. Needs **Advanced Credit and Debit Card Payments** from step 1. |

4. Save. Spree doesn't check the Client ID and Secret with PayPal when you save.
   A wrong pair shows up at checkout, where PayPal fails to load, so always
   [test a payment](#5-test-a-payment).

## 3. Add a webhook in PayPal

A webhook is an address on your Spree server that PayPal calls whenever a
payment is captured, refunded or reversed. Without it, Spree still records
payments made at checkout, but doesn't hear about anything that happens in
PayPal afterwards, such as a refund you make in PayPal or a payment that clears
later.

### Work out your webhook address

The address is made of your Spree API address and your PayPal payment method's
ID:

```text
https://<your Spree API address>/api/v3/webhooks/payments/<payment method ID>
```

**Your payment method ID.** On **Settings → Integrations**, choose **Configure**
on the PayPal card. The address in your browser now ends in
`?payment_method=pm_…`. The ID is the part that starts with `pm_`, for example
`pm_AbC123xyz`.

**Your Spree API address.** This is where your Spree server answers. It isn't
always your shop's address:

- If your shop runs on Spree's own pages, it is your store's address, for
  example `https://shop.example.com`.
- If you have a separate storefront (a "headless" setup), it is the address
  that storefront uses to reach Spree, for example `https://api.example.com`.
  Ask whoever set up your storefront for its "Spree API URL". To find it
  yourself: open your shop, open your browser's developer tools on the
  **Network** tab, and reload. The requests whose path starts with
  `/api/v3/store/` go to your Spree API address.

Put the two together. For example:

```text
https://api.example.com/api/v3/webhooks/payments/pm_AbC123xyz
```

PayPal only accepts `https://` addresses, and your server must be reachable
from the internet. A test store behind a sign-in page needs an exception for
this address (see [troubleshooting](#paypal-cant-reach-your-store)).

### Add the webhook

1. In the PayPal Developer Dashboard, open your app from step 1. Make sure the
   **Sandbox** or **Live** choice still matches.
2. In the app's **Webhooks** section, choose **Add Webhook**.
3. Paste your webhook address into **Webhook URL**.
4. Under **Event types**, select these six:

   | Event | What Spree does with it |
   |---|---|
   | Payment capture completed (`PAYMENT.CAPTURE.COMPLETED`) | Marks the payment as paid. |
   | Payment capture pending (`PAYMENT.CAPTURE.PENDING`) | Marks the payment as pending until PayPal finishes with it. |
   | Payment capture denied (`PAYMENT.CAPTURE.DENIED`) | Fails a payment that hasn't gone through yet. |
   | Payment capture declined (`PAYMENT.CAPTURE.DECLINED`) | Fails a payment that hasn't gone through yet. |
   | Payment capture refunded (`PAYMENT.CAPTURE.REFUNDED`) | Records a refund you made in PayPal. Refunds made in Spree aren't recorded twice. |
   | Payment capture reversed (`PAYMENT.CAPTURE.REVERSED`) | Cancels a checkout still waiting on that payment. |

   **All Events** works too, because Spree ignores the rest, but choosing only
   these six keeps PayPal's delivery log easier to read.
5. Save. PayPal lists the webhook with its **Webhook ID**, a code such as
   `8PT597110X687430LKGECATA`. Copy it.

## 4. Paste the Webhook ID into Spree

1. Back on **Settings → Integrations**, choose **Configure** on the PayPal card.
2. Paste the Webhook ID into **Webhook signing secret**.

   The help text under that field mentions EasyPost. It's shared with another
   integration, so ignore it: for PayPal, this field holds the **Webhook ID**.
   Spree uses it to ask PayPal whether each delivery really came from PayPal,
   and turns away any that didn't.
3. Save, and check the card's switch is on and shows **Active**.

## 5. Test a payment

Use **Sandbox** first.

1. In the PayPal Developer Dashboard, open **Sandbox accounts**. PayPal creates a
   personal (buyer) test account for you. Use it to pay with PayPal, or pay with
   one of PayPal's test card numbers.
2. Place an order on your store and pay.
3. In the Spree dashboard, open the order. The payment should show as
   **Completed**.
4. In the PayPal Developer Dashboard's event log, the webhook delivery for the
   payment should show as delivered successfully.

When it all works, repeat steps 1 to 4 for **Live**, with **Test Mode** off.

## Apple Pay

1. Turn on **Apple Pay** for your app in the PayPal Developer Dashboard.
2. Register every domain where buyers will see the Apple Pay button, including
   subdomains such as `www`, in PayPal's Apple Pay domain settings.
3. In Spree, turn on **Enable Apple Pay**.

Apple Pay only appears in Safari, on a page served over `https://`.

## Troubleshooting

### PayPal can't reach your store

PayPal's event log shows failed deliveries, or Spree never sees them.

- Check the webhook address: the right API address, `https://`, and the `pm_`
  ID of the PayPal payment method on that store.
- A store behind a sign-in page, such as a test site protected by an access
  service, basic authentication or an IP allow-list, sends PayPal to the
  sign-in page instead. Let `/api/v3/webhooks/payments/` through without a
  sign-in. It's safe to open: Spree checks every delivery with PayPal before
  acting on it.
- A delivery Spree turned away shows as **401** in PayPal's log. Check the
  Webhook ID in Spree matches the webhook PayPal is calling, in the same
  environment (Sandbox or Live).

### Card or Apple Pay options don't show at checkout

- Cards need **Advanced Credit and Debit Card Payments** on the PayPal app (step
  1) and **Enable Card Fields** on in Spree.
- Apple Pay needs the steps in [Apple Pay](#apple-pay), and Safari.

### A sandbox payment stays pending

A sandbox business account may hold payments in a currency it doesn't have
until you accept them. Sign in to [sandbox.paypal.com](https://www.sandbox.paypal.com)
as your sandbox **business** account and accept the payment, or set the account
to accept and convert payments in other currencies. PayPal then sends **Payment
capture completed** and Spree marks the payment as paid.

### PayPal doesn't load at checkout

Check that the Client ID and Secret come from the same app, and that
**Test Mode** matches where you created it: on for Sandbox, off for Live.

## For developers

Installation, how payments settle, refunds and upgrade notes are in the
[README](../README.md).
