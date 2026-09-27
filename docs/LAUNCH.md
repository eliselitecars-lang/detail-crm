# Launch checklist

A step-by-step list for taking Detail CRM live: which accounts to open, what
to set up in each, the order to deploy in, how to test the first shop, and
what App Store review will ask for. The technical details behind each deploy
step are in [DEPLOY.md](DEPLOY.md).

Prices, fees, limits and review times change and are not listed here: check
each provider's own pricing page (linked) before you commit.

**What you are launching**

- **Backend**: a Supabase project (database, sign-in, file storage, and six
  small server functions that talk to Stripe, Twilio and Resend).
- **Web app** at `app.yourdomain.com`: staff dashboard, public booking,
  quote/invoice/form pages and the customer portal (hosted on Cloudflare
  Pages).
- **iPhone app** for shop staff (TestFlight first, then the App Store).
- Each shop connects **its own Stripe account** (Stripe Connect Express);
  customer payments go to the shop, with your optional platform fee.

---

## 1. Accounts to create

Tick each box when done. Keep every key and password in a password manager;
you will paste them into GitHub in step 4.

### 1.1 Supabase (database + sign-in + storage)

- [ ] Create an organization and a project at [supabase.com](https://supabase.com/dashboard).
      Pick the region closest to your shops. **Save the database password**
      you choose (you need it for every deploy).
- [ ] Put the organization on a **paid plan** before real shops use it
      ([pricing](https://supabase.com/pricing)). Free projects are meant for
      testing: they can be paused when idle and have limited backups.
- [ ] Turn on the **Point-in-Time Recovery (PITR)** add-on (paid plans) so
      the database can be restored to any moment, not only to a daily backup
      ([backups](https://supabase.com/docs/guides/platform/backups)).
      Recommended as soon as shops enter real customers and payments.
- [ ] Create a personal **access token** (Account -> [Access Tokens](https://supabase.com/dashboard/account/tokens)).
- [ ] Note the project **Reference ID** (Project Settings -> General) and the
      **anon key** (Project Settings -> API).
- [ ] Read Supabase's [production checklist](https://supabase.com/docs/guides/deployment/going-into-prod)
      (MFA on your Supabase account, who has access to the organization).

You do **not** configure sign-in settings, email settings or scheduled jobs by
hand: the deploy does it (email confirmations stay ON in production).

### 1.2 Stripe (payments, as a platform)

- [ ] Create your platform's Stripe account and **activate** it (business
      details, bank account) at [dashboard.stripe.com](https://dashboard.stripe.com).
- [ ] Enable **Connect** and choose **Express** accounts for shops
      ([Express accounts](https://docs.stripe.com/connect/express-accounts)).
      Shops onboard from Settings -> Payments in the web app; Stripe hosts the
      onboarding and the shop's Express dashboard.
- [ ] **Platform branding** (Connect settings -> Branding): your platform name,
      icon and color, shown to shops during onboarding and in their Express
      dashboard.
- [ ] **Payouts** for connected accounts: decide the payout schedule shops get
      ([payout schedules](https://docs.stripe.com/connect/manage-payout-schedule)).
- [ ] Review who is responsible for refunds, disputes and negative balances
      of connected accounts in your Connect settings, and put it in your terms
      with shops ([Connect overview](https://docs.stripe.com/connect)).
- [ ] Decide your platform fee, if any (a percentage of card payments, set as
      `PLATFORM_FEE_BPS`; 100 = 1%). It is optional; unset means no fee.
- [ ] Copy the **live** API keys (Developers -> API keys): `sk_live_...` and
      `pk_live_...`. Use test keys only for a separate staging project.
- [ ] Webhook: nothing to click. The first backend deploy with
      `stripe_webhooks` creates the Connect webhook and stores its secret.
- [ ] Go through Stripe's [go-live checklist](https://docs.stripe.com/get-started/checklist/go-live).

### 1.3 Twilio (text messages)

All shops text through your one Twilio account, but **each shop is registered
separately** with US carriers (A2P 10DLC). This takes the longest of all the
accounts, so start early.

- [ ] Create a Twilio account and upgrade it from trial (trial accounts can
      only text verified numbers).
- [ ] Register your platform as an **ISV** in Trust Hub (your Primary Customer
      Profile) ([A2P 10DLC](https://www.twilio.com/docs/messaging/compliance/a2p-10dlc),
      [ISV onboarding](https://www.twilio.com/docs/messaging/compliance/a2p-10dlc/onboarding-isv)).
- [ ] For **each shop** that wants texting: its own Secondary Customer
      Profile, brand, campaign and Messaging Service, then a number bound to
      it. Follow [`supabase/setup/twilio.md`](../supabase/setup/twilio.md)
      exactly (it explains why shops must never share a campaign or service).
      Until a shop's campaign is approved, carriers block its texts.
- [ ] Copy the **Account SID** (`AC...`) and **Auth Token**.

Shops cannot buy or register numbers themselves yet: the operator does it per
shop (self-serve numbers are on the roadmap, gated on the Twilio ISV setup).

### 1.4 Resend (email)

- [ ] Create a Resend account and **add your sending domain** (for example
      `yourdomain.com` or `mail.yourdomain.com`)
      ([domains](https://resend.com/docs/dashboard/domains/introduction)).
- [ ] Add the DNS records Resend shows (SPF and DKIM) at your DNS provider and
      wait until the domain shows **Verified**. Adding a DMARC record is
      recommended for deliverability.
- [ ] Create an **API key** with sending access (`re_...`).
- [ ] Choose the sender, e.g. `Detail CRM <notifications@yourdomain.com>`
      (`EMAIL_FROM`). The same key sends sign-in emails through Resend's SMTP
      ([Supabase + Resend](https://resend.com/docs/send-with-supabase-smtp)); the
      deploy configures it.

### 1.5 Cloudflare (web hosting)

- [ ] Create a Cloudflare account. Note the **Account ID** (Workers & Pages).
- [ ] Create an **API token** with the permission *Account -> Cloudflare
      Pages -> Edit* ([create a token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)).
- [ ] Pick a Pages project name (e.g. `detail-crm`); the first web deploy
      creates it.

### 1.6 Apple (iPhone app)

- [ ] Enroll in the **Apple Developer Program**
      ([enroll](https://developer.apple.com/programs/enroll/)). Enroll as an
      organization so the App Store shows your company name; that needs a
      D-U-N-S number ([D-U-N-S](https://developer.apple.com/support/D-U-N-S/)).
- [ ] Register the bundle id `com.detailcrm.app` (or your own) under
      Certificates, Identifiers & Profiles -> Identifiers (no capabilities are
      needed yet).
- [ ] In [App Store Connect](https://appstoreconnect.apple.com), create the
      **app record** (Apps -> + -> New App) with that bundle id.
- [ ] Create an **App Store Connect API key** (Users and Access ->
      Integrations -> Team Keys) with the **Admin** role, download the `.p8`
      (only possible once) and note the Key ID and Issuer ID
      ([API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)).
      Admin lets Xcode create the signing certificate and profiles in the
      cloud; there is nothing to install on a Mac.
- [ ] Note your **Team ID** (developer.apple.com -> Account -> Membership).
- [ ] **APNs key** (push notifications): create one (Certificates, Identifiers
      & Profiles -> Keys -> Apple Push Notifications service) and keep the
      `.p8`, Key ID and Team ID. Push is **not in this build**; it is the next
      build phase, so the key is only stored for now
      ([token-based APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)).
- [ ] **Tap to Pay on iPhone** (optional, for later): request the entitlement
      from Apple ([Tap to Pay on iPhone](https://developer.apple.com/tap-to-pay/))
      and plan Stripe Terminal for it
      ([Stripe Tap to Pay](https://docs.stripe.com/terminal/payments/setup-reader/tap-to-pay)).
      The feature is not built yet and will ship switched off until Apple
      grants the entitlement, so asking early costs nothing.

### 1.7 GitHub

- [ ] Access to this repository with permission to edit **Settings -> Secrets
      and variables -> Actions**.
- [ ] Optional: an environment named `production` (Settings -> Environments)
      with yourself as required reviewer, so no deploy runs without your click.

---

## 2. Domain and DNS

- [ ] Own a domain, e.g. `yourdomain.com`.
- [ ] **Web app**: `app.yourdomain.com` -> Cloudflare Pages custom domain
      (added after the first web deploy; Cloudflare shows the CNAME to create,
      or creates it when the domain's DNS is on Cloudflare)
      ([custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/)).
      This exact origin is your `APP_BASE_URL`; changing it later means
      re-running the backend deploy.
- [ ] **Email**: the Resend records from 1.4 (SPF, DKIM; DMARC recommended).
- [ ] Supabase stays on `https://<ref>.supabase.co`. A custom API domain is a
      paid Supabase add-on; if you add one later, Stripe, Twilio and the apps
      must be pointed at it (re-run all deploys).
- [ ] A **privacy policy** and a **support** page/email on your domain
      (App Store Connect requires both URLs; shops will ask too). The web app
      serves the privacy policy at `<APP_BASE_URL>/privacy` and the terms of
      service at `<APP_BASE_URL>/terms` (section 6); a support page or email
      is yours to provide.

---

## 3. Values to write down

From the steps above you should now have: Supabase access token, project ref,
database password, anon key; Stripe `sk_live`/`pk_live`; Twilio SID + token;
Resend key + sender; Cloudflare token + account id + project name; Apple Key
ID, Issuer ID, `.p8`, Team ID; your `APP_BASE_URL`. Also generate the cron
secret once (`openssl rand -hex 32`, or any 32+ random letters and digits).
For the legal pages: your legal company name, a support email for privacy
requests, the governing law of your terms and (optionally) a postal address
(`LEGAL_ENTITY_NAME`, `SUPPORT_EMAIL`, `LEGAL_COUNTRY`, `LEGAL_ADDRESS` in
[DEPLOY.md section 2](DEPLOY.md#2-settings-reference)).

---

## 4. Deploy, in this order

1. [ ] **GitHub settings**: add every secret and variable listed in
       [DEPLOY.md section 2](DEPLOY.md#2-settings-reference). Each workflow
       starts by listing anything still missing.
2. [ ] **Backend dry run**: Actions -> *deploy-backend* -> Run workflow with
       *dry_run* checked. It changes nothing and prints the plan.
3. [ ] **Backend deploy**: run it again with *dry_run* unchecked and
       *stripe_webhooks* checked (first time only). The last step must say
       `0 failed`.
4. [ ] **Web deploy**: Actions -> *deploy-web* -> Run workflow. Then add the
       custom domain `app.yourdomain.com` to the Pages project and open it.
       (Set the variable `DEPLOY_WEB` = `true` if every change merged to `main`
       should deploy automatically.)
5. [ ] **iPhone build**: Actions -> *ios-testflight* -> Run workflow. The build
       shows up in App Store Connect -> TestFlight after Apple processes it;
       add yourself as an internal tester.
6. [ ] **Twilio numbers** for the first shop (1.3, `twilio.md`).

---

## 5. First-shop smoke test

Do this with a real card on live keys (refund it afterwards), or on a staging
project with Stripe test keys.

1. [ ] Web: **Sign up** at `app.yourdomain.com/signup`. The confirmation email
       arrives from your `EMAIL_FROM` domain (proves Resend + Auth). Confirm.
2. [ ] **Create the shop** (onboarding), fill Settings -> Business, Hours,
       Booking.
3. [ ] Settings -> **Payments** -> connect Stripe. Finish Express onboarding;
       back in the app the status shows charges enabled.
4. [ ] **Catalog**: add a service with a price for a vehicle category.
5. [ ] Open the public booking page `app.yourdomain.com/book/<your-slug>` in a
       private window, book as a customer, pay the deposit if you require one.
       The booking appears in the calendar; the payment appears under
       Payments (proves the Stripe webhook).
6. [ ] **Team**: invite a technician by email; accept on another device.
7. [ ] iPhone (TestFlight): sign in as the technician, open the job, take a
       before photo, clock in and out.
8. [ ] Create an **invoice**, send the pay link, pay it, then refund it from
       the web app (owner/admin).
9. [ ] **Texting** (after the shop's number is provisioned): send "on my way"
       from the job; reply STOP from the customer's phone and check the
       customer shows as opted out; reply START.
10. [ ] **Email campaign** to yourself: the unsubscribe link opens the
        `/u/<token>` page and unsubscribes.
11. [ ] Run the backend smoke checks again (the last step of deploy-backend
        or `verify_live.mjs`): still `0 failed`.

---

## 6. App Store review

TestFlight for your own team needs none of this; public App Store release
does ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)).

- [ ] **Privacy policy and terms**: the web app serves them at
      `<APP_BASE_URL>/privacy` and `<APP_BASE_URL>/terms` (no sign-in), and
      links them under the sign-in and sign-up pages, in the footer of the
      public booking, quote, invoice, form and portal pages, on the web
      Your account page and in the iPhone app (More -> Your account).
      **Have your lawyer review both texts before launch**: they describe
      what this code does (wording in `web/src/features/legal/content.tsx`),
      but they are not legal advice and the legal choices in them (liability
      cap, governing law, notice of changes, the shop's responsibility for
      refunds, disputes and negative balances) are yours to confirm. Set the
      `LEGAL_*` / `SUPPORT_EMAIL` variables
      ([DEPLOY.md section 2](DEPLOY.md#2-settings-reference)) so the pages name you;
      without them they say "the operator of this service". When the product
      changes what it collects or who receives it, update the text and its
      "Last updated" date (`LEGAL_LAST_UPDATED`) in the same change.
- [ ] **Privacy policy URL** in App Store Connect (App Information -> Privacy
      Policy URL): `<APP_BASE_URL>/privacy`, e.g.
      `https://app.yourdomain.com/privacy`.
- [ ] **Demo account**: create a real shop yourself (e.g. "Review Demo
      Detailing") with an owner login, a few services, a customer and a job,
      and give the email/password in App Store Connect -> App Review
      Information. Reviewers cannot sign up for a business on their own. The
      app only shows what you enter (no fake data ships with it).
- [ ] **Privacy "nutrition" labels** (App Store Connect -> App Privacy,
      [details](https://developer.apple.com/app-store/app-privacy-details/)).
      From what this build of the iPhone app actually handles:

      | Apple category | What the app collects | Linked to the user | Used for tracking |
      |---|---|---|---|
      | Contact Info: name, email address, phone number | staff account (name, email, phone) and the shop's customers entered by staff (name, email, phone) | yes | no |
      | Contact Info: physical address | customer service addresses | yes | no |
      | User Content: photos | before/after and inspection photos | yes | no |
      | User Content: other (signatures, notes) | customer signatures, job/inspection notes | yes | no |
      | User Content: emails or text messages | messages staff send to and receive from customers (Inbox) | yes | no |
      | Financial Info: payment info | card details typed into the Stripe payment sheet, processed by Stripe (the app stores only card brand and last 4) | yes | no |
      | Purchases: purchase history | invoices and payments of the shop's customers | yes | no |
      | Identifiers: user ID | the sign-in account id | yes | no |
      | Other data | vehicles (make/model, VIN, plate) and staff clock-in/out times | yes | no |

      Purpose for all: **App Functionality**. The app has no analytics, ads or
      tracking SDKs and does not read the device location (map buttons only
      open Apple Maps). The Stripe SDK may collect device data for fraud
      prevention: follow Stripe's guidance for the payment-sheet rows
      ([Stripe iOS SDK privacy details](https://support.stripe.com/questions/stripe-ios-sdk-and-apple-app-store-privacy-details)).
      Re-check this table whenever a build adds a feature (push notifications
      will add a device token; geostamped clock-in would add location).
- [ ] **Account deletion inside the app** (Guideline 5.1.1(v), required for any
      app that lets people create an account:
      [Apple's page](https://developer.apple.com/support/offering-account-deletion-in-your-app/)).
      Built: More -> Your account -> Delete account in the iPhone app, and
      the Your account page on the web (the `account` function). Shop owners
      must first transfer ownership or delete the shop. Mention the path in
      App Review Information if asked.
- [ ] **Privacy manifest**: the app stores its chosen shop in `UserDefaults`,
      a "required reason" API; `PrivacyInfo.xcprivacy` in the app target
      declares it (reason CA92.1) and no tracking
      ([required reasons](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)).
- [ ] **Export compliance**: already answered in the app
      (`ITSAppUsesNonExemptEncryption = NO`: it only uses the encryption built
      into iOS for HTTPS), so no questionnaire per build.
- [ ] **Payments**: the app charges for detailing work done in the real
      world, which Apple requires to go through a payment processor such as
      Stripe, not in-app purchase (Guideline 3.1.3(e)). Nothing to do; answer
      accordingly if asked.
- [ ] Sign in with Apple is not required: the app has no third-party sign-in
      (email and password only).
- [ ] Support URL, screenshots, description, age rating in App Store Connect
      (the privacy policy URL is above).

---

## 7. What is gated or not built

From SPEC section 9 (parity roadmap, 2026-09-27) and this launch review:

- **Ships dark until approved**: Tap to Pay on iPhone / Stripe Terminal
  (needs Apple's entitlement; not built yet).
- **Next build phase**: push notifications (APNs key in 1.6).
- **Operator-run for now**: per-shop Twilio numbers and A2P registration
  (self-serve SMS numbers are on the roadmap, gated on Twilio ISV onboarding).
- **Roadmap, not built yet**: recurring jobs, document follow-ups, multiple
  and per-service reminders, CSV import/export (P0); multi-job invoicing,
  customer job reports, lead forms and custom fields, booking embed / QR /
  pixels, required checklists, tips and commissions, coupon restrictions,
  gift cards (P1); proposal options, quote self-scheduling, calendar events
  and capacity v2, day map and route hand-off, iCal feeds, customer merge,
  preset fees, VIN barcode scan, memberships v2, geostamped clock-in,
  documents, iOS realtime (P2).
- **Not planned** (partner agreements or compliance): QuickBooks sync, own
  payment processing, Carfax / SiriusXM, 3D visualizer, marketplace/store,
  voice calling, Android app, workflow builder, route optimization engine,
  Reserve with Google, card surcharging.
- **Known open defects** found by the real-stack checks
  (`scripts/stack/README.md`): an unknown public link token answers HTTP 500
  instead of 404 (pages still show "not found"); due-on-receipt invoices show
  as overdue immediately; staff-sent invoice/quote messages can keep an empty
  "call us at" line when the shop has no phone number.
