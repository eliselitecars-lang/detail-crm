/**
 * Wording of /privacy and /terms. Every statement describes what this code
 * base actually does (data model: docs/SCHEMA.md; providers: SPEC §1 and
 * §5; deletion: the `account` and `storage-purge` functions and the
 * `payments` delete_shop action). When the product changes what it collects,
 * who receives it or how deletion works, change this file in the same
 * commit and bump LEGAL_LAST_UPDATED (operator.ts); legalVersion.test.tsx
 * holds a fingerprint of the wording per date and fails until both are done.
 * Operator details come only from the build-time VITE_LEGAL_* values; nothing
 * is made up when they are missing. The operator reviews the text with
 * counsel (docs/LAUNCH.md).
 */
import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { PRICING_PATH } from '@/features/billing/model';
import { LegalList, LegalSubheading, Term, type LegalSection } from './components/LegalDocument';
import { operatorName, operatorNameStart, type LegalOperator } from './operator';

export interface LegalText {
  intro: ReactNode;
  sections: LegalSection[];
}

const SHOP_KINDS = 'auto-detailing, ceramic-coating, window-tint and paint-protection-film shops';

/** How to reach the operator (and, for shop customers, the shop). */
function contactDetails(operator: LegalOperator, topic: string): ReactNode {
  const { supportEmail, address } = operator;
  const shopCustomers = (
    <p>
      If you are a customer of a shop, you can also contact that shop directly, using the phone
      number or email address on its booking, quote and invoice pages.
    </p>
  );
  if (!supportEmail && !address) {
    return (
      <>
        <p>
          For {topic}, contact {operatorName(operator)}.
        </p>
        {shopCustomers}
      </>
    );
  }
  return (
    <>
      <p>
        For {topic}, contact {operatorName(operator)}:
      </p>
      <LegalList>
        {supportEmail && (
          <li>
            Email:{' '}
            <a
              href={`mailto:${supportEmail}`}
              className="text-primary-ink font-medium break-all hover:underline"
            >
              {supportEmail}
            </a>
          </li>
        )}
        {address && (
          <li>
            Mail: <address className="inline whitespace-pre-line not-italic">{address}</address>
          </li>
        )}
      </LegalList>
      {shopCustomers}
    </>
  );
}

