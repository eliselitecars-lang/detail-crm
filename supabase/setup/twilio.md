# Twilio setup (platform operator)

All shops send through the platform's single Twilio account
(`TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` function secrets). A shop's
`shops.sms_from_number` is typed in by the shop's owner/admin on the SMS
settings page, so on its own it proves nothing. The platform binds a number
to its shop in two places, both set only by the platform operator:

- **In the database:** `public.shop_sms_numbers` (service role only). A
  shop can only save a `sms_from_number` bound to it there (anything else is
  refused with "not provisioned for this shop"), so no tenant can claim
  another shop's number, even before that shop saves it or while it has it
  cleared. A number is bound to one shop at most.
- **In Twilio:** the number's inbound webhook URL. The `messaging` function
  only **sends from** a number, and only **routes replies and STOP/START**
  received on it, when that URL names the shop.

## Each shop is its own A2P brand, campaign and Messaging Service

US carriers only deliver 10DLC (local number) texts sent under a registered
A2P 10DLC brand and campaign; anything else comes back `undelivered`
(Twilio 30034 / 30007). The platform is an ISV sending for many unrelated
businesses, so:

- **The brand is the shop, not the platform.** A2P rules require the brand
  on a campaign to be the business named in its messages. One platform
  campaign carrying many different shop names is non-compliant and can be
  rejected or suspended, which would stop texts for every tenant at once.
- **One Messaging Service per shop, holding only that shop's number(s).**
  Twilio applies Advanced Opt-Out per Messaging Service: a STOP sent to any
  number in a service opts the sender out of every number in it. If shops
  shared a service, a customer who texted STOP to shop A could no longer be
  texted by shop B (even a transactional reminder): shop B's sends would
  fail with 21610, and the function would then record a permanent SMS
  opt-out in shop B (`messaging/optout.ts`) that shop B's staff cannot
  clear (`customers_comms_guard`), although the customer never opted out
  of B. With one service per shop, Twilio's opt-out scope matches the
  database's (opt-outs are per shop and address, `comms_suppressions`).

Never add a shop's number to a service that holds another shop's number or
whose campaign is registered for another brand.

## Provisioning a number for a shop

