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

States a shop can be in:

| State | Meaning | Can create new work? |
|---|---|---|
| `active` | billing is off, or the subscription is paid (also: cancelled, but the paid period has not ended) | yes |
| `trialing` | inside the free trial | yes |
| `past_due` | a renewal payment failed; Stripe is retrying | yes (until Stripe gives up) |
| `comped` | you made the shop free (section 7) | yes |
| `lapsed` | trial over without a subscription, or the subscription ended | no: see section 8 |

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
  usable (`past_due`) while Stripe retries; when Stripe cancels it or marks
  it unpaid, the shop keeps access until the end of the period it paid for,
  then lapses. The owner also gets an in-app notification on each failed
  payment.
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
| `BILLING_AUTOMATIC_TAX` | `true` or unset | Stripe Tax at Checkout (section 9). Unset = off |

What the trial does:

- A shop created while billing is on starts with a trial of
  `BILLING_TRIAL_DAYS` days. It can use everything without entering a card.
- If the owner subscribes during the trial and at least 48 hours of it are
  left, Checkout keeps the rest of the trial: the first charge happens when
  the trial ends. With less than 48 hours left (Stripe's minimum), the
  subscription starts and is charged right away.
- A shop gets its trial once: a shop that already had a trial on a
  subscription does not get a new one.
- **When you turn billing on, every existing shop that never subscribed gets
  a trial of `BILLING_TRIAL_DAYS` days from that moment.** With `0` days,
  those shops lapse **immediately**. Comp your pilot shops first (section 7)
  or set a trial.

Turning it on, in order:

1. Plans created (section 3) and the Customer Portal saved (section 4), in
   the same mode (test or live) as the project's Stripe keys.
2. Pilot shops comped (section 7).
3. Set `BILLING_TRIAL_DAYS`, then `BILLING_ENABLED` = `true`.
4. Run **deploy-backend** with *dry_run* first, then without it and with
   ***stripe_webhooks*** checked (at least the first time billing is on). The
   deploy:
   - creates the **platform** webhook endpoint for `billing-webhook` with
     exactly the billing events and stores its signing secret as
     `STRIPE_BILLING_WEBHOOK_SECRET` (never printed);
   - applies the settings (`set_billing_config`) and reads them back:
     `billing: ON, trial N day(s)`;
   - syncs the plans from Stripe: `billing plans synced from Stripe: ...`;
   - ends with the smoke checks, which must say `0 failed`.

   Without *stripe_webhooks*, create the endpoint yourself
   ([functions README](../supabase/functions/README.md#stripe-platform-billing-webhook))
   and set the secret `STRIPE_BILLING_WEBHOOK_SECRET` in GitHub; the deploy
   refuses `BILLING_ENABLED=true` without it.
5. Check it end to end (section 10).

Safety: a deploy where `BILLING_ENABLED` (or `BILLING_TRIAL_DAYS`) is **not
set** never changes a project where billing is already on (or has a trial):
it stops and asks you to set the value explicitly. So a local run without the
variables cannot switch billing off by accident.

Turning it off later: set `BILLING_ENABLED` = `false` and deploy. Every shop
is fully usable again. **Stripe keeps billing existing subscriptions**: cancel
them in Stripe if you stop charging. The platform endpoint is left in place so
subscription changes keep reaching the app.

---

## 6. Where shops subscribe

Only the owner, on the web: **Settings -> Billing** -> choose a plan ->
Stripe Checkout (card details are entered on Stripe's page, never in the
app) -> back to Settings -> Billing, which shows the result once Stripe has
confirmed it (usually a few seconds). From then on **Manage billing** opens
the Customer Portal (switch plan, update the card, cancel, invoices). A shop
with a live subscription cannot start a second one.

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
- automations and campaign sends (reminders, follow-ups, document
  follow-ups).

People trying a paused action see "This shop's subscription has ended. The
shop owner can renew it in Settings > Billing."

Team size: on a plan with `max_members`, inviting or adding a member beyond
the limit is refused with "Your plan allows N team members." (active members
and pending invites count, the owner included). Accepting an invite that was
already sent always works.

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
| Paid, but the page still shows the trial / no subscription | the platform webhook did not arrive: Stripe -> Webhooks -> the billing endpoint's deliveries. 400 answers = wrong `STRIPE_BILLING_WEBHOOK_SECRET`: re-run the deploy with *stripe_webhooks* and `STRIPE_BILLING_WEBHOOK_RECREATE=1` |
| Deploy stops: "BILLING_ENABLED is not set, but billing is ON" | set the variable explicitly (section 5, Safety) |
| Deploy stops: an endpoint at `.../billing-webhook` "was not created by this script" | an endpoint made by hand: delete it, or set `STRIPE_BILLING_WEBHOOK_ADOPT=<we_...>` if it is the platform endpoint whose secret is `STRIPE_BILLING_WEBHOOK_SECRET` |
| A shop was deleted but Stripe still bills it | deleting a shop does not cancel its platform subscription: cancel it in Stripe (Customers -> the shop's billing customer; its metadata `shop_id` is the deleted shop's id) |
