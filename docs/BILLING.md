# Shop subscription billing (operator guide)

How you, the platform operator, charge detailing shops a recurring
subscription for Detail CRM: where plans and prices live, how to turn billing
on, how to give a pilot shop free access, and what happens when a shop stops
paying. No code changes are needed for any of it.

Nothing about your plans is written into the app. Plan names, prices, team
size limits, the trial length and taxes all come from **your** Stripe account
and two deploy settings. Examples below use placeholders such as
`<your monthly price>`: put in your own numbers.

---

## 1. Two separate money flows

Detail CRM moves money in two unrelated ways. Keep them apart in your head
and in Stripe.

| | **You charge shops** (this guide) | **Shops charge their customers** |
|---|---|---|
| What | the shop's Detail CRM subscription | invoices, deposits, gift cards, customer memberships |
| Stripe account | **your platform account** | **each shop's own** connected Express account (Stripe Connect) |
| Set up by | you, in your Stripe Dashboard (Products, Prices, Customer Portal) | each shop owner, in Settings -> Payments (Connect onboarding) |
| Money goes to | you | the shop (minus your optional platform fee, `PLATFORM_FEE_BPS`) |
| Where the shop pays / manages | Settings -> Billing in the web app (Stripe Checkout, Stripe Customer Portal) | their customers pay on public invoice, booking and portal pages |
| Webhook endpoint | platform endpoint ("Events on your account") -> `billing-webhook`, secret `STRIPE_BILLING_WEBHOOK_SECRET` | Connect endpoint ("Events on Connected accounts") -> `stripe-webhook`, secret `STRIPE_WEBHOOK_SECRET` |
| Server functions | `billing`, `billing-webhook` | `stripe-connect`, `payments`, `stripe-webhook` |
| Refunds and disputes | you, in your Stripe Dashboard | the shop, in its Express dashboard / the web app |

Rules that keep them apart:

- Create subscription plans only in **your platform account**, never on a
  shop's connected account.
- Only mark Products as plans (`detailcrm_plan = true`, section 3) when they
  are Detail CRM subscriptions. A shop's customer memberships are a separate
  feature (Settings -> Memberships) that lives on the shop's own account.
- The platform fee and subscriptions are independent: you can use either,
  both or neither.

---

## 2. How it works

- Billing is **off** until you turn it on (`BILLING_ENABLED`, section 5).
  While it is off every shop can use everything, exactly as before.
- Your plans are Stripe Products + Prices. The app copies them into its own
  plan list automatically (on every change in Stripe, once a day, and at
  every deploy).
- Only the shop **owner** can subscribe, switch plans, update the card or
  cancel, on the web: Settings -> Billing opens Stripe Checkout to subscribe
  and the Stripe Customer Portal to manage. Admins and managers can see the
  status without buttons. Technicians never see prices or billing details.