export function privacyPolicy(operator: LegalOperator): LegalText {
  const we = operatorNameStart(operator);
  return {
    intro: (
      <p>
        This policy explains what information Detail CRM (the “Service”) handles, why, who else
        receives it, how long it is kept and the choices you have.
      </p>
    ),
    sections: [
      {
        id: 'who-we-are',
        title: 'Who we are',
        body: (
          <>
            <p>
              {we} (“we”, “us”) runs the Service: a web app and an iPhone app that {SHOP_KINDS} use
              to run their business — online booking, calendar, customers and vehicles, quotes,
              invoices, payments, messages, photos, inspections, forms and time tracking.
            </p>
            <p>
              This policy covers everyone who uses the Service: shop owners and their team members
              (“staff”); customers of a shop who book online, open a booking, quote, invoice, form
              or unsubscribe link, or use the customer portal; and visitors of the Service’s pages.
            </p>
          </>
        ),
      },
      {
        id: 'shops-and-customers',
        title: 'Shops and their customers’ information',
        body: (
          <>
            <p>
              Every shop that signs up gets its own separate workspace. The shop decides which
              customers, vehicles and jobs it records and which messages it sends them. For that
              information the shop is responsible under privacy law (in data-protection terms, the
              shop is the controller), and we handle it on the shop’s behalf only to provide the
              Service to that shop (as its processor or service provider).
            </p>
            <p>
              If you are a customer of a shop, the shop’s own privacy practices apply to your
              records. Send questions and requests about them — for example to see, correct or
              delete them — to the shop. If you contact us instead, we will pass your request on to
              the shop or help it respond.
            </p>
            <p>
              We are responsible for the information we need to run the Service itself: user
              accounts, sign-in and security.
            </p>
          </>
        ),
      },
      {
        id: 'information',
        title: 'Information the Service handles',
        body: (
          <LegalList>
            <li>
              <Term>Accounts:</Term> your email address and password, your name and mobile number if
              you add them, the shops you belong to, your role in each (owner, admin, manager or
              technician), the name your team sees and your calendar colour. Passwords are handled
              by our sign-in provider (Supabase Auth) and are never stored in readable form.
            </li>
            <li>
              <Term>Shop details:</Term> business name, contact details, address, time zone, logo
              and brand colour, services and prices, business hours, booking and tax settings,
              message templates, forms, coupons, membership plans and, if the shop records them,
              team members’ pay rates and commission.
            </li>
            <li>
              <Term>Customers and vehicles:</Term> names, company, email addresses, phone numbers,
              addresses, notes and tags; whether a customer agreed to marketing texts or emails, and
              any opt-outs; vehicles (year, make, model, trim, colour, VIN, license plate) and
              notes.
            </li>
            <li>
              <Term>Jobs and documents:</Term> appointments and repeating appointments (date, time,
              service address, services, prices, notes and status history), checklists, inspections
              (damage marks, mileage, fuel level, notes), quotes (including the name typed to
              approve one and a time the customer picks), invoices, payments, memberships, gift
              cards and store credit, referral codes (and which customer referred whom), staff
              tasks, and any extra details the shop chooses to keep in its own custom fields or asks
              as booking questions.
            </li>
            <li>
              <Term>Photos, videos, files and signatures:</Term> before-and-after and inspection
              photos, walkaround videos (with their sound), documents the shop uploads to a job or
              customer (such as PDFs, Word and Excel files and images), and signatures customers
              draw or type on inspections and forms. They are kept in private file storage that only
              the shop’s team can open, according to their role. When a shop shares a job report,
              the customer’s link shows only the photos, videos, inspection details and documents
              the shop chose to share, through links that expire after a few minutes; documents the
              shop marks as shared also appear on the customer’s booking page and in the customer
              portal the same way. Shop logos and service images are public, because they appear on
              the shop’s booking pages. When a customer signs a form or an inspection remotely, the
              typed name and the time are recorded (and, for forms, the IP address of the signing
              device) as evidence of the signature.
            </li>
            <li>
              <Term>Messages:</Term> texts and emails sent to customers (recipient, content and
              delivery status), customers’ text replies to the shop’s number, campaign recipients,
              and in-app notifications for staff.
            </li>
            <li>
              <Term>Payments:</Term> online and in-person payments are processed by Stripe: cards
              and wallets such as Apple Pay and Google Pay and, when they are turned on for the
              shop’s Stripe account, US bank debits and pay-later services. Card and bank details
              are entered on Stripe’s payment page on the web or in Stripe’s payment form in the
              iPhone app, or read by Stripe’s software when a card is tapped on the iPhone or a
              Stripe card reader, and go directly to Stripe; the Service never receives or stores
              them. We keep only Stripe’s reference IDs, the kind of payment method, the card brand,
              the last four digits of the card or bank account and, for saved cards, the expiry
              month and year, together with amounts, tips, refunds and the outcome of any dispute.
              Cash, check and other payments are recorded by staff.
            </li>
            <li>
              <Term>Shop subscriptions:</Term> when the Service charges shops a subscription, we
              keep each shop’s subscription status, plan, trial and billing-period dates, and
              Stripe’s reference IDs for the shop’s billing customer and subscription. The owner
              enters the card on Stripe’s checkout page; the Service never receives or stores it.
              Because each person gets one free trial, when a shop starts a trial we also record who
              it was given to: the owner’s account, a scrambled (hashed) form of their email address
              — not the address itself — the shop and when the trial ends. This record is kept after
              the shop or the account is deleted (deleting the account removes the link to it), so
              the same email address does not get a second trial.
            </li>
            <li>
              <Term>Time tracking:</Term> when staff clock in and out, the job the time belongs to,
              and notes. When a team member clocks in or out in the iPhone app and has allowed
              location access, the location of the device at that moment (and its accuracy) is
              recorded with the time entry, where the shop’s managers can see it; it is never
              tracked in between. Clocking in or out in the web app records no location.
            </li>
            <li>
              <Term>Online booking, membership sign-up and contact forms:</Term> what a customer
              enters when booking (name, email, phone, vehicle, service address, notes, answers to
              the shop’s booking questions, the chosen services and time, a coupon or referral code
              and marketing choices) or when filling in a shop’s contact form (name, email, phone,
              vehicle, message, answers and marketing choices, plus the IP address of the device,
              used to limit abuse). When an online booking is accepted, the IP address of the device
              (and, if the customer is signed in, their account) is also recorded with the time, so
              the number of online bookings from one device or account can be limited; each time the
              shop receives another online booking, these records older than two days are deleted. A
              membership sign-up on a shop’s online join page records what the person enters (name,
              email, phone, vehicle and marketing choices). When someone starts a membership
              sign-up, the IP address of the device is recorded with the attempt, together with the
              membership, the customer record it belongs to and the email and text-message choices
              the person made; those choices are applied to a customer record the sign-up created
              only once the first membership payment goes through. The record is used to limit the
              number of sign-ups from one connection, and each time the shop receives another online
              sign-up attempt, these records older than seven days are deleted. When someone checks
              a coupon code on a shop’s booking page, the check is recorded with the IP address of
              the device (for an IPv6 address, only its network part), a scrambled form of the code
              (not the code itself), whether the shop has such a code and the time, so the number of
              codes one connection can try is limited and a booking can use only a code that was
              checked; each time the shop receives another check, these records older than two days
              are deleted. Gift card purchases record the buyer’s and recipient’s names and email
              addresses, the gift message and the IP address of the buyer’s device; gift card codes
              are stored only in a scrambled form (plus their last four characters, so staff can
              find a card) and are emailed to the recipient. When someone enters a gift card code
              that does not work on an invoice payment page, the IP address of the device is
              recorded with the failed attempt to stop codes being guessed. A shop can embed its
              booking page or contact form in its own website: the form then appears inside that
              website, and the embed script sets no cookies and tells the website only how tall the
              form is.
            </li>
            <li>
              <Term>Customer portal:</Term> customers who create a portal account sign in with an
              email address and password; once that address is confirmed, the portal shows the
              records shops keep under it.
            </li>
            <li>
              <Term>Devices and connections:</Term> the web app keeps your sign-in session and a few
              preferences (theme, last shop used, calendar view, column choices for spreadsheet
              imports) in your browser’s local storage, and the staff app uses no advertising or
              analytics cookies. Spreadsheets imported into the web app are read in your browser;
              only the columns you choose are sent to the Service, when you check or import them,
              and the file’s name is kept in the shop’s import history. Exports are made from what
              your role may see and saved to your device. The iPhone app keeps your sign-in session
              and the shop you last chose on the device; it uses the camera, the microphone (for the
              sound of a video) and the photo library only when you take or attach a photo or video
              or scan a VIN. If you allow location access while using the app, it uses your location
              in three places: it is recorded with a clock-in or clock-out (the only time it is
              stored); the day map shows your own position on your device without sending it
              anywhere; and when a shop takes in-person card payments with Tap to Pay or a card
              reader, Stripe’s payment software uses it while the payment is taken. If you allow
              notifications, the iPhone app registers a device token with the Service so it can send
              you push notifications about your work. Our hosting providers process IP addresses and
              request details to deliver the Service, keep it secure and fix problems.
            </li>
          </LegalList>
        ),
      },
      {
        id: 'use',
        title: 'How we use information',
        body: (
          <>
            <LegalList>
              <li>
                To provide the Service: sign-in, each shop’s workspace with the permissions of each
                role, online booking and availability, documents, payments, messages, reports and
                search.
              </li>
              <li>
                To send the messages the Service is built to send: account emails (confirming your
                email address, resetting your password, team invitations) and the texts and emails a
                shop sends or schedules for its customers (confirmations, reminders, quotes,
                invoices, receipts, follow-ups and campaigns).
              </li>
              <li>
                To bill shops for their subscription to the Service, where it charges one, and to
                tell the shop owner about a problem with a subscription payment.
              </li>
              <li>
                To keep the Service secure, prevent abuse and fraud, and find and fix problems.
              </li>
              <li>To meet legal obligations and enforce our terms.</li>
            </LegalList>
            <p>
              We do not sell personal information, we do not share it for targeted advertising, we
              do not show ads, and neither app contains our own advertising or analytics trackers. A
              shop may choose to add its own Meta (Facebook) Pixel or Google Analytics tag to its
              public booking page; Meta or Google then receive information as that shop’s providers
              (see below).
            </p>
            <p>
              Where the law requires a legal basis (for example in the European Economic Area or the
              United Kingdom), we rely on performing our contract with you or with the shop, our
              legitimate interest in running and securing the Service, consent where it is asked for
              (such as marketing messages), and legal obligations.
            </p>
          </>
        ),
      },
      {
        id: 'sharing',
        title: 'Who receives information',
        body: (
          <>
            <p>We share information only as needed to run the Service, with these providers:</p>
            <LegalList>
              <li>
                <Term>Supabase</Term> hosts the database, sign-in, file storage and the server
                functions. All Service data is stored with Supabase.
              </li>
              <li>
                <Term>Stripe</Term> processes card payments. Each shop connects its own Stripe
                account, and payments are made on that account. When a customer pays by card, saves
                a card or starts a membership, the customer’s name, email address and phone number
                may be shared with Stripe to create the customer on the shop’s Stripe account.
                Stripe may also collect device information to prevent fraud. Shop subscriptions are
                separate: they are billed on our own Stripe account, which receives the shop’s
                billing details — the shop’s name and the owner’s email address, used to create the
                shop’s billing customer, and the card and any billing address the owner enters on
                Stripe’s checkout and billing pages.
              </li>
              <li>
                <Term>Twilio</Term> sends and receives text messages: phone numbers and message
                content.
              </li>
              <li>
                <Term>Resend</Term> sends email: addresses and message content, including account
                emails such as email confirmation and password reset.
              </li>
              <li>
                <Term>Cloudflare</Term> hosts the web app and delivers its pages.
              </li>
              <li>
                <Term>Apple</Term> distributes the iPhone app through the App Store and TestFlight.
                Apple’s own privacy policy covers what Apple collects, such as downloads and any
                crash reports you choose to share with app developers. Push notifications to the
                iPhone app are delivered through the Apple Push Notification service, which receives
                the device token, the notification’s title and text, and the internal ID of the
                record it opens. The iPhone app’s maps are Apple Maps: when staff use the map of
                mobile jobs, service addresses that have no map point yet are sent to Apple’s map
                service to find their location, and the point found is saved with the job so the
                team sees it on the web map too.
              </li>
              <li>
                <Term>Google Fonts</Term> provides the web app’s typeface, so your browser sends
                Google its IP address and browser details when a page loads.
              </li>
              <li>
                <Term>OpenStreetMap</Term>: the day map in the web app shows map images from the
                OpenStreetMap Foundation’s tile servers, so the browser sends them its IP address
                and the part of the map shown (around the day’s service addresses). The web app
                never sends addresses to a map service to look them up.
              </li>
              <li>
                <Term>NHTSA</Term> (the US National Highway Traffic Safety Administration): when
                staff decode a VIN, only the VIN is sent to NHTSA’s public vehicle database to look
                up the year, make and model.
              </li>
            </LegalList>
            <p>
              Map and route buttons open Apple Maps or Google Maps with the addresses or map points
              of the stops only when you tap them.
            </p>
            <p>
              <Term>Tools a shop chooses:</Term> a shop can connect its own tools; the information
              then goes to those tools under the shop’s responsibility:
            </p>
            <LegalList>
              <li>
                Webhooks send details of bookings, jobs, payments, signed forms and memberships
                (including the customer’s name, email address and phone number) to web addresses the
                shop sets up, such as Zapier or its own systems. Card details and internal notes are
                never included.
              </li>
              <li>
                If the shop adds its own Meta (Facebook) Pixel or Google Analytics 4 tag in its
                booking settings, its public booking page loads the tag (also when that page is
                embedded in the shop’s website), and Meta or Google receive, as the shop’s
                providers, page views, the start of a booking and each booking made, with its value;
                Google Analytics also receives the amount of a deposit paid online, when the
                customer comes back from paying it. With these they receive the device’s IP address
                and browser details, and they may set cookies. The tags run on no other page: not on
                private booking links, contact forms, quotes, invoices, the customer portal or staff
                pages, and the customer’s own booking page loads only Google Analytics, only for
                that deposit report. The Service never gives these tags names, email addresses,
                phone numbers, coupon codes or booking links, and the page address they are given
                never contains a booking link or a coupon code. Meta also offers a pixel setting,
                “automatic advanced matching”, that lets its code pick up contact details typed into
                a page; the booking settings ask shops to keep it off.
              </li>
              <li>
                A personal calendar feed link lets a team member see their jobs (or, for managers
                who choose it, every job of the shop), their own calendar events and the shop-wide
                ones such as closures, from a week back to 90 days ahead, in a calendar app such as
                Google Calendar, Apple Calendar or Outlook. That calendar provider then fetches and
                keeps a copy of the feed on its servers. Each job shows its time, number and
                services, the customer’s first name and last initial (or company name), the
                vehicle’s year, make and model, the service address (or the shop’s address) and a
                link to the job in the app; each event shows its time and title. Phone numbers,
                email addresses, prices and notes are never included.
              </li>
              <li>
                To verify a shop’s texting number, the business details the shop enters are sent to
                Twilio and the mobile carriers.
              </li>
            </LegalList>
            <p>
              Inside a shop, team members see information according to their role; technicians see
              only the jobs assigned to them. Booking, quote, invoice, form, job report, gift card
              and calendar feed links contain a long random code: anyone who has a link can open
              that one page, so shops send each link only to the person concerned, and can withdraw
              a job report or calendar link at any time.
            </p>
            <p>
              We may also disclose information when the law requires it, to protect the rights,
              safety or property of users or others, or as part of a merger, acquisition or sale of
              the Service, in which case this policy continues to apply to the information
              transferred.
            </p>
          </>
        ),
      },
      {
        id: 'messages',
        title: 'Texts, emails and your choices',
        body: (
          <LegalList>
            <li>
              Each shop texts its customers from its own number. Reply STOP (or STOPALL,
              UNSUBSCRIBE, CANCEL, END, QUIT, OPTOUT or REVOKE) to stop all texts from that shop’s
              number; reply START, UNSTOP or YES to receive them again. Your mobile carrier’s
              message and data rates may apply.
            </li>
            <li>
              Marketing texts and emails (campaigns and follow-ups) go only to customers who agreed
              to receive them from the shop. Marketing texts end with instructions to opt out, and
              marketing emails contain an unsubscribe link. Unsubscribing stops all emails from that
              shop to your address.
            </li>
            <li>
              Messages about your appointments and documents — such as booking confirmations,
              reminders, quotes, invoices and receipts — are sent to the contact details you gave
              the shop, unless you have opted out of that channel.
            </li>
            <li>
              Account emails (confirming your address, password resets and team invitations) are
              part of having an account and cannot be switched off.
            </li>
          </LegalList>
        ),
      },
      {
        id: 'retention',
        title: 'Keeping and deleting information',
        body: (
          <>
            <p>
              Information is kept for as long as the shop’s workspace or your account exists, unless
              it is deleted earlier.
            </p>
            <LegalSubheading>Deleting your account</LegalSubheading>
            <p>
              You can delete your account yourself: on the web on the Your account page, or in the
              iPhone app under More › Your account. This permanently deletes your sign-in and
              profile, removes you from every shop team and unlinks your customer portal. Records
              that shops keep for their business, such as appointments, invoices and payments, stay
              with those shops. If you were given a free trial, the record of it (with a scrambled
              form of your email address, described under “Shop subscriptions”) is kept without the
              link to your account. A shop owner must first transfer ownership of the shop or delete
              it.
            </p>
            <LegalSubheading>Deleting a shop</LegalSubheading>
            <p>
              A shop owner can delete the shop in the web app’s settings. The shop’s own
              subscription to the Service ends, open card payment links are expired and running
              membership subscriptions are cancelled first; then the shop and everything recorded in
              it — customers, vehicles, jobs, documents, payment records, messages and team
              memberships — are deleted, and the shop’s stored files (photos, videos, uploaded
              documents, signatures, logo and service images) are removed from file storage by an
              automatic clean-up job. The shop’s Stripe account belongs to the shop and is not
              closed. Photos, videos, documents and signatures of a deleted job, customer,
              inspection or form are removed the same way.
            </p>
            <p>
              Copies held by our providers — for example messages already delivered through Twilio
              or Resend, payment records in the shop’s Stripe account, subscription billing records
              in our Stripe account, and database backups kept by our hosting provider for a limited
              time — follow those providers’ own retention rules.
            </p>
          </>
        ),
      },
      {
        id: 'security',
        title: 'Security',
        body: (
          <p>
            All connections to the Service use HTTPS. Each shop’s information is kept apart from
            other shops’ by access rules enforced in the database, and each team member’s access
            depends on their role. Card numbers never reach our systems, and new accounts must
            confirm their email address. No system is perfectly secure: if you think your account
            was misused, change your password and contact us.
          </p>
        ),
      },
      {
        id: 'rights',
        title: 'Your rights',
        body: (
          <>
            <p>
              You can delete your account at any time (see above), and staff can update their name
              and mobile number in the iPhone app (More › Your account). To get a copy of your
              information, correct it or have it deleted, contact us; if it is a shop’s record about
              you as its customer, contact the shop.
            </p>
            <p>
              Depending on where you live — for example in the European Economic Area, the United
              Kingdom or US states such as California — you may have the right to access, correct,
              delete or receive a copy of your personal information, to object to or restrict
              certain uses, to withdraw consent, and to complain to a data-protection authority. We
              will not treat you differently for using these rights. We may need to confirm your
              identity before acting on a request.
            </p>
          </>
        ),
      },
      {
        id: 'children',
        title: 'Children',
        body: (
          <p>
            The Service is meant for businesses and their adult customers. It is not directed to
            children under 13 (or the higher age set by the law where you live), and we do not
            knowingly collect their personal information. If you believe a child has given us
            information, contact us and we will delete it.
          </p>
        ),
      },
      {
        id: 'transfers',
        title: 'Where information is processed',
        body: (
          <p>
            The Service’s data is stored with Supabase in the hosting region we chose for the
            Service. Our providers may process information in the United States and other countries,
            whose data-protection laws may differ from those where you live; where the law requires
            it, these transfers are protected by appropriate safeguards such as standard contractual
            clauses.
          </p>
        ),
      },
      {
        id: 'changes',
        title: 'Changes to this policy',
        body: (
          <p>
            We may update this policy when the Service or the law changes. The date at the top shows
            the current version. If a change significantly affects how we handle your information,
            we will tell you in the Service or by email before it applies.
          </p>
        ),
      },
      {
        id: 'contact',
        title: 'Contact us',
        body: contactDetails(operator, 'privacy questions and requests'),
      },
    ],
  };
}

