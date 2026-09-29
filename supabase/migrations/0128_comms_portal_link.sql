-- ============================================================================
-- 0128 — {{portal_link}}: customer messages can point to the client portal,
-- and the membership welcome says how to manage or cancel.
--
-- The client portal (/portal) already lets a customer cancel a membership,
-- update the card, see visits, documents and reports
-- (portal_membership_cancel, web features/portal), but no message could
-- link to it and the membership_welcome default never said how to manage
-- or cancel the membership — the acknowledgement automatic-renewal laws
-- expect to carry the cancellation route.
--
--   * {{portal_link}} (customer-level, every template and campaign):
--     APP_BASE_URL/portal?shop=<shop slug> — the same base as every other
--     customer link (app_url). The portal page is /portal (it lists every
--     shop the signed-in client is a customer of; the shop parameter names
--     the shop the message came from). Null while app_base_url is unset,
--     like the other app links (comms_uses_app_links: a message using it is
--     then never queued).
--   * portal_link is an optional placeholder (comms_v2_optional_vars): a
--     line using it without a value is left out (comms_omit_lines_without).
--   * default membership_welcome, SMS and email: + "Manage or cancel your
--     membership any time in your account: {{portal_link}}". Rows still on
--     the 0083 default wording are updated to the new default (subject and
--     body both unchanged by the shop); edited rows are left alone and
--     "Reset to default" (reset_message_template) brings the new wording.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- comms_customer_vars (0033 body) + portal_link
-- ---------------------------------------------------------------------------
create or replace function public.comms_customer_vars(p_shop_id uuid, p_customer_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'customer_first_name', case when c.id is null then null
                                else coalesce(nullif(btrim(c.first_name), ''), nullif(btrim(c.company), ''),
                                              nullif(btrim(c.last_name), ''), 'there') end,
    'customer_name', coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(c.first_name), ''),
                                                          nullif(btrim(c.last_name), ''))), ''),
                              nullif(btrim(c.company), '')),
    'shop_name', s.name,
    'shop_phone', public.format_phone(s.phone),
    'review_link', nullif(btrim(s.review_url), ''),
    -- only while the page has something to book (public_booking_catalog
    -- refuses a shop whose online booking is off)
    'booking_page_link', case when b.enabled then public.app_url('/book/' || s.slug) end,
    -- 0128: the client portal, opened on this shop (sign-in first)
    'portal_link', public.app_url('/portal?shop=' || s.slug))
  from public.shops s
  left join public.booking_settings b on b.shop_id = s.id
  left join public.customers c on c.shop_id = s.id and c.id = p_customer_id
  where s.id = p_shop_id
$$;

-- ---------------------------------------------------------------------------
-- optional placeholders (0083) + portal_link; app links (0083) + portal_link
-- ---------------------------------------------------------------------------
create or replace function public.comms_v2_optional_vars() returns text[]
language sql immutable
set search_path = ''
as $$
  select array['quote_number', 'quote_total', 'valid_until', 'invoice_number', 'due_date', 'days_overdue',
               'deposit_due', 'deposit_link', 'rebook_link', 'report_link', 'gift_card_code', 'gift_card_amount',
               'sender_name', 'recipient_name', 'gift_message', 'credit_amount', 'referee_first_name',
               'portal_link']
$$;

create or replace function public.comms_uses_app_links(p_text text) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(p_text ~ '\{\{[ \t]*(booking_link|booking_page_link|quote_link|invoice_link|unsubscribe_link|deposit_link|rebook_link|report_link|portal_link)[ \t]*\}\}',
                  false)
$$;

-- ---------------------------------------------------------------------------
-- default_message_templates (0083 body): membership_welcome manage / cancel
-- ---------------------------------------------------------------------------
create or replace function public.default_message_templates()
returns table (key public.message_template_key, channel public.message_channel, subject text, body text,
               enabled boolean, offset_minutes integer)