- The iPhone app shows a neutral status line only (for example "This shop's
  subscription is inactive. Creating new jobs, quotes, invoices and customers
  is paused."). It has no prices, no plan names and no purchase buttons or
  links, as Apple's App Store rules require (guidelines 3.1.1 / 3.1.3).
  Owners subscribe on the web.
- Stripe is the source of truth. Every subscription change reaches the app
  through the platform webhook; nothing in the apps can mark a shop as paid.
- The web app has a public **pricing page** at `<APP_BASE_URL>/pricing`
  listing your plans (from the same plan list; section 6.1). While billing is
  off, or before any plan is synced, it says pricing is coming soon and shows
  no numbers.

States a shop can be in:

| State | Meaning | Can create new work? |
|---|---|---|
| `active` | billing is off, or the subscription is paid (also: the subscription ended, but the last period it was paid for has not) | yes |
| `trialing` | inside the free trial | yes |
| `past_due` | a renewal payment failed; Stripe is retrying | yes (until Stripe gives up) |
| `comped` | you made the shop free (section 7) | yes |
| `lapsed` | trial over without a subscription, or the subscription ended and the last period it was paid for is over | no: see section 8 |

The one date that decides how long an ended subscription keeps access is
`shop_billing.paid_through`, the end of the last period the shop was in
good standing for. While the subscription is active or in a trial it
follows the period end; once a renewal fails (`past_due`, then `unpaid` or
`paused`) it stays at that renewal date; cancelling leaves it as it is.
Stripe's own `current_period_end` is not used for this: Stripe moves it on
to the next period at renewal, before that period is paid.

---

## 3. Create your plans in Stripe

Do this in **test mode** first (a staging project with `sk_test_` keys), then
repeat it in live mode: Stripe keeps test and live Products separately.

### 3.1 One Product per plan

Stripe Dashboard (your **platform** account) -> **Product catalog** ->
**Add product**:

1. **Name**: what shops see on the plan card, for example `<Plan name>`.
2. **Description** (optional): one line under the name.
3. **Metadata** (the Product's metadata section -> Add metadata). Keys and
   values are typed exactly as shown:

| Key | Value | Required | Example |
|---|---|---|---|
| `detailcrm_plan` | `true` | **yes**: only Products with it become plans | `true` |
| `max_members` | the most team members a shop on this plan may have, as a whole number. Counts active members **and** pending invites, the owner included. Leave the key out for no limit | no | `<your team size limit>` |
| `features` | short keys, separated by commas, listed on the plan card (lowercase letters, digits, `_`, `-`) | no | `<feature_key>,<another_key>` |
| `sort` | a whole number; plans are shown lowest first (then by price) | no | `1` |

Notes:

- `features` only **describe** a plan; they do not switch parts of the app on
  or off. The one limit the app enforces per plan is `max_members`.
- An invalid value never blocks the sync: a `max_members` that is not a
  positive whole number is treated as **no limit**, an invalid feature key is
  left out, and an invalid `sort` becomes `0`. Each one is reported as a
  warning (section 3.4), so check the deploy log after editing metadata.
- Archiving a Product, or removing its `detailcrm_plan` key, removes the plan
  from the plan cards. Shops already subscribed to it keep their
  subscription until they switch or you change it in Stripe.

### 3.2 Prices

On the Product, **Add price** once per billing period you offer:

- **Recurring**, billing period **Monthly** or **Yearly** (every N months or
  years works too). Weekly and daily prices are not supported and are
  skipped.
- **Standard pricing** (a fixed amount per unit): for example
  `<your monthly price>` per month and `<your yearly price>` per year, in your
  currency. Usage-based, tiered, package and "customer chooses the price"
  prices are skipped.
- Each active Price is one option on the billing page, shown with the
  Product's name. A Product with a monthly and a yearly Price gives two
  options.

Stripe Prices cannot be edited. To change what new subscribers pay, add a new
Price and **archive** the old one: the old option disappears for new
checkouts, and existing subscribers stay on the price they have until they
switch plans in the portal or you migrate them in Stripe.

### 3.3 Example (placeholders)

| Product name | Metadata | Prices |
|---|---|---|
| `<Plan A name>` | `detailcrm_plan=true`, `max_members=<limit A>`, `features=<keys A>`, `sort=1` | `<your monthly price A>` / month, `<your yearly price A>` / year |
| `<Plan B name>` | `detailcrm_plan=true`, `features=<keys B>`, `sort=2` (no `max_members`: unlimited) | `<your monthly price B>` / month |

### 3.4 How plans reach the app

The plan list in the app is refreshed:

- right away, whenever a Product or Price changes (the platform webhook);
- every day at 06:35 UTC (a scheduled job, as a safety net);
- at every backend deploy while billing is on. The deploy log prints
  `billing plans synced from Stripe: N active price(s), M deactivated`, then
  one `WARN` line per Price that was skipped (with the reason: for example
  `unsupported_interval`, `metered_price`, `tiered_price`, `no_fixed_amount`)
  and per metadata value that was ignored.

To refresh by hand (for example after fixing metadata), re-run the backend
deploy, or call the function with your cron secret:

```bash
curl -sS -X POST "https://<project ref>.supabase.co/functions/v1/billing" \
  -H "Content-Type: application/json" -H "x-cron-secret: <CRON_SECRET>" \
  -d '{"action":"sync_plans"}'
# -> {"upserted": ..., "deactivated": ..., "skipped": [...], "warnings": [...]}
```

---

## 4. Customer Portal and Checkout settings (Stripe Dashboard)

The owner's **Manage billing** button opens Stripe's Customer Portal with your
account's default portal settings. Stripe refuses to open it until they have
been saved once, **separately in test mode and in live mode**. Until then the
button answers "Billing management is not set up yet. Please contact
support."

Stripe Dashboard -> **Settings** -> **Billing** -> **Customer portal**:

1. **Payment methods**: allow customers to update them.
2. **Cancellations**: allow, **at the end of the billing period** (the shop
   keeps access until the period it paid for ends).
3. **Subscriptions**: turn on "Customers can switch plans" and add every plan
   Product and Price from section 3 (so owners change plans here; the billing
   page never opens a second subscription). Choose how Stripe prorates.
4. **Invoice history**: on.
5. **Business information**: your support contact, and your terms and privacy
   links (`<APP_BASE_URL>/terms`, `<APP_BASE_URL>/privacy`).
6. **Save**.

Also in your Stripe settings:

- **Failed payments** (Settings -> Billing -> Subscriptions and emails ->
  Manage failed payments): the retry schedule, and what happens when every
  retry fails (cancel the subscription, or mark it unpaid). A shop stays
  usable (`past_due`) while Stripe retries, and the owner gets an in-app
  notification on each failed payment. A retry that succeeds changes
  nothing for the shop. When every retry fails and Stripe cancels the
  subscription or marks it unpaid, the shop **lapses at once**: it was paid
  up to the renewal that failed (`paid_through`, section 2), so the unpaid
  period is not given away, and the retry days were its grace period. After
  a cancellation the owner can choose a plan again in Settings -> Billing.
  A subscription marked unpaid still exists in Stripe, so a new checkout is
  refused (section 6): the owner settles it through **Manage billing**, or
  you cancel it in Stripe so the owner can choose a plan again.
- **Customer emails** (same page): receipts, upcoming renewals, failed
  payments, as you prefer.
- **Discounts**: Checkout accepts promotion codes. Create Coupons and
  Promotion codes in Stripe if you want them; none are needed.
- **Branding** (Settings -> Branding): your name, icon and colours on
  Checkout and the portal.

---

## 5. Trial length and turning billing on

Both are deploy settings: GitHub -> the repository -> **Settings** ->
**Secrets and variables** -> **Actions** -> **Variables** (repository level
or the `production` environment). For a local deploy, export them like the
other inputs ([DEPLOY.md](DEPLOY.md) section 3).

| Variable | Value | Meaning |
|---|---|---|
| `BILLING_TRIAL_DAYS` | a whole number of days, `0` to `730` | free trial for shops; `0` = no trial. Unset = `0` |
| `BILLING_ENABLED` | `true` or `false` | turns subscription billing on or off. Unset = off |
| `BILLING_AUTOMATIC_TAX` | `true` or unset | Stripe Tax at Checkout (section 9). Unset = off: deleting the variable turns it off at the next deploy |

What the trial does:

- A shop created while billing is on starts with a trial of
  `BILLING_TRIAL_DAYS` days. It can use everything without entering a card.
- If the owner subscribes during the trial and at least 48 hours of it are
  left, Checkout keeps the rest of the trial: the first charge happens when
  the trial ends. With less than 48 hours left (Stripe's minimum), the
  subscription starts and is charged right away.
- A shop gets its trial once: a shop that already had a trial on a
  subscription does not get a new one.
- **A person gets the trial once**, not once per shop. The app remembers
  whom it gave a trial to (their account and a one-way hash of their email
  address, with any `+tag` ignored and, for Gmail, dots ignored and
  `googlemail.com` counted as `gmail.com`; the address itself is not
  stored). A
  new shop created by someone who already had a trial starts **without**
  one: it can be viewed but not used for new work until the owner picks a
  plan in Settings -> Billing, and Checkout carries no trial. Deleting the
  old shop, re-creating it under the same web address, or deleting the
  account and signing up again with the same email does not give a new
  trial. Someone who signs up with a different email address does get one:
  if you see that, comp or contact the shop.
- To let someone have another trial (for example a genuine second
  business), delete their record in the Supabase SQL editor, then have them
  create the shop again (or set a trial on the shop yourself):
  `delete from public.billing_trial_grants where user_id = (select id from auth.users where email = '<their email>');`
- **When you turn billing on, every existing shop that never subscribed gets
  a trial of `BILLING_TRIAL_DAYS` days from that moment.** With `0` days,
  those shops lapse **immediately**. Comp your pilot shops first (section 7)
  or set a trial.

Turning it on, in order:

1. Plans created (section 3) and the Customer Portal saved (section 4), in
   the same mode (test or live) as the project's Stripe keys.
2. Pilot shops comped (section 7).
3. Set `BILLING_TRIAL_DAYS`, then `BILLING_ENABLED` = `true`.
4. Run **deploy-backend** with ***stripe_webhooks*** checked, with *dry_run*
   first and then without it (the first time billing is on; later deploys
   leave *stripe_webhooks* unchecked and keep the stored secret). The deploy:
   - creates the **platform** webhook endpoint for `billing-webhook` with
     exactly the billing events and stores its signing secret as
     `STRIPE_BILLING_WEBHOOK_SECRET` (never printed);
   - applies the settings (`set_billing_config`) and reads them back:
     `billing: ON, trial N day(s)`;
   - syncs the plans from Stripe: `billing plans synced from Stripe: ...`;
   - ends with the smoke checks, which must say `0 failed`.

   Without *stripe_webhooks*, create the endpoint yourself
   ([functions README](../supabase/functions/README.md#stripe-platform-billing-webhook))
   and set the secret `STRIPE_BILLING_WEBHOOK_SECRET` in GitHub. With
   `BILLING_ENABLED=true` a deploy stops in its second step, before anything
   changes, while that secret is neither an input nor already stored in the
   project.
5. Check it end to end (section 10).

What each part does, if you need to check or do it by hand:

| Part | What runs | By hand |
|---|---|---|
| The switch and the trial | `public.set_billing_config(p_enabled, p_trial_days)` (service role only) writes `platform_config` `billing_enabled` / `billing_trial_days`; switching on starts the trial of every shop that never subscribed | Supabase SQL editor: `select public.set_billing_config(true, <trial days>);` then set the same values in the GitHub variables, or the next deploy stops (Safety, below) |
| The plan list | the `billing` function's `sync_plans` (with the `x-cron-secret` header) copies every active recurring Price of a Product with `detailcrm_plan=true` into the app's plan list and retires the rest | the `curl` in section 3.4 |
| Subscription changes | Stripe's **platform** webhook ("Events on your account") -> `<project URL>/functions/v1/billing-webhook`, signed with `STRIPE_BILLING_WEBHOOK_SECRET`, events `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`, `product.created`, `product.updated`, `product.deleted`, `price.created`, `price.updated`, `price.deleted` | Stripe Dashboard -> Developers -> Webhooks -> Add endpoint (not a Connect endpoint), then the secret in GitHub |
| Web and iPhone | read the standing with `shop_entitlement`; nothing to deploy | - |

The iPhone app shows a neutral status only (section 2); it never offers a
plan, a price or a way to buy, so it needs no change and no App Review note
beyond the one in [LAUNCH.md](LAUNCH.md) section 6.

Safety: a deploy where `BILLING_ENABLED` (or `BILLING_TRIAL_DAYS`) is **not
set** never changes a project where billing is already on (or has a trial):
it stops and asks you to set the value explicitly. So a local run without the
variables cannot switch billing off by accident.

Turning it off later: set `BILLING_ENABLED` = `false` and deploy. Every shop
is fully usable again. **Stripe keeps billing existing subscriptions**: cancel
them in Stripe if you stop charging. The platform endpoint and its stored
signing secret are left in place so subscription changes keep reaching the
app.

---

## 6. Where shops subscribe

Only the owner, on the web: **Settings -> Billing** -> choose a plan ->
Stripe Checkout (card details are entered on Stripe's page, never in the
app) -> back to Settings -> Billing, which shows the result once Stripe has
confirmed it (usually a few seconds). From then on **Manage billing** opens
the Customer Portal (switch plan, update the card, cancel, invoices).

**One subscription per shop.** A shop is never meant to pay twice:

- **Choose plan** is offered only while the shop has no live subscription,
  and the server refuses a checkout (`409 already_subscribed`) whenever
  Stripe already has a subscription for the shop's billing customer that
  can still bill, even one the app has not heard of yet because its webhook
  has not arrived. The owner sees "This shop already has a subscription. Use
  Manage billing to change or cancel it." or, while a payment is still being
  confirmed, "A payment for this shop's subscription is still being
  confirmed. Refresh in a few minutes, or use Manage billing."
- A checkout link stays payable for **about an hour** (60 to 70 minutes;
  Stripe's own default would be 24 hours), and starting a new checkout
  expires the shop's older open ones, so at most one payable link exists.
- If two subscriptions start anyway (two links paid at almost the same
  moment), the platform webhook keeps the **oldest** and automatically
  **refunds and cancels the newer one** (every payment it took, refund
  reason "duplicate"). The function log shows
  `billing_duplicate_subscription_cancelled` with the amount refunded. A
  second subscription you create yourself in the Stripe Dashboard (without
  the checkout's `shop_id` metadata) is never touched: it is only logged
  (`billing_event_ignored`, reason `duplicate_subscription`), and you refund
  or cancel it in Stripe.

**The billing customer follows the shop owner.** Each shop has one
platform Stripe customer, and Stripe sends the shop's receipts, renewal
notices and failed-payment emails to that customer's email, so it always
carries the **current owner's** email (and `metadata.owner_user_id`):

- **Choose plan** (checkout) and **Manage billing** (portal) update it first
  when the owner, or the owner's email, changed since it was last written;
- after **Transfer ownership** the web and iPhone apps call the `billing`
  function's `sync_customer`, which readdresses it to the new owner at once;
- the daily `sync_customers` job (`detail-crm-billing-sync-customers`,
  supabase/setup/cron.sql) catches every ownership change the apps did not
  report (a customer whose `owner_user_id` is not the shop's current owner).
  An owner who only changed their own sign-in email is picked up at their
  next checkout, Manage billing or `sync_customer`.

A Stripe failure while readdressing never blocks checkout or managing
billing (`billing_customer_contact_sync_failed` in the function log); the
next one tries again. Invoices Stripe already finalized keep the address
they were finalized with. Do not change the customer's email in the Stripe
Dashboard: the next readdress writes the owner's back.

### 6.1 What the web app shows

Everything below is read from the server at run time
(`shop_entitlement`, `public_billing_plans()`, `public_billing_offer()`
(0131: the plans plus the trial length), the `billing` function); the web
never has a plan, price, trial length or limit of its own.

| Where | Who | What |
|---|---|---|
| Settings -> **Billing** (`/app/settings/billing`) | owner | status (trial days left in the shop's time zone, plan, renewal or end date, team members used of the plan's limit), the plan cards with **Choose plan** (Checkout) while there is no live subscription, **Manage billing** (Customer Portal) once the shop has had one |
| | admin, manager | the same status, read-only ("Only the shop owner can choose a plan ...") |
| | technician | not listed; the page says "You don't have access" |
| | everyone, billing off | the section is not listed; opened directly it says billing isn't enabled and offers nothing to buy |
| Back from Checkout (`?checkout=success`) | owner | "Confirming your subscription with Stripe..." while it re-reads the status every 2 seconds, then "Thanks! Stripe confirmed your subscription." If the webhook has not arrived after 60 seconds it stops and says so, with **Check again** (section 11: the webhook). `?checkout=cancelled`: "Checkout was cancelled. No subscription was started." |
| Banner above every staff page | owner | the in-app trial ends within 7 days ("Choose a plan to keep creating new work"), a payment problem (`past_due`); both dismissible for the browser session, with **Go to Billing** |
| | everyone | the shop is lapsed: "This shop's subscription is inactive, so new records can't be created right now. You can still view everything." Owner: **Go to Billing**; others: "Ask the shop owner to renew it." Not dismissible, never blocks reading |
| A refused action (section 8) | everyone | the server's sentence as it is |
| | owner | plus a **Go to Billing** link (forms and dialogs) or action (error pop-ups) |
| Notifications | owner | "Subscription payment problem" opens Settings -> Billing |
| `/pricing` (public) | anyone | the plans with price, period, team size and feature keys, the trial length ("14-day free trial for your first shop", from `public_billing_offer()`; nothing when no trial is set), and **Create your shop** (sign-up); "Pricing coming soon" without plans |
| Shop setup (`/app/onboarding`, before the shop exists) | signed-in user | with billing on, a link to `/pricing`, and "Your first shop gets a N-day free trial" when this person never had one, or that the trial was already used (this shop starts without one) when they did (`public_billing_offer().trial_available`, once per person) |

Nothing appears while billing is off, while a shop is `active` or `comped`,
or while its standing cannot be read.

---

## 7. Free access for a pilot shop (comp)

A comped shop can use everything without a subscription until the date you
choose (or forever). Run in the Supabase Dashboard -> **SQL editor**:

```sql
-- find the shop (its booking link is /book/<slug>)
select id, name, slug from public.shops where slug = '<booking slug>';

-- free forever
select public.billing_set_comp('<shop id>', 'infinity');

-- free until a date (UTC)
select public.billing_set_comp('<shop id>', '<yyyy-mm-dd>T00:00:00Z');

-- end the comp now (the shop then needs a subscription or a live trial)
select public.billing_set_comp('<shop id>', now());
```

A comp does not touch Stripe. If a comped shop also has a subscription,
Stripe still charges it: cancel that subscription in Stripe if the shop
should be free.

Comp **forever** the shops that must never lapse:

- the **App Review demo shop** ([LAUNCH.md](LAUNCH.md) section 6, "Demo
  account"): Apple's reviewers sign in to it, possibly weeks after you
  created it, and a lapsed shop cannot create records;
- your own pilot, test and internal shops.

---

## 8. What a lapsed shop can and cannot do

Nothing is deleted when a shop lapses, and the owner can renew at any time
from Settings -> Billing.

Still works:

- signing in, and **viewing** everything (customers, jobs, calendar, quotes,
  invoices, reports), and exports;
- **collecting money on existing invoices and deposits** (pay links, card
  payments);
- **finishing existing jobs**;
- **managing billing**: subscribing again, the Customer Portal.

Paused:

- creating new customers, jobs, recurring job series, quotes, invoices and
  campaigns, and sending new messages to customers from staff;
- **online booking** (the public booking page says booking is unavailable);
- **lead forms**: the shop's embedded or linked lead form reads as "form not
  found", so no lead is captured and no lead auto-reply goes out;
- **online membership sign-ups**: the public membership page lists no plans;
- **online gift card sales**: the public gift card page shows sales as off;
- **selling memberships and issuing gift cards from staff** (`PT402`, below).
  Store credit a referral earns when a job is completed, and refunds back
  onto an existing gift card, keep working;
- automations and campaign sends (reminders, follow-ups, document
  follow-ups);
- **inviting team members**: no new invites, and no invite emails (new or
  resent). An invite that was already sent can still be accepted;
- **buying a self-serve text number and registering 10DLC** (Settings ->
  Text messaging). The platform pays Twilio for these, so they need a
  **paid** subscription (or a comp) even before a shop lapses: a shop on its
  free trial (or a Stripe trial) or `past_due` is refused too ("Self-serve
  text numbers are available once the shop's subscription is paid. Contact
  support to connect a number during the trial.", or, `past_due`, update the
  payment method first). You can connect a number by hand meanwhile
  (supabase/setup/twilio.md). A number the shop already has stays
  connected.

Customers on the public pages never see the subscription sentence below:
they get the page's usual "not available" answer.

People trying a paused action see the server's neutral sentence: "This
shop's subscription is inactive, so new records can't be created right
now." (the database raises SQLSTATE `PT402`, which PostgREST answers with
HTTP 402; the server functions answer `402 payment_required` with the same
sentence). It is worded for the iPhone app too, so it never mentions prices
or buying; on the web the owner also gets a **Go to Billing** link.

Team size: on a plan with `max_members`, inviting or adding (or
re-activating) a member beyond the limit is refused with "This shop's plan
allows N team members." (active members and pending invites count, the owner
included). Accepting an invite that was already sent always works.

Invite emails leave from the platform's own sending address, so they are
limited for every shop, whatever its plan: 20 new invites and 30 invite
emails a day per shop and per person, and a shop on its free trial sends
the standard invitation wording rather than its own `invite` template
(`docs/SPEC.md` §5, `invites`).

### 8.1 Deleting a shop ends its subscription

Only the owner can delete a shop (web: Settings -> Delete shop, typing the
shop's name). The server (`payments` function, `delete_shop`) handles the
shop's platform subscription in three steps, so a deleted shop is never
billed again and a deletion that fails never costs a shop its plan:

1. **Before anything else changes**, every platform subscription of the
   shop that can still bill (the one the app tracks, and any other one
   Stripe has for the shop's billing customer, such as a duplicate not yet
   resolved) is set to end at its period end, so nothing renews. One still
   `incomplete` (nothing paid) is cancelled outright. If Stripe refuses or
   cannot be reached, nothing is deleted and the owner sees "We could not
   cancel the shop's subscription, so nothing was deleted. Try again."
2. If a later step of the deletion fails (for example a card payment is
   still processing), the shop stays and renewal is switched back on for
   every subscription step 1 changed. If even that fails it is logged as
   `platform_subscription_resume_failed`, and the owner can resume renewal in
   the Customer Portal.
3. Once the shop is deleted, each of those subscriptions is **cancelled
   immediately**. If Stripe fails at that moment the deletion stands and the
   log shows `platform_subscription_cancel_failed`: the subscription still
   ends at its period end (step 1), but cancel it in Stripe yourself if it
   should end now (Customers -> the shop's billing customer, metadata
   `shop_id`).

Nothing is refunded automatically for the rest of the period; refund in
Stripe if you choose to. The shop's own Stripe Connect account is not
touched. This happens whether billing is currently on or off.

---

## 9. Taxes (Stripe Tax: optional, off by default)

By default Checkout charges the Price exactly as you set it: no tax is
calculated or collected. Whether you must charge sales tax or VAT on your
subscriptions depends on where you and your shops are: ask your accountant.

To collect tax with Stripe Tax:

1. Set up Stripe Tax on your **platform** account (Stripe Dashboard -> Tax:
   your business address, registrations, and the tax behaviour of your
   Prices, inclusive or exclusive).
2. Set the variable `BILLING_AUTOMATIC_TAX` = `true` and deploy.

From then on Checkout computes the tax, asks for the address it needs and
saves it on the shop's billing customer, so renewals are taxed too.
Subscriptions started before the change are not changed; update them in
Stripe if needed. Without step 1, Checkout fails and the owner sees a generic
error.

---

## 10. Test it (test mode)

On a staging project with Stripe test keys:

1. Create a plan Product with a test Price; run the deploy with
   `BILLING_ENABLED=true` and *stripe_webhooks*; the log lists the plan.
2. Sign up a new shop on the web; Settings -> Billing shows the trial.
3. Choose the plan and pay with Stripe's test card `4242 4242 4242 4242`;
   back in Settings -> Billing the status becomes active.
4. **Manage billing**: switch plans, then cancel at period end; the page
   shows the end date.
5. Failed renewal: in Stripe, use a [test clock](https://docs.stripe.com/billing/testing/test-clocks)
   or the card `4000 0000 0000 0341` (attaches, then declines) and advance
   time: the shop shows past due and the owner gets a notification.
6. Stripe Dashboard -> Developers -> Webhooks -> the billing endpoint: every
   delivery answered 200.

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Owner sees "Subscriptions are not available yet." | billing is off: `BILLING_ENABLED=true`, then deploy |
| "Billing management is not set up yet." | the Customer Portal settings were never saved in this mode (section 4) |
| A plan is missing on the billing page | the Product lacks `detailcrm_plan=true`, is archived, or its Price is weekly/usage-based/tiered/customer-chosen; the deploy log (or `sync_plans`) names each skipped Price and why |
| A plan shows no team limit | `max_members` is missing or not a positive whole number (a warning in the deploy log) |
| Paid, but the page still shows the trial / no subscription | the platform webhook did not arrive: Stripe -> Webhooks -> the billing endpoint's deliveries. 400 answers = wrong `STRIPE_BILLING_WEBHOOK_SECRET` (often an old GitHub secret sent back after the deploy made a new one: delete it): run **deploy-backend** with *stripe_webhooks* and *stripe_webhook_recreate* = `billing` ([DEPLOY.md](DEPLOY.md) 3.3) |
| Deploy stops: "BILLING_ENABLED is not set, but billing is ON" | set the variable explicitly (section 5, Safety) |
| Deploy stops: an endpoint at `.../billing-webhook` "was not created by this script" | an endpoint made by hand: delete it, or run with *stripe_webhooks* and *stripe_webhook_adopt_billing* = its `we_...` id if it is the platform endpoint whose secret is `STRIPE_BILLING_WEBHOOK_SECRET` ([DEPLOY.md](DEPLOY.md) 3.3) |
| Deploy stops in step 2: "STRIPE_BILLING_WEBHOOK_SECRET is neither an input nor stored in the project" | billing is on but the platform endpoint was never created: run once with *stripe_webhooks* (section 5) |
| The owner cannot delete the shop: "We could not cancel the shop's subscription, so nothing was deleted." | the first step of the deletion (stop renewal, section 8.1) failed in Stripe (refused or unreachable), so nothing changed. Try again; check the subscription in Stripe (Customers -> the shop's billing customer, metadata `shop_id`) |
| "This shop already has a subscription. Use Manage billing ..." when choosing a plan | Stripe has a subscription for the shop that can still bill (section 6), possibly one whose webhook has not arrived yet, or one marked unpaid: use Manage billing, or check the customer in Stripe |
| A shop was charged twice | two checkouts were paid at almost the same moment: the webhook refunds and cancels the newer subscription by itself (log `billing_duplicate_subscription_cancelled`). A second subscription made in the Stripe Dashboard is only logged (`duplicate_subscription`): refund and cancel it in Stripe |
| The owner's checkout says "This shop's billing account was just set up by another request. Refresh and try again." | two checkouts raced to create the shop's Stripe customer; the next try uses the one that won |
| "Confirming your subscription with Stripe..." ends with "Stripe hasn't confirmed the subscription yet" | the platform webhook has not delivered (see the "Paid, but ..." row) |