export function termsOfService(operator: LegalOperator): LegalText {
  const name = operatorName(operator);
  return {
    intro: (
      <p>
        These terms are an agreement between you and {name} (“we”, “us”) for the use of Detail CRM
        (the “Service”). Please read them together with the Privacy Policy.
      </p>
    ),
    sections: [
      {
        id: 'agreement',
        title: 'Accepting these terms',
        body: (
          <>
            <p>
              By creating an account, joining a shop’s team or using the Service, you agree to these
              terms. If you use the Service for a business, you confirm that you may accept these
              terms on its behalf, and “you” includes that business. If you do not agree, do not use
              the Service.
            </p>
            <p>
              Customers of a shop who book online, open a link the shop sent them or use the
              customer portal may use those pages as these terms allow. Their agreement for the work
              on their vehicle is with the shop, not with us.
            </p>
          </>
        ),
      },
      {
        id: 'service',
        title: 'The Service',
        body: (
          <>
            <p>
              The Service is a web app and an iPhone app for {SHOP_KINDS}: online booking, calendar,
              customers and vehicles, quotes, invoices, card payments, text and email messages,
              photos, inspections, forms, memberships, time tracking and reports. We may change, add
              or remove features over time. Test versions (such as TestFlight builds) may contain
              errors.
            </p>
            <p>
              Where we charge shops for using the Service, we do so through the shop subscriptions
              described below; these terms do not set prices.
            </p>
          </>
        ),
      },
      {
        id: 'accounts',
        title: 'Accounts and roles',
        body: (
          <LegalList>
            <li>
              Give accurate information, confirm your email address and keep your password to
              yourself. You are responsible for what happens under your account; tell us promptly if
              you think it was misused.
            </li>
            <li>
              Each shop has one owner. The owner and admins manage the shop’s settings, card
              payments and team; managers run the day-to-day work; technicians see and work on the
              jobs assigned to them. The shop decides who joins its team and with which role, and
              removes people who should no longer have access.
            </li>
            <li>
              A shop cannot be left without an owner: before deleting their account, an owner
              transfers ownership to another team member or deletes the shop.
            </li>
            <li>
              You must be old enough to enter into a binding contract where you live to create an
              account.
            </li>
          </LegalList>
        ),
      },
      {
        id: 'shops',
        title: 'Your responsibilities as a shop',
        body: (
          <>
            <p>If you run a shop on the Service, you are responsible for:</p>
            <LegalList>
              <li>
                <Term>Your customers’ information:</Term> having the right to record it, telling
                your customers how you use it, and answering their requests to see, correct or
                delete it.
              </li>
              <li>
                <Term>Consent for texts and emails:</Term> getting and keeping any consent the law
                requires before you text or email customers, especially for marketing, and marking
                that consent accurately in the Service. The Service stops texts to a number that
                replied STOP and emails to an address that unsubscribed, and sends marketing only to
                customers marked as opted in.
              </li>
              <li>
                <Term>Texting registration:</Term> your texts are sent from a number registered for
                your shop with mobile carriers. Carriers may block messages until that registration
                is approved, or when they consider messages unwanted.
              </li>
              <li>
                <Term>Your prices, taxes and policies:</Term> the services, prices, discounts,
                deposits, tax rates, cancellation policy, quote and invoice terms and forms you
                publish are yours. The Service calculates totals and tax from your settings; you are
                responsible for checking them and for charging, reporting and paying the taxes that
                apply to you.
              </li>
              <li>
                <Term>Your work and your customers:</Term> the work you do and your agreements with
                your customers are between you and them.
              </li>
              <li>
                <Term>Your team:</Term> what your team members do in your workspace, and giving each
                of them only the role they need.
              </li>
              <li>
                <Term>Following the law:</Term> including the consumer-protection, privacy,
                anti-spam and telemarketing laws that apply to you.
              </li>
            </LegalList>
          </>
        ),
      },
      {
        id: 'payments',
        title: 'Payments through Stripe',
        body: (
          <LegalList>
            <li>
              Card payments use Stripe Connect. To take card payments, you connect your shop’s own
              Stripe account and accept Stripe’s terms for it, including its connected account
              agreement.
            </li>
            <li>
              Payments are made on your Stripe account: you are the merchant of record for every
              payment, and Stripe pays out to your bank account on the schedule set for your
              account. We do not hold your customers’ money.
            </li>
            <li>
              You are responsible for the refunds you give, for disputes (chargebacks) and their
              fees, and for any negative balance on your Stripe account. The Service records the
              outcome of a dispute but does not change what a customer owes because of it.
            </li>
            <li>
              Card payments may carry an application fee for us, collected by Stripe from each card
              payment. Whether one applies, and its amount, are agreed between you and us; these
              terms do not set it.
            </li>
            <li>
              Card and bank details are entered directly with Stripe. The Service stores only
              Stripe’s reference IDs, the card brand, the last four digits of the card or bank
              account and the expiry date of saved cards.
            </li>
            <li>
              Cash, check and other payments you record are your own records; the Service does not
              move that money.
            </li>
          </LegalList>
        ),
      },
      {
        id: 'subscriptions',
        title: 'Shop subscriptions',
        body: (
          <>
            <p>
              When we charge for the Service, each shop needs a subscription to keep creating new
              work. The subscription is between the shop and us, and is separate from the payments
              the shop’s customers make to the shop.
            </p>
            <LegalList>
              <li>
                <Term>Plans and prices:</Term> the plans, their prices, billing periods, any limit
                on team size and any free trial are shown on our{' '}
                <Link to={PRICING_PATH} className="text-primary-ink underline underline-offset-2">
                  pricing page
                </Link>{' '}
                and in the web app (Settings → Billing) before you subscribe. The amount you pay,
                including any taxes, is shown on Stripe’s checkout page before you confirm.
              </li>
              <li>
                <Term>Who manages it:</Term> only the shop owner can subscribe, change plans, update
                the payment method or cancel, in the web app, which opens Stripe’s secure pages.
                Subscription payments are processed by Stripe on our Stripe account; card details go
                directly to Stripe.
              </li>
              <li>
                <Term>Trial:</Term> a shop may start with a free trial of the length shown in the
                app, without entering a card. Each person gets one free trial: a shop created by an
                owner who already had one, on any shop (including a deleted one), starts without a
                trial and needs a subscription to add new work. If the owner subscribes with at
                least two days of the trial left, the first payment is due when the trial ends;
                otherwise it is due when the subscription starts.
              </li>
              <li>
                <Term>Renewal:</Term> a subscription renews automatically at the end of each billing
                period, and the payment method on file is charged for the next period, until the
                subscription is cancelled.
              </li>
              <li>
                <Term>Cancelling:</Term> the owner can cancel at any time in the billing portal
                (Settings → Billing → Manage billing). The cancellation takes effect at the end of
                the billing period already paid, and the shop keeps full use of the Service until
                then. Fees already paid are not refunded, except as stated at checkout or where the
                law requires it. Deleting the shop ends its subscription immediately.
              </li>
              <li>
                <Term>Failed payments:</Term> if a renewal payment fails, Stripe tries again and the
                shop keeps working in the meantime; the owner is notified. If the payment still
                cannot be collected once Stripe stops retrying, the subscription ends: the shop
                keeps full use until the end of the last billing period that was paid for (which may
                already have passed), and then the pause described under “When a subscription ends”
                applies.
              </li>
              <li>
                <Term>Team size:</Term> on a plan with a team limit, active team members and pending
                invitations count toward it, the owner included. Accepting an invitation that was
                already sent always works.
              </li>
              <li>
                <Term>When a subscription ends:</Term> when a trial ends without a subscription, or
                a subscription ends, nothing is deleted. The shop’s team can still sign in, view and
                export everything, finish existing jobs and collect payments on existing invoices
                and deposits. Until the shop subscribes again, creating new customers, jobs,
                repeating jobs, quotes, invoices and campaigns, sending new messages to customers,
                online booking, lead forms (and their automatic replies), selling memberships and
                gift cards (online and by the shop’s team), and scheduled automatic messages (such
                as reminders, review requests and follow-ups) and campaign sends are paused.
                Messages about existing work, such as job updates and receipts, still go out, and
                store credit earned from referrals and refunds to existing gift cards keep working.
              </li>
              <li>
                <Term>Free access:</Term> we may give a shop free use of the Service for a period;
                when it ends, the shop needs a subscription (or a trial still running) to keep
                creating new work.
              </li>
            </LegalList>
          </>
        ),
      },
      {
        id: 'acceptable-use',
        title: 'Acceptable use',
        body: (
          <>
            <p>Do not use the Service to:</p>
            <LegalList>
              <li>
                break the law or anyone’s rights, or text or email people who have not agreed to
                receive your messages;
              </li>
              <li>upload anything unlawful, infringing or harmful, including malware;</li>
              <li>
                access information of shops or people you are not allowed to see, get around roles,
                security measures or limits, or test the Service’s security without our written
                permission;
              </li>
              <li>
                overload, disrupt, scrape or copy the Service, or resell access to it without our
                permission;
              </li>
              <li>impersonate anyone or mislead people about who sent a message.</li>
            </LegalList>
          </>
        ),
      },
      {
        id: 'content',
        title: 'Your content and our Service',
        body: (
          <>
            <p>
              You keep all rights to the information and files you put into the Service. You allow
              us to host, copy, process and display them only as needed to provide, secure and
              support the Service for you, and as the Privacy Policy describes.
            </p>
            <p>
              The Service — its software, design and names — belongs to us or our licensors. These
              terms give you the right to use it while they apply, and no other rights. If you send
              us feedback, we may use it without owing you anything.
            </p>
          </>
        ),
      },
      {
        id: 'third-parties',
        title: 'Services from other companies',
        body: (
          <p>
            The Service relies on other companies, including Supabase, Stripe, Twilio, Resend,
            Cloudflare and Apple. Their services are governed by their own terms, and we are not
            responsible for their outages or actions. Links in the Service may open other sites or
            apps, such as maps, under their own terms.
          </p>
        ),
      },
      {
        id: 'termination',
        title: 'Ending use of the Service',
        body: (
          <LegalList>
            <li>
              You can stop using the Service at any time and delete your account in the apps. A shop
              owner can delete the shop in the web app’s settings, which permanently deletes the
              shop’s records and files as the Privacy Policy describes. Deleting cannot be undone,
              so keep copies of anything you still need.
            </li>
            <li>
              We may suspend or end your access if you break these terms, if your use puts the
              Service, other users or the public at risk, or if the law requires it. Where
              reasonable, we will tell you first and give you a chance to fix the problem.
            </li>
            <li>
              When your access ends, your right to use the Service ends. Parts of these terms that
              by their nature should continue, such as your responsibilities, the disclaimers, the
              limitation of liability and the governing law, continue to apply.
            </li>
          </LegalList>
        ),
      },
      {
        id: 'disclaimers',
        title: 'Disclaimers',
        body: (
          <p>
            The Service is provided “as is” and “as available”. To the extent the law allows, we
            make no warranties, express or implied, including of merchantability, fitness for a
            particular purpose and non-infringement. We do not promise that the Service will be
            uninterrupted or error-free, or that every text or email will be delivered (carriers and
            mailbox providers may filter or delay messages). Nothing in the Service is legal, tax or
            financial advice.
          </p>
        ),
      },
      {
        id: 'liability',
        title: 'Limitation of liability',
        body: (
          <p>
            To the extent the law allows, we are not liable for indirect, incidental, special,
            consequential or punitive damages, or for lost profits, revenue, data or goodwill,
            arising from the Service or these terms. Our total liability for all claims about the
            Service is limited to the amount you paid us for the Service in the twelve months before
            the event that led to the claim. Some places do not allow these limits, so they may not
            all apply to you; nothing in these terms limits liability that cannot be limited by law.
          </p>
        ),
      },
      {
        id: 'indemnity',
        title: 'Indemnity',
        body: (
          <p>
            If you use the Service for a business, you will defend and compensate us for claims,
            losses and costs (including reasonable legal fees) that come from your content, your
            dealings with your customers, the messages you send, or your breach of these terms or
            the law.
          </p>
        ),
      },
      {
        id: 'law',
        title: 'Governing law and disputes',
        body: (
          <>
            {operator.country ? (
              <p>
                These terms are governed by the laws of {operator.country}, without regard to
                conflict-of-laws rules, and disputes about them are decided by the courts there.
                Mandatory consumer-protection laws of the place where you live still apply to you.
              </p>
            ) : (
              <p>
                These terms are governed by the laws of the place where {name} is established,
                without regard to conflict-of-laws rules. Mandatory consumer-protection laws of the
                place where you live still apply to you.
              </p>
            )}
            <p>
              Before starting a formal dispute, please contact us so we can try to resolve it
              informally.
            </p>
          </>
        ),
      },
      {
        id: 'changes',
        title: 'Changes to these terms',
        body: (
          <p>
            We may update these terms. The date at the top shows the current version. If a change is
            significant, we will tell you in the Service or by email before it takes effect;
            continuing to use the Service after that means you accept the updated terms.
          </p>
        ),
      },
      {
        id: 'general',
        title: 'General',
        body: (
          <p>
            These terms, the Privacy Policy and any separate agreement about fees are the whole
            agreement between you and us about the Service. If part of these terms cannot be
            enforced, the rest still applies. Not enforcing a right does not waive it. You may not
            transfer these terms without our consent; we may transfer them as part of a merger,
            acquisition or sale of the Service.
          </p>
        ),
      },
      {
        id: 'contact',
        title: 'Contact',
        body: contactDetails(operator, 'questions about these terms'),
      },
    ],
  };
}
