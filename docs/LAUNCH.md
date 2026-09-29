# Launch checklist

A step-by-step list for taking Detail CRM live: which accounts to open, what
to set up in each, the order to deploy in, how to test the first shop, and
what App Store review will ask for. The technical details behind each deploy
step are in [DEPLOY.md](DEPLOY.md).

Prices, fees, limits and review times change and are not listed here: check
each provider's own pricing page (linked) before you commit.

**What you are launching**

- **Backend**: a Supabase project (database, sign-in, file storage, and 15
  small server functions in `supabase/functions/` that talk to Stripe,
  Twilio, Resend and Apple's push service).
- **Web app** at `app.yourdomain.com`: staff dashboard, public booking,
  quote/invoice/form pages and the customer portal (hosted on Cloudflare
  Pages).
- **iPhone app** for shop staff (TestFlight first, then the App Store).
- Each shop connects **its own Stripe account** (Stripe Connect Express);
  customer payments go to the shop, with your optional platform fee.
- Optional: shops pay **you** a monthly or yearly subscription for Detail CRM,
  on **your** Stripe account (plans you define in Stripe). It is off until
  you turn it on and is unrelated to the shops' own Stripe accounts:
  [BILLING.md](BILLING.md).

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
- [ ] Raise the project's **upload size limit** to at least **200 MB**
      (Dashboard -> Storage -> Settings -> Upload file size limit; the
      maximum depends on the plan). Job videos (`job-media` bucket) go up to
      200 MB and documents up to 25 MB; the migrations set each bucket's own
      limit, but the project-wide limit caps them all and the deploy does not
      change it (the Free plan allows 50 MB, so videos above that fail).
- [ ] Read Supabase's [production checklist](https://supabase.com/docs/guides/deployment/going-into-prod)
      (MFA on your Supabase account, who has access to the organization).

You do **not** configure sign-in settings, email settings or scheduled jobs by
hand: the deploy does it (email confirmations stay ON in production). The
upload size limit above is the one storage setting you set yourself.

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
      `PLATFORM_FEE_BPS`; 100 = 1%). It is optional; unset means no fee, and
      deleting the variable later removes the fee at the next backend deploy.
- [ ] Copy the **live** API keys (Developers -> API keys): `sk_live_...` and
      `pk_live_...`. Use test keys only for a separate staging project.
- [ ] Webhook: nothing to click. The first backend deploy with
      `stripe_webhooks` creates the Connect webhook and stores its secret in
      the project; later deploys keep it (it never needs to be in GitHub).
- [ ] **Shop subscriptions** (optional, whenever you are ready to charge
      shops; [BILLING.md](BILLING.md)): create your plan Products and Prices
      in this platform account (metadata `detailcrm_plan` = `true`), save the
      **Customer Portal** settings (Settings -> Billing -> Customer portal, in
      test and in live mode), choose a trial length, and decide whether you
      need Stripe Tax. Then set `BILLING_TRIAL_DAYS` and `BILLING_ENABLED` and
      deploy with `stripe_webhooks` (it also creates the separate platform
      billing webhook). Comp pilot shops **before** turning billing on.
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
- [ ] **Geo permissions** (Twilio Console -> Messaging -> Settings -> Geo
      permissions): allow texts only to the countries your shops serve (for
      example only the United States and Canada). Your one account pays for
      every shop's texts, and staff can text any number saved on a customer;
      limiting the countries caps the cost of a mistake and of SMS-pumping
      fraud to premium-rate destinations. Recommended before the first shop
      texts.

Public **lead forms** (a shop can embed them on its website; anyone can
submit them) cannot be used to text arbitrary numbers at your cost: the
optional auto-reply is **emailed** to the address given, and **texted only
to a phone number the shop has already verified on an existing customer**,
never to the number a new lead typed in.
It greets the person as "there" and never repeats what they typed, and each
form accepts at most 10 submissions per IP address (3 per email or phone,
200 in total) in any 24 hours (`public_submit_lead`, migration 0088).