1. Register the shop for A2P 10DLC (once per shop; Twilio's ISV flow) and
   give it its own Messaging Service:
   - Trust Hub -> Customer Profiles: create a **Secondary Customer Profile**
     for the shop (legal business name, EIN, address, authorized
     representative) under the platform's Primary Customer Profile. A shop
     without an EIN registers as a Sole Proprietor brand instead.
   - Messaging -> Regulatory Compliance -> A2P 10DLC: register the shop's
     **brand** from that profile.
   - Messaging -> Services -> Create: one **Messaging Service for the
     shop**, named so it can be traced back (e.g. `shop <SHOP_UUID> - Shine
     Auto Spa`). Settings:
     - Integration -> Incoming Messages: **Defer to sender's webhook**. This
       is what keeps the number's own webhook (step 3) in charge; any other
       setting replaces it, and the number would stop routing replies/STOPs
       to its shop and fail the sender check below (texts fail with "not
       provisioned").
     - Leave the service's status callback empty: every outbound text
       carries its own `StatusCallback`.
     - Advanced Opt-Out: keep Twilio's default keywords (STOP..., START,
       YES, UNSTOP, HELP). The function mirrors them: STOP-type keywords opt
       the number out of this shop, START/UNSTOP/YES opt it back in.
   - Register the shop's **campaign** on that service: use case covering
     what the shop sends (appointment/customer-care messages, plus
     marketing if it uses campaigns or the follow-up automation), sample
     messages taken from its templates, how customers opt in (they give
     their mobile number when booking or to the shop), and the opt-out /
     help wording. Until the campaign is approved, US texts from its
     numbers are blocked (30034).
2. Buy (or port) the number in the platform Twilio account and add it to
   **that shop's** Messaging Service (Messaging -> Services -> the shop's
   service -> Sender Pool -> Add Senders). The function still sends
   `From` = the shop's number, which is correct for a number in a Messaging
   Service (Twilio applies the service's A2P registration to it).
3. Phone Numbers -> Manage -> Active numbers -> the number -> Messaging
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
   With the service set to defer, this per-number setting is the one that
   applies (check that it still shows after adding the number to the
   service).
4. Bind the number to the shop in the database (SQL editor, as postgres /
   service role):

   ```sql
   insert into public.shop_sms_numbers (phone_number, shop_id)
   values ('+12055550100', '<SHOP_UUID>');
   ```
5. Tell the shop the number; they enter it in Settings -> SMS (E.164, e.g.
   `+12055550100`).

Moving a number to another shop: move it to the new shop's Messaging
Service (never keep it in the old shop's), change the `shop_id` in its
webhook URL, then re-bind it in the database
(`delete from public.shop_sms_numbers where phone_number = '+1...'`, which
also clears it from the old shop, then insert it for the new shop) and have
the new shop enter it.
Until both sides agree, sends from it fail with "this shop's text number is
not provisioned for it on the platform" and inbound texts to it are
acknowledged but not recorded (logged as `inbound_sms_ignored` /
`number_not_provisioned`).

## Numbers no shop uses (release worklist)

The platform pays Twilio every month for every number on its account,
whether or not a shop still uses it. Whenever a number stops being bound to
a shop (the owner releases it, the shop is deleted, or you move it with the
`delete` above), the database logs it in `public.sms_number_releases`
(service role only; phone number, shop id, shop name, time).

- **Numbers bought through self-serve** (`sms-provisioning`, friendly name
  `dcrm-<SHOP_UUID>-...`) need nothing from you: `release_number` gives
  them back to Twilio, and deleting a shop releases its self-serve number and
  Messaging Service right after the shop is gone. If Twilio failed at that
  moment, the daily job below retries.
- **Numbers you bound by hand** are never released automatically: you
  bought them, so you decide (release, or re-assign to another shop).

The daily `detail-crm-sms-releases` job (supabase/setup/cron.sql) calls
`sms-provisioning` `release_worklist`, which checks each logged number
against Twilio and removes the entries that are done (no longer on the
account, or bound to a shop again). What it cannot settle it reports:

- in the function logs as `sms_numbers_awaiting_release` (warn, with the
  count) — check it after deleting a shop that had a number;
- in the answer when you run it yourself:

  ```sh
  curl -sS -X POST "https://<PROJECT_REF>.supabase.co/functions/v1/sms-provisioning" \
    -H "Content-Type: application/json" -H "x-cron-secret: $CRON_SECRET" \
    -d '{"action":"release_worklist"}'
  # {"checked":3,"pending":[{"phone_number":"+12055550100","twilio_number_sid":"PN...",
  #   "shop_id":"...","shop_name":"...","shop_deleted":true,"released_at":"..."}],
  #  "released":1,"pruned":2,"failed":0}
  ```

Every `pending` number is still rented by the platform and bound to no
shop. Release it in the Twilio Console (Phone Numbers -> Manage -> Active
numbers -> the number -> Release; also delete that shop's Messaging Service,
`shop <SHOP_UUID> - ...`) or bind it to a shop again; the next run clears
the entry. `failed` counts numbers Twilio could not be asked about (they are
retried the next day). Read the raw table only for history: it also holds
recent releases that are already done (kept 30 days: they count toward a
shop's limit of 2 self-serve releases per 30 days).

## Migrating from a shared platform Messaging Service

Earlier versions of this guide put every shop's number in one platform
service under one platform campaign. To move off it: register each shop
(step 1), move each number from the shared service's Sender Pool to its
shop's service, then delete the shared service. While numbers were shared,
a STOP to one shop blocked the person at every shop, and sends that failed
with 21610 recorded SMS opt-outs in shops the person never opted out of.
Find those in the logs (`sms_opt_out_recorded` with `source:
twilio_21610`); where the customer never texted STOP to that shop's own
number (no inbound STOP in its `messages`), the operator may clear the
opt-out with service role (`comms_unsuppress(shop_id, 'sms', phone)`;
marketing consent, `sms_opt_in`, stays off until the customer gives it
again). Staff cannot, by design.

## What the function checks

- **Outbound** (`process_queue`, staff `send`): before sending, it looks the
  `From` number up in the account (`IncomingPhoneNumbers?PhoneNumber=`, once
  per number per run) and requires that its SmsUrl is this function's
  `twilio_inbound` URL with the message's `shop_id`. Otherwise the message
  fails without contacting the recipient. A lookup outage schedules a retry.
- **Inbound** (`twilio_inbound`): after the X-Twilio-Signature check (over
  the configured URL, with or without the `#...` fragment), the signed
  `shop_id` must be the shop the `To` number is bound to in
  `shop_sms_numbers`. Routing follows that binding, not `sms_from_number`,
  so replies and STOPs still land while a shop has cleared its sending
  number (e.g. to pause texting).
- **Status callbacks** (`twilio_status`): the URL is sent with every message
  as `StatusCallback` (`...messaging?action=twilio_status#rc=3&rp=all`);
  nothing to configure.
- **Opt-in keywords** (`twilio_inbound`): START and UNSTOP are applied by
  `record_inbound_sms`; YES (also a Twilio opt-in keyword) is applied by the
  function with the same `comms_unsuppress`, and only when it is the newest
  inbound text from that number, so a late webhook retry never undoes a
  later STOP.
- **Twilio 21610** (recipient replied STOP to this number, e.g. a STOP whose
  webhook was lost, or carrier-level opt-out): the customer's SMS opt-out is
  recorded (`sms_opted_out_at`, `sms_opt_in = false`) and their queued texts
  from that shop are cancelled.

## Campaign email unsubscribe

Marketing emails (campaigns and the promotional `follow_up` template) carry
`List-Unsubscribe:
<.../functions/v1/messaging?action=unsubscribe&token=<unsubscribe token>>` and
`List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058, required by
Gmail/Yahoo for bulk senders). The token is the email's random
`messages.unsubscribe_token` — never its message id. A POST to that URL
unsubscribes (`public_unsubscribe`); a GET never unsubscribes (link scanners
follow GETs) and redirects to the web app's `/u/<token>` page. The footer
link in every marketing email (`{{unsubscribe_link}}`, rendered by
`launch_campaign` / `enqueue_customer_template`) points at that same page.
Transactional email has no unsubscribe token.

**The web app must serve `/u/:token`** (public, no sign-in): it shows the
shop name and a "Unsubscribe" button that calls the `public_unsubscribe`
RPC (`p_token` = the token; granted to `anon`; `true` = done, `false` =
invalid link) and then confirms. Without that route the visible link and any
mail client that opens the List-Unsubscribe URL in a browser land on the
404 page, and only RFC 8058 one-click (Gmail/Yahoo) works; CAN-SPAM needs a
working opt-out in every campaign email. The function cannot serve the page
itself: Supabase rewrites `text/html` answers to GET requests on the default
`*.supabase.co` domain to `text/plain`.
`messaging` is deployed with `verify_jwt = false`, so no extra setup is needed.
