/**
 * Wording of /privacy and /terms. Every statement describes what this code
 * base actually does (data model: docs/SCHEMA.md; providers: SPEC §1 and
 * §5; deletion: the `account` and `storage-purge` functions and the
 * `payments` delete_shop action). When the product changes what it collects,
 * who receives it or how deletion works, change this file in the same
 * commit and bump LEGAL_LAST_UPDATED (operator.ts). Operator details come
 * only from the build-time VITE_LEGAL_* values; nothing is made up when they
 * are missing. The operator reviews the text with counsel (docs/LAUNCH.md).
 */
import type { ReactNode } from 'react';
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
              <Term>Jobs and documents:</Term> appointments (date, time, service address, services,
              prices, notes and status history), checklists, inspections (damage marks, mileage,
              fuel level, notes), quotes (including the name typed to approve one), invoices,
              payments and memberships.
            </li>
            <li>
              <Term>Photos and signatures:</Term> before-and-after and inspection photos, and
              signatures customers draw on inspections and forms. They are kept in private file
              storage that only the shop’s team can open, according to their role. Shop logos and
              service images are public, because they appear on the shop’s booking pages. When a
              customer signs a form, the typed name, the time and the IP address of the signing
              device are recorded as evidence of the signature.
            </li>
            <li>
              <Term>Messages:</Term> texts and emails sent to customers (recipient, content and
              delivery status), customers’ text replies to the shop’s number, campaign recipients,
              and in-app notifications for staff.
            </li>
            <li>
              <Term>Payments:</Term> card payments are processed by Stripe. Card numbers are entered
              on Stripe’s payment page on the web or in Stripe’s payment form in the iPhone app and
              go directly to Stripe; the Service never receives or stores them. We keep only
              Stripe’s reference IDs, the card brand, the last four digits and, for saved cards, the
              expiry month and year, together with amounts, tips, refunds and the outcome of any
              dispute. Cash, check and other payments are recorded by staff.
            </li>
            <li>
              <Term>Time tracking:</Term> when staff clock in and out, the job the time belongs to,
              and notes.
            </li>
            <li>
              <Term>Online booking:</Term> what a customer enters when booking: name, email, phone,
              vehicle, service address, notes, the chosen services and time, a coupon code and
              marketing choices.
            </li>
            <li>
              <Term>Customer portal:</Term> customers who create a portal account sign in with an
              email address and password; once that address is confirmed, the portal shows the
              records shops keep under it.
            </li>
            <li>
              <Term>Devices and connections:</Term> the web app keeps your sign-in session and a few
              preferences (theme, last shop used, sidebar state) in your browser’s local storage,
              and uses no advertising or analytics cookies. The iPhone app keeps your sign-in
              session and the shop you last chose on the device; it uses the camera and photo
              library only when you take or attach a photo, and it does not access your location.
              Our hosting providers process IP addresses and request details to deliver the Service,
              keep it secure and fix problems.
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
                To keep the Service secure, prevent abuse and fraud, and find and fix problems.
              </li>
              <li>To meet legal obligations and enforce our terms.</li>
            </LegalList>
            <p>
              We do not sell personal information, we do not share it for targeted advertising, we
              do not show ads, and neither app contains advertising or analytics trackers.
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
                Stripe may also collect device information to prevent fraud.
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
                crash reports you choose to share with app developers.
              </li>
              <li>
                <Term>Google Fonts</Term> provides the web app’s typeface, so your browser sends
                Google its IP address and browser details when a page loads.
              </li>
              <li>
                <Term>NHTSA</Term> (the US National Highway Traffic Safety Administration): when
                staff decode a VIN, only the VIN is sent to NHTSA’s public vehicle database to look
                up the year, make and model.
              </li>
            </LegalList>
            <p>
              Map buttons open Apple Maps or Google Maps with an address only when you tap them.
            </p>
            <p>
              Inside a shop, team members see information according to their role; technicians see
              only the jobs assigned to them. Booking, quote, invoice and form links contain a long
              random code: anyone who has a link can open that one page, so shops send each link
              only to the customer concerned.
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
              with those shops. A shop owner must first transfer ownership of the shop or delete it.
            </p>
            <LegalSubheading>Deleting a shop</LegalSubheading>
            <p>
              A shop owner can delete the shop in the web app’s settings. Open card payment links
              are expired and running membership subscriptions are cancelled first; then the shop
              and everything recorded in it — customers, vehicles, jobs, documents, payment records,
              messages and team memberships — are deleted, and the shop’s stored files (photos,
              signatures, logo and service images) are removed from file storage by an automatic
              clean-up job. The shop’s Stripe account belongs to the shop and is not closed. Photos
              and signatures of a deleted job, inspection or form are removed the same way.
            </p>
            <p>
              Copies held by our providers — for example messages already delivered through Twilio
              or Resend, payment records in the shop’s Stripe account, and database backups kept by
              our hosting provider for a limited time — follow those providers’ own retention rules.
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
              Any fees for using the Service are agreed separately between you and us; these terms
              do not set prices.
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
              Card numbers are entered directly with Stripe. The Service stores only Stripe’s
              reference IDs, the card brand, the last four digits and the expiry date of saved
              cards.
            </li>
            <li>
              Cash, check and other payments you record are your own records; the Service does not
              move that money.
            </li>
          </LegalList>
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