Self-serve numbers (a shop owner searches for, buys and verifies its own
number in Settings -> SMS) are built but **ship dark**; while they are off,
the operator sets up each shop's number as above.

- [ ] Optional, to let shops get **toll-free** numbers themselves: once your
      Twilio account can buy numbers and submit toll-free verifications, and
      number costs are accounted for, set `SMS_PROVISIONING_ENABLED=true`.
- [ ] Optional, to also offer **local** numbers (A2P 10DLC registration):
      once your ISV profile is approved, set `TWILIO_ISV_ENABLED=true` and
      `TWILIO_PRIMARY_CUSTOMER_PROFILE_SID` (the approved primary customer
      profile, `BU...`); the deploy refuses the flag without the profile.

Unset means off, and deleting a variable turns the feature off again at the
next backend deploy. Both are listed in [DEPLOY.md](DEPLOY.md).

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
      Certificates, Identifiers & Profiles -> Identifiers and turn on the
      **Push Notifications** capability (the app's entitlements carry
      `aps-environment`; with automatic cloud signing and the Admin API key
      below Xcode can also add it, but a profile without it fails the
      archive).
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
      `.p8`, Key ID and Team ID. The `push` edge function sends with it (its
      APNs secrets are listed in docs/DEPLOY.md; the topic is the bundle id).
      Without them the app still registers devices and the in-app bell works;
      nothing is pushed
      ([token-based APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)).