language sql immutable
set search_path = ''
as $$
  select v.key::public.message_template_key, v.channel::public.message_channel, v.subject, v.body, v.enabled,
         v.offset_minutes
  from (values
    ('booking_request_received', 'sms', null::text,
     'Hi {{customer_first_name}}, thanks for your booking request with {{shop_name}} for {{job_date}} at {{job_time}}. We''ll review it and confirm shortly. Details: {{booking_link}}',
     true, null::integer),
    ('booking_request_received', 'email', 'We received your booking request - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThanks for requesting an appointment with {{shop_name}}. Here is what we received:\n\nDate: {{job_date}}\nTime: {{job_time}}\nVehicle: {{vehicle}}\nServices: {{services}}\n\nWe''ll review your request and confirm shortly. You can view or manage your booking here: {{booking_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('booking_confirmed', 'sms', null,
     'Hi {{customer_first_name}}, your appointment with {{shop_name}} is confirmed for {{job_date}} at {{job_time}}. Manage your booking: {{booking_link}}',
     true, null),
    ('booking_confirmed', 'email', 'Your appointment is confirmed - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nYour appointment with {{shop_name}} is confirmed.\n\nDate: {{job_date}}\nTime: {{job_time}}\nVehicle: {{vehicle}}\nServices: {{services}}\n\nView or manage your booking here: {{booking_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('appointment_reminder', 'sms', null,
     E'Reminder: your appointment with {{shop_name}} is on {{job_date}} at {{job_time}}. Need to make a change? Visit {{booking_link}}\nQuestions? Call {{shop_phone}}.',
     true, -1440),
    ('appointment_reminder', 'email', 'Appointment reminder - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThis is a friendly reminder of your upcoming appointment with {{shop_name}}.\n\nDate: {{job_date}}\nTime: {{job_time}}\nVehicle: {{vehicle}}\nServices: {{services}}\n\nNeed to make a change? Visit {{booking_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, -1440),
    ('on_the_way', 'sms', null,
     'Hi {{customer_first_name}}, your technician from {{shop_name}} is on the way. See you soon!',
     true, null),
    ('job_started', 'sms', null,
     'Hi {{customer_first_name}}, we have started work on your vehicle. We''ll let you know as soon as it''s ready. - {{shop_name}}',
     true, null),
    ('job_completed', 'sms', null,
     'Hi {{customer_first_name}}, your vehicle is all done! Thank you for choosing {{shop_name}}.',
     true, null),
    ('job_completed', 'email', 'Your vehicle is ready - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nGood news: the work on your vehicle is complete.\n\nVehicle: {{vehicle}}\nServices: {{services}}\n\nThank you for choosing {{shop_name}}.\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('quote_sent', 'sms', null,
     'Hi {{customer_first_name}}, {{shop_name}} sent you a quote. Review and approve it here: {{quote_link}}',
     true, null),
    ('quote_sent', 'email', 'Your quote from {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you for your interest in {{shop_name}}. Your quote is ready for review.\n\nReview and approve it here: {{quote_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('invoice_sent', 'sms', null,
     'Hi {{customer_first_name}}, here is your invoice from {{shop_name}}. Balance due: {{balance}}. View and pay online: {{invoice_link}}',
     true, null),
    ('invoice_sent', 'email', 'Your invoice from {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you for your business. Your invoice from {{shop_name}} is ready.\n\nTotal: {{amount}}\nBalance due: {{balance}}\n\nView and pay online: {{invoice_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('payment_receipt', 'sms', null,
     E'Thank you, {{customer_first_name}}! {{shop_name}} received your payment of {{amount}}.\nRemaining balance: {{balance}}.',
     true, null),
    ('payment_receipt', 'email', 'Payment received - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you! We received your payment of {{amount}}.\n\nRemaining balance: {{balance}}\n\nView your invoice: {{invoice_link}}\n\n{{shop_name}}',
     true, null),
    ('review_request', 'sms', null,
     'Hi {{customer_first_name}}, thank you for choosing {{shop_name}}! If you have a moment, we would really appreciate a review: {{review_link}}',
     true, 120),
    ('review_request', 'email', 'How did we do? - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you for choosing {{shop_name}}. We hope you love the results!\n\nIf you have a moment, we would really appreciate a review: {{review_link}}\n\nThank you,\n{{shop_name}}',
     true, 120),
    ('follow_up', 'sms', null,
     'Hi {{customer_first_name}}, it has been a while since your last visit to {{shop_name}}. Ready to keep your vehicle looking its best? Book here: {{booking_page_link}}',
     false, 43200),
    ('follow_up', 'email', 'Time for your next visit? - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nIt has been a while since your last visit to {{shop_name}}. Regular care keeps your vehicle protected and looking its best.\n\nBook your next appointment here: {{booking_page_link}}\n\n{{shop_name}}',
     false, 43200),
    ('membership_welcome', 'sms', null,
     E'Hi {{customer_first_name}}, welcome to your {{shop_name}} membership! We are glad to have you.\nManage or cancel your membership any time in your account: {{portal_link}}\nQuestions? Call {{shop_phone}}.',
     true, null),
    ('membership_welcome', 'email', 'Welcome to your membership - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nWelcome to your {{shop_name}} membership! We are glad to have you.\n\nWhenever you are ready for your next visit, book here: {{booking_page_link}}\n\nManage or cancel your membership any time in your account: {{portal_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('invite', 'email', 'You are invited to join {{shop_name}}',
     E'Hello,\n\nYou have been invited to join the {{shop_name}} team.\n\nAccept your invitation here: {{invite_link}}\n\nThis invitation expires in 7 days. If you were not expecting it, you can ignore this email.',
     true, null),
    -- ---------------------------------------------------------------- v2 (0083)
    ('quote_reminder', 'sms', null,
     E'Hi {{customer_first_name}}, just a reminder that your quote from {{shop_name}} is ready for review.\nReview and approve it here: {{quote_link}}',
     false, null),
    ('quote_reminder', 'email', 'A reminder about your quote - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nJust a friendly reminder that your quote from {{shop_name}} is ready for review.\n\nQuote #{{quote_number}}\nTotal: {{quote_total}}\nValid until: {{valid_until}}\n\nReview and approve it here: {{quote_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     false, null),
    ('deposit_reminder', 'sms', null,
     E'Hi {{customer_first_name}}, a deposit is still needed to hold your appointment with {{shop_name}}.\nAppointment: {{job_date}} at {{job_time}}\nDeposit due: {{deposit_due}}\nPay securely here: {{deposit_link}}',
     false, null),
    ('deposit_reminder', 'email', 'Deposit reminder - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nA deposit is still needed to hold your appointment with {{shop_name}}.\n\nDate: {{job_date}}\nTime: {{job_time}}\nVehicle: {{vehicle}}\nServices: {{services}}\nDeposit due: {{deposit_due}}\n\nPay securely here: {{deposit_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     false, null),
    ('invoice_reminder', 'sms', null,
     E'Hi {{customer_first_name}}, a friendly reminder from {{shop_name}} about invoice #{{invoice_number}}.\nBalance due: {{balance}}\nDue date: {{due_date}}\nView and pay online: {{invoice_link}}',
     false, null),
    ('invoice_reminder', 'email', 'Reminder: invoice #{{invoice_number}} from {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThis is a friendly reminder about your invoice from {{shop_name}}.\n\nInvoice #{{invoice_number}}\nBalance due: {{balance}}\nDue date: {{due_date}}\n\nView and pay online: {{invoice_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     false, null),
    ('invoice_overdue', 'sms', null,
     E'Hi {{customer_first_name}}, invoice #{{invoice_number}} from {{shop_name}} is past due.\nBalance due: {{balance}}\nDue date: {{due_date}}\nPay online: {{invoice_link}}',
     false, null),
    ('invoice_overdue', 'email', 'Past due: invoice #{{invoice_number}} from {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nOur records show that your invoice from {{shop_name}} is past due. If you have already paid, thank you and please disregard this message.\n\nInvoice #{{invoice_number}}\nBalance due: {{balance}}\nDue date: {{due_date}}\nDays past due: {{days_overdue}}\n\nPay online: {{invoice_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     false, null),
    ('service_followup', 'sms', null,
     E'Hi {{customer_first_name}}, it is about time for your next visit to {{shop_name}} to keep your vehicle protected.\nBook here: {{rebook_link}}',
     false, null),
    ('service_followup', 'email', 'Time for your next service? - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nIt is about time for your next visit to {{shop_name}}. Regular care keeps your vehicle protected and looking its best.\n\nBook your next appointment here: {{rebook_link}}\n\n{{shop_name}}',
     false, null),
    ('lead_received', 'sms', null,
     E'Hi {{customer_first_name}}, thanks for reaching out to {{shop_name}}! We received your request and will get back to you shortly.\nQuestions? Call {{shop_phone}}.',
     true, null),
    ('lead_received', 'email', 'We received your request - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThanks for reaching out to {{shop_name}}! We received your request and will get back to you shortly.\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('job_report', 'sms', null,
     'Hi {{customer_first_name}}, your job report from {{shop_name}} is ready. See the photos and details here: {{report_link}}',
     true, null),
    ('job_report', 'email', 'Your job report from {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you for choosing {{shop_name}}. Your job report is ready, with the photos and details of the work.\n\nVehicle: {{vehicle}}\nServices: {{services}}\n\nView your report here: {{report_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('gift_card_delivery', 'email', 'A gift card from {{sender_name}}',
     E'Hi {{customer_first_name}},\n\n{{sender_name}} sent you a {{shop_name}} gift card worth {{gift_card_amount}}.\n\n{{gift_message}}\n\nYour gift card code: {{gift_card_code}}\n\nShow this code when you pay, or enter it when paying an invoice online.\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
     true, null),
    ('referral_reward', 'sms', null,
     E'Hi {{customer_first_name}}, thank you for referring a friend to {{shop_name}}! You earned store credit: {{credit_amount}}.\nYour credit code: {{gift_card_code}}',
     true, null),
    ('referral_reward', 'email', 'Thank you for your referral - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nThank you for referring a friend to {{shop_name}}!\n\n{{referee_first_name}} just completed their first visit with us.\n\nYou earned store credit: {{credit_amount}}\nYour credit code: {{gift_card_code}}\n\nShow this code when you pay, or enter it when paying an invoice online.\n\n{{shop_name}}',
     true, null)
  ) as v(key, channel, subject, body, enabled, offset_minutes)
$$;

-- ---------------------------------------------------------------------------
-- Existing shops: membership_welcome rows still on the 0083 default wording
-- take the new default (a shop's own wording is never touched).
-- ---------------------------------------------------------------------------
update public.message_templates t
   set body = d.body
  from public.default_message_templates() d
 where t.key = 'membership_welcome' and d.key = t.key and d.channel = t.channel
   and t.subject is not distinct from d.subject
   and t.body = case t.channel
                  when 'sms' then E'Hi {{customer_first_name}}, welcome to your {{shop_name}} membership! We are glad to have you.\nQuestions? Call {{shop_phone}}.'
                  else E'Hi {{customer_first_name}},\n\nWelcome to your {{shop_name}} membership! We are glad to have you.\n\nWhenever you are ready for your next visit, book here: {{booking_page_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}'
                end;
