# Twilio setup (platform operator)

All shops send through the platform's single Twilio account
(`TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` function secrets). A shop's
`shops.sms_from_number` is typed in by the shop's owner/admin on the SMS
settings page, so on its own it proves nothing: the `messaging` function only
**sends from** a number, and only **routes replies and STOP/START** received
on it, when the platform has bound that number to the shop in Twilio.

The binding is the number's inbound webhook URL, which only the platform
operator can set.

## Provisioning a number for a shop

1. Buy (or port) the number in the platform Twilio account. Do **not** add it
   to a Messaging Service (a service's inbound settings would replace the
   number's own webhook; if you must, set the service to "Defer to sender's
   webhook").
2. Phone Numbers -> Manage -> Active numbers -> the number -> Messaging
   configuration -> **A message comes in**: Webhook, HTTP POST,

   ```
   https://<PROJECT_REF>.supabase.co/functions/v1/messaging?action=twilio_inbound&shop_id=<SHOP_UUID>#rc=3&rp=all
   ```

   - `<SHOP_UUID>` is `shops.id` of the shop the number is for.
   - The base must equal `FUNCTIONS_PUBLIC_URL` when that secret is set
     (local tunnels), otherwise `${SUPABASE_URL}/functions/v1`.
   - `#rc=3&rp=all` are Twilio connection overrides: retry up to 3 times on
     any failure. By default Twilio retries only a connect timeout, so a
     transient 5xx would lose an inbound text or STOP for good. Both
     handlers are idempotent (per MessageSid / forward-only status).
3. Tell the shop the number; they enter it in Settings -> SMS (E.164, e.g.
   `+12055550100`).

Moving a number to another shop: change the `shop_id` in its webhook URL
first, then have the old shop clear the number and the new shop enter it.
Until both sides agree, sends from it fail with "this shop's text number is
not provisioned for it on the platform" and inbound texts to it are
acknowledged but not recorded (logged as `inbound_sms_ignored` /
`number_not_provisioned`).

## What the function checks

- **Outbound** (`process_queue`, staff `send`): before sending, it looks the
  `From` number up in the account (`IncomingPhoneNumbers?PhoneNumber=`, once
  per number per run) and requires that its SmsUrl is this function's
  `twilio_inbound` URL with the message's `shop_id`. Otherwise the message
  fails without contacting the recipient. A lookup outage schedules a retry.
- **Inbound** (`twilio_inbound`): after the X-Twilio-Signature check (over
  the configured URL, with or without the `#...` fragment), the signed
  `shop_id` must be the shop whose `sms_from_number` is the `To` number.
- **Status callbacks** (`twilio_status`): the URL is sent with every message
  as `StatusCallback` (`...messaging?action=twilio_status#rc=3&rp=all`);
  nothing to configure.
- **Twilio 21610** (recipient replied STOP to this number, e.g. a STOP whose
  webhook was lost, or carrier-level opt-out): the customer's SMS opt-out is
  recorded (`sms_opted_out_at`, `sms_opt_in = false`) and their queued texts
  from that shop are cancelled.

## Campaign email unsubscribe

Campaign emails carry `List-Unsubscribe:
<.../functions/v1/messaging?action=unsubscribe&token=<message id>>` and
`List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058, required by
Gmail/Yahoo for bulk senders). A POST to that URL unsubscribes
(`public_unsubscribe`); a GET redirects to the web `/u/<message id>` page.
`messaging` is deployed with `verify_jwt = false`, so no extra setup is needed.