- [ ] **Tap to Pay on iPhone** (optional): request the entitlement from
      Apple ([Tap to Pay on iPhone](https://developer.apple.com/tap-to-pay/))
      and enable Stripe Terminal on the platform account
      ([Stripe Tap to Pay](https://docs.stripe.com/terminal/payments/setup-reader/tap-to-pay)).
      The app ships with it switched off (`TAP_TO_PAY_ENABLED` = `NO` in
      `Config.plist`); ios/README.md lists the two changes to make once Apple
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
      This exact origin is your `APP_BASE_URL`. Pick it before the first
      TestFlight build: changing it later means re-running the backend deploy
      **and** shipping a new iPhone build (ios-testflight, then an App Store
      release). Each iPhone build has the origin built in (`WEB_APP_URL` in
      `Config.plist`) for the booking and invite links it shares, the
      Privacy/Terms rows and its password-reset and sign-up email links, so
      installed copies keep using the old one until they update. Until then,
      keep the old domain attached to the web app and list it in
      `AUTH_ADDITIONAL_REDIRECT_URLS` (`https://old.example.com/**`) — see
      DEPLOY.md 4.4.
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
       *dry_run* and *stripe_webhooks* checked. It changes nothing and
       prints the plan.
3. [ ] **Backend deploy**: run it again with *dry_run* unchecked and
       *stripe_webhooks* checked (first time only: it stores the webhook
       secret in the project, and later deploys leave the box unchecked and
       keep it). The last step must say `0 failed`.
4. [ ] **Web deploy**: Actions -> *deploy-web* -> Run workflow. Then add the
       custom domain `app.yourdomain.com` to the Pages project and open it.
       (Set the variable `DEPLOY_WEB` = `true` if every change merged to `main`
       should deploy automatically.)
5. [ ] **iPhone build**: Actions -> *ios-testflight* -> Run workflow. The build
       shows up in App Store Connect -> TestFlight after Apple processes it;
       add yourself as an internal tester.
6. [ ] **Twilio numbers** for the first shop (1.3, `twilio.md`). When a
       shop is deleted later, its self-serve numbers are released
       automatically; numbers you bound by hand are not: they appear on the
       daily `release_worklist` (`sms_numbers_awaiting_release` in the
       `sms-provisioning` logs) for you to release or give to another shop
       (`supabase/setup/twilio.md`).
7. [ ] **Billing** (optional, later): [BILLING.md](BILLING.md) section 5.
       Until `BILLING_ENABLED` is `true` every shop can use everything for
       free. In short, in this order:
       1. In your **platform** Stripe account, one Product per plan with the
          metadata `detailcrm_plan` = `true` (plus optional `max_members`,
          `features`, `sort`) and a monthly and/or yearly recurring Price
          each; save the Customer Portal settings (test and live mode).
       2. Comp pilot shops (`billing_set_comp`, BILLING.md section 7).
       3. Set `BILLING_TRIAL_DAYS`, then `BILLING_ENABLED` = `true`, and run
          *deploy-backend* with *stripe_webhooks*. It creates the platform
          webhook endpoint for `billing-webhook` (checkout, subscription,
          invoice paid / payment failed, product and price events) and
          stores its secret, applies the switch and trial with
          `set_billing_config(p_enabled, p_trial_days)`, and syncs the plans
          through the `billing` function (`sync_plans`).
       4. Check: `<APP_BASE_URL>/pricing` lists the plans; Settings -> Billing
          shows the trial and the plan cards to the owner (section 5 step 12).
       The iPhone app shows neutral status text only (section 6).

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
        `/u/<token>` page and unsubscribes you from marketing email only
        (invoices and reminders still arrive); on the same page try
        Resubscribe, then Stop all emails (it asks first). Signed in to
        `/portal` with that address, the Marketing emails toggle shows and
        changes the same choice.
11. [ ] Run the backend smoke checks again (the last step of deploy-backend
        or `verify_live.mjs`): still `0 failed`.
12. [ ] **Billing** (only once it is on; best on a staging project with test
        keys): the test in [BILLING.md](BILLING.md) section 10 (subscribe
        with a test card, manage in the portal, a failed renewal).

---

## 6. App Store review

TestFlight for your own team needs none of this; public App Store release
does ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)).

- [ ] **Privacy policy and terms**: the web app serves them at
      `<APP_BASE_URL>/privacy` and `<APP_BASE_URL>/terms` (no sign-in), and
      links them under the sign-in and sign-up pages, in the footer of the
      public booking, quote, invoice, form and portal pages, on the web
      Your account page, and in the iPhone app on Create account, Sign in,
      the shop picker, Create shop and Join a team, and under More -> Your
      account.
      **Have your lawyer review both texts before launch**: they describe
      what this code does (wording in `web/src/features/legal/content.tsx`),
      but they are not legal advice and the legal choices in them (liability
      cap, governing law, notice of changes, the shop's responsibility for
      refunds, disputes and negative balances, and the shop subscription
      terms: automatic renewal, cancellation at the end of the paid period in
      the Customer Portal, no refunds except as stated at checkout or
      required by law, what a lapsed shop can still do) are yours to confirm.
      The privacy policy says your platform Stripe account receives the
      shop's billing details for the subscription. Set the
      `LEGAL_*` / `SUPPORT_EMAIL` variables
      ([DEPLOY.md section 2](DEPLOY.md#2-settings-reference)) so the pages name you;
      without them they say "the operator of this service". When the product
      changes what it collects or who receives it, update the text and its
      "Last updated" date (`LEGAL_LAST_UPDATED`) in the same change (the web
      unit test `legalVersion.test.tsx` fails until both are done).
- [ ] **Privacy policy URL** in App Store Connect (App Information -> Privacy
      Policy URL): `<APP_BASE_URL>/privacy`, e.g.
      `https://app.yourdomain.com/privacy`.
- [ ] **Demo account**: sign up with a **fresh email address that never
      had a free trial** (the trial is given once per person, by account and
      by email, `+tag` and Gmail-dot variants included: an address that
      already had one gets a shop without a trial, lapsed at once while
      billing is on). Create a real shop with it (e.g. "Review Demo
      Detailing") with an owner login, a few services, a customer and a job,
      then **comp that shop forever** so it never lapses during a review
      (`select public.billing_set_comp('<shop id>', 'infinity');`,
      [BILLING.md](BILLING.md) section 7). Do not create extra shops from the
      demo login: they would start without a trial. Give the email/password
      in App Store Connect -> App Review Information. Reviewers can also sign
      up and create a shop on the phone (Create account -> confirm the email
      -> Create my shop), but that shop is empty, and with billing on it gets
      the free trial only if that person never had one (once per person).
      The demo shop shows the app with real records. The app only shows what
      you enter (no fake data ships with it).
- [ ] **Privacy "nutrition" labels** (App Store Connect -> App Privacy,
      [details](https://developer.apple.com/app-store/app-privacy-details/)).
      From what this build of the iPhone app actually handles:

      | Apple category | What the app collects | Linked to the user | Used for tracking |
      |---|---|---|---|
      | Contact Info: name, email address, phone number | staff account (name, email, phone) and the shop's customers entered by staff (name, email, phone) | yes | no |
      | Contact Info: physical address | customer service addresses | yes | no |
      | Location: precise location | the device location at the moment a team member clocks in or out, when they allow location access (stored with the time entry; never tracked in between) | yes | no |
      | User Content: photos or videos | before/after and inspection photos, job walkaround videos (with sound) | yes | no |
      | User Content: other (signatures, notes, documents) | customer signatures, job/inspection notes, documents attached to jobs and customers, custom field answers, staff tasks | yes | no |
      | User Content: emails or text messages | messages staff send to and receive from customers (Inbox) | yes | no |
      | Financial Info: payment info | card details typed into the Stripe payment sheet or tapped on Tap to Pay / a card reader when enabled, processed by Stripe (the app stores only card brand and last 4) | yes | no |
      | Purchases: purchase history | invoices, payments, gift cards and store credit of the shop's customers | yes | no |
      | Identifiers: user ID | the sign-in account id | yes | no |
      | Identifiers: device ID | the push notification device token (only when notifications are allowed) | yes | no |
      | Other data | vehicles (make/model, VIN, plate) and staff clock-in/out times | yes | no |

      Purpose for all: **App Functionality**. The app has no analytics, ads or
      tracking SDKs. It asks for "while using the app" location
      (`NSLocationWhenInUseUsageDescription`) and uses it in three places:
      the location stamped on a clock-in / clock-out (the only device
      location it stores; `OpsClockLocationProvider`); the day map
      (`JobsDayMapView`), which shows your own position on the device and
      does not send it anywhere; and, when Tap to Pay or a card reader is
      turned on, the Stripe Terminal SDK, which requires location access
      while taking in-person payments (see Stripe's privacy details below).
      The day map also sends service addresses that have no map point yet to
      Apple's geocoder (`CLGeocoder`) and saves the point found on the job
      (`set_job_coordinates`), and its route buttons open Apple Maps or
      Google Maps with the stops. The camera is used for photos, videos and
      VIN scanning, the microphone only for the sound of job videos. The
      Stripe SDK may collect device data for fraud prevention: follow
      Stripe's guidance for the payment-sheet rows
      ([Stripe iOS SDK privacy details](https://support.stripe.com/questions/stripe-ios-sdk-and-apple-app-store-privacy-details)).
      Re-check this table whenever a build adds a feature.

      On the web (not the iPhone app, so not part of these labels): a shop
      may enter its own Meta Pixel or Google Analytics 4 id in Settings ->
      Online booking. Only its public booking page `/book/<slug>` then loads
      the tag (never private booking links, lead forms, quotes, invoices, the
      portal or staff pages; the customer's own booking page `/booking/<token>`
      loads only GA4, once, to report a deposit paid online, with the token
      left out of the page address; `web/src/features/booking/tracking.ts`).
      The deploy's CSP allows the tags' origins only on `WEB_TRACKING_PATHS`
      (DEPLOY.md 4.3). The privacy policy says so; shops should mention the
      tags in their own privacy policy and keep Meta's "Automatic advanced
      matching" off (Settings -> Online booking says so too). The web day map
      loads map tiles from OpenStreetMap (listed in the privacy policy).
- [ ] **Account deletion inside the app** (Guideline 5.1.1(v), required for any
      app that lets people create an account:
      [Apple's page](https://developer.apple.com/support/offering-account-deletion-in-your-app/)).
      Built: More -> Your account -> Delete account in the iPhone app (also
      in the account menu of the shop picker), and the Your account page on
      the web (the `account` function). A shop can't be left without an
      owner, so the app's Delete account screen first lists the shops the
      person owns (`account_deletion_blockers`), and each can be handled in
      the app: delete the shop there (type its name; `payments` ->
      `delete_shop`, which also ends its subscription to you,
      [BILLING.md](BILLING.md) section 8.1), or make another team member the
      owner (Team -> the member -> Make owner, `transfer_ownership`). A solo
      owner who signed up on the phone therefore deletes the shop and then
      the account without leaving the app. Mention the path in App Review
      Information if asked.
- [ ] **Customer deletion requests** (not an App Store item: privacy laws
      such as the GDPR or CCPA let a shop's customers ask the shop to delete
      their details). Built on the web only: the customer's page -> Delete,
      shown to owners and admins (managers and technicians don't see it; no
      client can delete a `customers` row directly, 0125 / 0132). The dialog
      first shows the server's dry run (`payments` -> `erase_customer`
      without `confirm`, nothing changes): the customer is **deleted** when
      no job, invoice, payment or membership references them, otherwise
      **anonymised** in place — shown as "Deleted customer", with contact
      details, addresses, notes, vehicle VIN / plate, messages, files, form
      answers and signatures removed, while jobs, quotes, invoices, payments
      and memberships keep their amounts, numbers and dates (revenue and tax
      reports don't change). Duplicates merged into the customer are handled
      the same way. An active membership must be cancelled first; the action
      itself cancels unfinished card attempts, closes open pay / deposit
      pages and removes saved cards and the customer's Stripe customer on
      the shop's account; money still moving (a bank debit clearing, a page
      just paid) refuses until it settles. Opt-out lists stay (keyed by
      address), and `customer_erasures` records who erased which record and
      when (no personal data). The privacy policy describes this under
      "Deleting a shop's customer". Try it once on a staging project: a
      customer with a paid invoice comes back anonymised, one with no
      history is deleted.
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
- [ ] **Shop subscriptions** (when billing is on): the iPhone app has no
      purchase screen, no prices, no plan names and no links or buttons
      towards buying; it only shows a neutral status line, and a refused
      action shows the server's neutral sentence ("This shop's subscription
      is inactive, so new records can't be created right now."). Shops, as
      businesses, subscribe to the service on the web (Settings -> Billing;
      the public `/pricing` page lists the plans). If App Review asks,
      explain exactly that (guidelines 3.1.1 and 3.1.3); do not add a link
      to the web billing or pricing page in the app. The web's owner-only
      "Go to Billing" links and banners exist only on the web.
      Know the weak spot of that answer: the app lets anyone create an
      account and a shop (Create my shop, `create_shop`). With billing on,
      that shop starts a trial unless that person already had one (the trial
      is once per person; then the shop starts lapsed), and after the trial
      it can only be paid for on the web. A reviewer who tries this may read it as a subscription
      sold outside the app for an account made in the app (3.1.1 / 3.1.3(b)).
      Decide before you submit how you answer that: explain that the
      subscription is a business service bought by the shop on the web, and
      that most shops start on the web; or keep billing off
      (`BILLING_ENABLED`, [BILLING.md](BILLING.md) section 5) for the first
      review. Either way, test the path yourself on TestFlight first.
- [ ] Sign in with Apple is not required: the app has no third-party sign-in
      (email and password only).
- [ ] Support URL, screenshots, description, age rating in App Store Connect
      (the privacy policy URL is above).
- [ ] **Later releases**: once a version (1.0 first) is approved, App Store
      Connect closes it and rejects further uploads of it. Before the next
      iPhone release raise the app version: run ios-testflight with
      `app_version` (e.g. `1.1`) or change `MARKETING_VERSION` in the project
      ([DEPLOY.md section 5](DEPLOY.md#5-iphone-testflight), "Versions").

---

## 7. What is gated or not built

From SPEC section 9 (parity roadmap, 2026-09-27) and this launch review:

- **Built, ships dark until approved**: Tap to Pay on iPhone and Bluetooth
  card readers (Stripe Terminal). Off until Apple grants the entitlement and
  you set `TAP_TO_PAY_ENABLED` (and `TERMINAL_BLUETOOTH_ENABLED` for readers)
  to `YES` in the app's `Config.plist` (1.6, ios/README.md).
- **Built, ships dark until you turn it on**: self-serve SMS numbers
  (`SMS_PROVISIONING_ENABLED` for toll-free numbers; `TWILIO_ISV_ENABLED` +
  `TWILIO_PRIMARY_CUSTOMER_PROFILE_SID` for local A2P 10DLC numbers; 1.3).
  While they are off, per-shop Twilio numbers and A2P registration are
  operator-run.
- **Off until you turn it on**: shop subscription billing
  (`BILLING_ENABLED`, [BILLING.md](BILLING.md)); Stripe Tax on those
  subscriptions (`BILLING_AUTOMATIC_TAX`).
- **Needs its keys**: push notifications to the iPhone app are built; nothing
  is pushed until the four `APNS_*` values are set (APNs key in 1.6). The
  in-app notification list works without them.
- **Built in this release** (the parity roadmap, SPEC section 9, and the
  rest of the parity plan): recurring jobs, push notifications, document
  follow-ups, multiple and per-service reminders, CSV import/export (P0);
  multi-job invoicing, customer job reports, lead forms and custom fields,
  booking embed / QR / pixels, required checklists, tips and commissions,
  coupon restrictions, gift cards (P1); proposal options, quote
  self-scheduling, calendar events and capacity v2, day map and route
  hand-off, iCal feeds, customer merge, preset fees, VIN barcode scan,
  memberships v2, geostamped clock-in (iPhone app), documents, iOS
  realtime (P2); plus outbound webhooks (Zapier-ready), inventory and
  consumables, customer referrals, job videos, bank debits (ACH) and
  pay-later through Stripe Checkout, staff tasks, lead-source and quote
  conversion reports, and PDF quotes / invoices / receipts.
  Document follow-ups and service follow-ups are seeded off in every shop:
  a shop turns them on in Settings -> Follow-ups and Settings -> Messages &
  automations (service follow-ups are then written per service in the
  catalog). Follow-up and service follow-up **emails** are marketing email:
  they go out only while the shop has a street address and city on file
  (Settings -> Business profile; 0119). Without one they are not sent (an
  automation's run is logged as skipped) and a hand-sent Follow-up email is
  refused with `postal_address_required`; tell mobile-only shops to add a
  mailing address before turning them on. Bank debits and pay-later appear at checkout only when those
  payment methods are enabled for the shop's connected Stripe account
  (Stripe's payment method settings). Embedding the booking page or
  a lead form on a shop's website needs `WEB_EMBED_PATHS=/book/*,/lead/*`
  on the web deploy, and shops' own Meta Pixel / GA4 tags load only with
  `WEB_TRACKING_PATHS=/book/*,/booking/*` (DEPLOY.md 4.3); without them
  those pages refuse to be framed and the tags are blocked. Lead forms are
  rate-limited, and their auto-reply is emailed and texted only to a phone
  number the shop already verified (1.3).
- **Not built** (partner agreements or compliance; SPEC section 9):
  QuickBooks sync, own payment processing, Carfax / SiriusXM, 3D
  visualizer, marketplace/store, voice calling, Android app, workflow
  builder, route optimization engine, Reserve with Google, card
  surcharging.
- **Bot challenge on public forms: not built.** Lead forms and the online
  booking page (embedded or not) are limited in the database per
  connection, per contact and per form (per shop for bookings) in any 24
  hours, and never text a phone number the shop has not verified; a bot
  challenge such as Cloudflare Turnstile is optional future hardening that
  would need a server-side verification path for its token, which does not
  exist yet.
- **Defects found by the real-stack checks** (`scripts/stack/README.md`)
  are fixed and kept as regression checks: unknown public link tokens answer
  404 (`PT404`), a due-on-receipt invoice is due at the end of its issue day
  (not overdue at once), and quote / invoice messages are rendered by the
  server, so a shop without a phone number gets no empty "call us at" line.
