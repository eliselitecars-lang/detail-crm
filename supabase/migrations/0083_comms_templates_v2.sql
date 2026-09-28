-- ============================================================================
-- 0083 — Templates v2: the generalised enqueue core, default wording for
-- EVERY template key (the comms range writes all wording, including money's
-- gift_card_delivery / referral_reward and ops' job_report), seeding of new
-- shops and backfill of existing ones.
--
-- New keys (0060, 0070, 0080) and their classification:
--   key                 channels     seeded    kind           sent by
--   quote_reminder      sms, email   disabled  transactional  document follow-ups (0085)
--   deposit_reminder    sms, email   disabled  transactional  document follow-ups (0085)
--   invoice_reminder    sms, email   disabled  transactional  document follow-ups (0085)
--   invoice_overdue     sms, email   disabled  transactional  document follow-ups (0085)
--   service_followup    sms, email   disabled  MARKETING      per-service follow-ups (0086); the
--                                                            template row is the shop's on/off
--                                                            switch per channel, the wording of
--                                                            each follow-up lives in
--                                                            service_followups
--   lead_received       sms, email   enabled   transactional  lead form auto-reply (0088): emailed,
--                                                            texted only to a verified phone;
--                                                            {{customer_first_name}} is "there"
--   job_report          sms, email   enabled   transactional  publish_job_report (ops 0072)
--   gift_card_delivery  email only   enabled   transactional  gift cards (money 0066)
--   referral_reward     sms, email   enabled   transactional  referral credit (money 0069)
-- Document follow-ups additionally need followup_settings (all off by
-- default); a follow-up goes out on each channel whose template is enabled.
--
-- New placeholders (in addition to those documented in 0032):
--   {{quote_number}}        quote number, e.g. 1001                     quote follow-ups
--   {{quote_total}}         quote total, e.g. $1,234.56                 quote follow-ups
--   {{valid_until}}         last day the quote is valid, e.g. June 30, 2025 (optional)
--   {{invoice_number}}      invoice number                              invoice follow-ups
--   {{due_date}}            invoice due date, e.g. June 30, 2025        invoice follow-ups (optional)
--   {{days_overdue}}        whole days past the due date                overdue notices
--   {{deposit_due}}         deposit still due, e.g. $50.00              deposit reminders
--   {{deposit_link}}        where to pay it: the booking page           deposit reminders
--   {{rebook_link}}         the shop's online booking page (a service follow-up preselects
--                           the service and vehicle size); only while online booking is on
--   {{report_link}}         the customer's job report                   job_report
--   {{gift_card_code}}, {{gift_card_amount}}, {{sender_name}}, {{recipient_name}},
--   {{gift_message}}        gift card delivery (money 0066)
--   {{credit_amount}}, {{referee_first_name}}
--                           referral reward (money 0069; {{gift_card_code}} is the credit code)
-- deposit_link, rebook_link and report_link are app links: a message using
-- them is never queued while app_base_url is unset (comms_uses_app_links).
-- A line that uses one of the new placeholders without a value is left out
-- of the message (comms_omit_lines_without, applied by the core), like the
-- optional values of 0033.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Classification helpers (replaced)
-- ---------------------------------------------------------------------------
create or replace function public.comms_uses_app_links(p_text text) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(p_text ~ '\{\{[ \t]*(booking_link|booking_page_link|quote_link|invoice_link|unsubscribe_link|deposit_link|rebook_link|report_link)[ \t]*\}\}',
                  false)
$$;

-- Marketing (promotional) keys: need the channel's marketing opt-in
-- (re-checked at send time), SMS carry the opt-out line, email the
-- unsubscribe link.
create or replace function public.comms_is_marketing_key(p_key public.message_template_key) returns boolean
language sql immutable
set search_path = ''
as $$ select coalesce(p_key::text in ('follow_up', 'service_followup'), false) $$;

-- ---------------------------------------------------------------------------
-- comms_job_vars (replaced): + {{rebook_link}} — the shop's online booking
-- page while online booking is on (a service follow-up overrides it with a
-- link that preselects the service, 0086). The job's invoice is its LIVE
-- invoice found through invoice_jobs (money 0063), so a job billed on a
-- grouped (fleet) invoice — invoices.job_id null, whole-invoice payments
-- without job_id — gets that invoice's link, total ({{amount}}) and
-- balance ({{balance}}), exactly what the /i page shows; a draft grouped
-- invoice is not the customer's yet, so the job's own total and payments
-- are used. Everything else is unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.comms_job_vars(p_job_id uuid) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_job       public.jobs;
  v_shop      public.shops;
  v_local     timestamp;
  v_vehicle   text;
  v_services  text;
  v_q_token   uuid;
  v_i_token   uuid;
  v_i_status  text;
  v_i_job     uuid;
  v_i_total   bigint;
  v_i_balance bigint;
  v_paid      bigint := 0;
  v_amount    bigint;
  v_balance   bigint;
  v_cust_vars jsonb;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    return null;
  end if;
  select * into v_shop from public.shops s where s.id = v_job.shop_id;

  if v_job.scheduled_start is not null then
    v_local := v_job.scheduled_start at time zone v_shop.timezone;
  end if;

  select nullif(btrim(concat_ws(' ', v.year::text, nullif(btrim(v.make), ''), nullif(btrim(v.model), ''))), '')
    into v_vehicle
    from public.vehicles v where v.id = v_job.vehicle_id and v.shop_id = v_job.shop_id;

  select string_agg(li.name, ', ' order by li.sort, li.created_at, li.id)
    into v_services
    from public.job_line_items li where li.job_id = v_job.id and li.shop_id = v_job.shop_id;

  if v_job.quote_id is not null and to_regclass('public.quotes') is not null then
    execute 'select q.public_token from public.quotes q
              where q.id = $1 and q.shop_id = $2 and q.status::text <> ''draft'''
      into v_q_token using v_job.quote_id, v_job.shop_id;
  end if;

  if to_regclass('public.invoice_jobs') is not null then
    -- the job's live invoice, single-job or grouped (at most one:
    -- invoice_jobs_one_live_invoice)
    execute 'select i.public_token, i.status::text, i.job_id, i.total_cents, i.balance_cents
               from public.invoice_jobs ij
               join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
              where ij.shop_id = $1 and ij.job_id = $2 and not ij.voided and i.status::text <> ''void''
              order by i.created_at desc limit 1'
      into v_i_token, v_i_status, v_i_job, v_i_total, v_i_balance using v_job.shop_id, v_job.id;
    if v_i_status = 'draft' and v_i_job is null then
      -- a draft grouped invoice: not sent, and its total is the whole group's
      v_i_token := null; v_i_status := null; v_i_total := null; v_i_balance := null;
    end if;
  end if;
  if to_regclass('public.payments') is not null then
    execute 'select coalesce(sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)), 0)
               from public.payments p where p.shop_id = $1 and p.job_id = $2'
      into v_paid using v_job.shop_id, v_job.id;
  end if;

  if v_i_status is not null and v_i_status <> 'draft' then
    v_amount := v_i_total;
    v_balance := greatest(v_i_balance, 0);
  else
    v_amount := coalesce(v_i_total, v_job.total_cents);
    v_balance := greatest(v_amount - coalesce(v_paid, 0), 0);
  end if;

  v_cust_vars := public.comms_customer_vars(v_job.shop_id, v_job.customer_id);
  return v_cust_vars || jsonb_build_object(
    'job_number', v_job.number::text,
    'job_date', to_char(v_local, 'FMDay, FMMonth FMDD'),
    'job_time', to_char(v_local, 'FMHH12:MI AM'),
    'vehicle', v_vehicle,
    'services', v_services,
    'booking_link', public.app_url('/booking/' || v_job.public_token::text),
    'quote_link', case when v_q_token is not null then public.app_url('/q/' || v_q_token::text) end,
    'invoice_link', case when v_i_token is not null and v_i_status <> 'draft'
                         then public.app_url('/i/' || v_i_token::text) end,
    'amount', public.format_money(v_amount, v_shop.currency),
    'balance', public.format_money(v_balance, v_shop.currency),
    'rebook_link', v_cust_vars -> 'booking_page_link');
end
$$;

-- ---------------------------------------------------------------------------
-- comms_omit_lines_without — p_text without the lines that use one of the
-- placeholders p_names while p_vars has no value for it (missing, null, an
-- object / array, or blank text); the blank line that set an omitted
-- paragraph apart goes with it (as comms_omit_unavailable_values does for
-- the 0033 optional values). Unchanged when nothing is missing; null for
-- null.
-- ---------------------------------------------------------------------------
create function public.comms_omit_lines_without(p_text text, p_vars jsonb, p_names text[]) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  c_re      constant text := '\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}';
  v_vars    jsonb := case when jsonb_typeof(p_vars) = 'object' then p_vars else '{}'::jsonb end;
  v_missing text[];
  v_out     text[] := '{}';
  v_line    text;
  v_omitted boolean := false;
begin
  if p_text is null or coalesce(cardinality(p_names), 0) = 0 then
    return p_text;
  end if;
  select coalesce(array_agg(n), '{}') into v_missing
    from unnest(p_names) as n
   where coalesce(jsonb_typeof(v_vars -> n), 'null') not in ('string', 'number', 'boolean')
      or btrim(v_vars ->> n) = '';
  if cardinality(v_missing) = 0
     or not exists (select 1 from regexp_matches(p_text, c_re, 'g') m where m[1] = any (v_missing)) then
    return p_text;
  end if;
  foreach v_line in array string_to_array(p_text, E'\n') loop
    if exists (select 1 from regexp_matches(v_line, c_re, 'g') m where m[1] = any (v_missing)) then
      v_omitted := true;
      continue;
    end if;
    if btrim(v_line, E' \t\r') = '' then
      continue when v_omitted and (cardinality(v_out) = 0 or btrim(v_out[cardinality(v_out)], E' \t\r') = '');
    else
      v_omitted := false;
    end if;
    v_out := v_out || v_line;
  end loop;
  return array_to_string(v_out, E'\n');
end
$$;

-- The optional placeholders of the v2 keys (see the header): a line using
-- one without a value is left out.
create function public.comms_v2_optional_vars() returns text[]
language sql immutable
set search_path = ''
as $$
  select array['quote_number', 'quote_total', 'valid_until', 'invoice_number', 'due_date', 'days_overdue',
               'deposit_due', 'deposit_link', 'rebook_link', 'report_link', 'gift_card_code', 'gift_card_amount',
               'sender_name', 'recipient_name', 'gift_message', 'credit_amount', 'referee_first_name']
$$;

-- ---------------------------------------------------------------------------
-- enqueue_message_core — INTERNAL (service_role and definer code; no caller
-- checks). The body of enqueue_customer_template (0033), generalised:
--   * the wording is passed in (p_tpl_subject / p_tpl_body: a template's, or
--     a per-service follow-up's); a null body means "no enabled wording" and
--     queues nothing (after the customer / job / document checks, so those
--     errors are raised exactly as before);
--   * p_quote_id / p_invoice_id record the document the message is about
--     (messages.quote_id / invoice_id); each must belong to the shop (P0002)
--     and to the customer (22023);
--   * the link a key exists to deliver is required: quote_sent /
--     quote_reminder {{quote_link}}, invoice_sent / invoice_reminder /
--     invoice_overdue {{invoice_link}}, review_request {{review_link}};
--   * lines using a v2 placeholder without a value are left out
--     (comms_omit_lines_without);
--   * marketing keys (follow_up, service_followup) are never queued for an
--     archived (soft-deleted) customer, like campaigns (0035); the send-time
--     check (comms_withdraw_reason, 0085) withdraws queued ones too.
-- Every other rule of 0033 applies unchanged: consent and suppressions,
-- marketing opt-in / opt-out line / unsubscribe link, app_base_url gating,
-- cancelled appointments, idempotent p_request_nonce.
-- ---------------------------------------------------------------------------
create function public.enqueue_message_core(
  p_shop_id        uuid,
  p_customer_id    uuid,
  p_key            public.message_template_key,
  p_channel        public.message_channel,
  p_tpl_subject    text,
  p_tpl_body       text,
  p_job_id         uuid default null,
  p_extra_vars     jsonb default null,
  p_send_after     timestamptz default null,
  p_sent_by        uuid default null,
  p_request_nonce  text default null,
  p_quote_id       uuid default null,
  p_invoice_id     uuid default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust     public.customers;
  v_shop     public.shops;
  v_job_cust uuid;
  v_job_st   public.job_status;
  v_doc_cust uuid;
  v_to       text;
  v_vars     jsonb;
  v_tpl_subj text;
  v_tpl_body text;
  v_subject  text;
  v_body     text;
  v_token    uuid;
  v_unsub    text;
  v_need     text;
  v_id       uuid;
  v_conname  text;
begin
  if p_shop_id is null or p_customer_id is null or p_key is null or p_channel is null then
    raise exception 'shop, customer, key and channel are required' using errcode = '22023';
  end if;
  if p_request_nonce is not null then
    if not public.comms_valid_request_nonce(p_request_nonce) then
      raise exception 'request_nonce must be 8-64 letters, digits, - or _' using errcode = '22023';
    end if;
    select m.id into v_id from public.messages m
     where m.shop_id = p_shop_id and m.sent_by is not distinct from p_sent_by and m.request_nonce = p_request_nonce;
    if found then
      return v_id;                          -- a retry of a send that already queued
    end if;
  end if;
  select * into v_cust from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if p_job_id is not null then
    select j.customer_id, j.status into v_job_cust, v_job_st
      from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id;
    if not found then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if v_job_cust <> p_customer_id then
      raise exception 'the job belongs to another customer' using errcode = '22023';
    end if;
    if v_job_st in ('cancelled', 'no_show') and public.comms_is_appointment_key(p_key) then
      return null;
    end if;
  end if;
  if p_quote_id is not null then
    select q.customer_id into v_doc_cust from public.quotes q where q.id = p_quote_id and q.shop_id = p_shop_id;
    if not found then
      raise exception 'quote not found' using errcode = 'P0002';
    end if;
    if v_doc_cust <> p_customer_id then
      raise exception 'the quote belongs to another customer' using errcode = '22023';
    end if;
  end if;
  if p_invoice_id is not null then
    select i.customer_id into v_doc_cust from public.invoices i where i.id = p_invoice_id and i.shop_id = p_shop_id;
    if not found then
      raise exception 'invoice not found' using errcode = 'P0002';
    end if;
    if v_doc_cust <> p_customer_id then
      raise exception 'the invoice belongs to another customer' using errcode = '22023';
    end if;
  end if;

  if nullif(btrim(coalesce(p_tpl_body, '')), '') is null then
    return null;                            -- no enabled wording
  end if;
  v_tpl_body := p_tpl_body;
  v_tpl_subj := case when p_channel = 'email' then p_tpl_subject end;
  -- never queue a message whose customer link would render blank
  if public.app_url('/') is null
     and (public.comms_uses_app_links(v_tpl_body) or (p_channel = 'email' and public.comms_uses_app_links(v_tpl_subj))) then
    return null;
  end if;
  select * into v_shop from public.shops s where s.id = p_shop_id;

  if p_channel = 'sms' then
    if v_cust.phone is null or v_cust.sms_opted_out_at is not null or v_shop.sms_from_number is null then
      return null;
    end if;
    v_to := v_cust.phone;
  else
    if v_cust.email is null or v_cust.email_opted_out_at is not null then
      return null;
    end if;
    v_to := v_cust.email::text;
  end if;
  if public.comms_is_suppressed(p_shop_id, p_channel, v_to) then
    return null;
  end if;
  if public.comms_is_marketing_key(p_key)
     and (v_cust.archived_at is not null
          or not (case p_channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end)) then
    return null;                            -- no promotions without consent, nor to an archived customer
  end if;

  v_vars := case when p_job_id is not null then public.comms_job_vars(p_job_id)
                 else public.comms_customer_vars(p_shop_id, p_customer_id) end;
  if jsonb_typeof(p_extra_vars) = 'object' then
    v_vars := v_vars || p_extra_vars;
  end if;
  v_need := case p_key::text when 'quote_reminder' then 'quote_link'
                             when 'invoice_reminder' then 'invoice_link'
                             when 'invoice_overdue' then 'invoice_link'
                             else public.comms_key_required_link(p_key) end;
  if v_need = any (public.comms_unavailable_links(
                     v_tpl_body || case when p_channel = 'email' then E'\n' || coalesce(v_tpl_subj, '') else '' end,
                     v_vars)) then
    return null;                            -- the message would be missing the link it exists to deliver
  end if;
  if p_channel = 'email' and public.comms_is_marketing_key(p_key) then
    v_token := gen_random_uuid();
    v_unsub := public.app_url('/u/' || v_token::text);
    if v_unsub is null then
      return null;                          -- no working unsubscribe link: never send marketing email without one
    end if;
    v_vars := v_vars || jsonb_build_object('unsubscribe_link', v_unsub);
  else
    v_vars := v_vars - 'unsubscribe_link';
  end if;

  v_tpl_body := public.comms_omit_lines_without(v_tpl_body, v_vars, public.comms_v2_optional_vars());
  v_tpl_subj := public.comms_omit_lines_without(v_tpl_subj, v_vars, public.comms_v2_optional_vars());
  select r.subject, r.body into v_subject, v_body
    from public.comms_render_parts(p_channel, v_tpl_subj, v_tpl_body, v_vars, v_shop.name) r;
  if v_body is null then
    return null;
  end if;
  if public.comms_is_marketing_key(p_key) then
    v_body := case p_channel when 'sms' then public.comms_sms_with_optout(v_body)
                             else public.comms_email_with_unsubscribe(v_body, v_unsub) end;
  end if;

  if p_request_nonce is null then
    insert into public.messages (shop_id, customer_id, job_id, quote_id, invoice_id, direction, channel, to_address,
                                 subject, body, status, send_after, template_key, sent_by, unsubscribe_token)
    values (p_shop_id, p_customer_id, p_job_id, p_quote_id, p_invoice_id, 'outbound', p_channel, v_to,
            v_subject, v_body, 'queued', coalesce(p_send_after, now()), p_key, p_sent_by, v_token)
    returning id into v_id;
    return v_id;
  end if;
  begin
    insert into public.messages (shop_id, customer_id, job_id, quote_id, invoice_id, direction, channel, to_address,
                                 subject, body, status, send_after, template_key, sent_by, unsubscribe_token,
                                 request_nonce)
    values (p_shop_id, p_customer_id, p_job_id, p_quote_id, p_invoice_id, 'outbound', p_channel, v_to,
            v_subject, v_body, 'queued', coalesce(p_send_after, now()), p_key, p_sent_by, v_token, p_request_nonce)
    returning id into v_id;
  exception when unique_violation then
    get stacked diagnostics v_conname = constraint_name;
    if v_conname is distinct from 'messages_request_nonce_key' then
      raise;
    end if;
    -- a concurrent retry with the same nonce won the race
    select m.id into v_id from public.messages m
     where m.shop_id = p_shop_id and m.sent_by is not distinct from p_sent_by and m.request_nonce = p_request_nonce;
  end;
  return v_id;
end
$$;

comment on function public.enqueue_message_core(uuid, uuid, public.message_template_key, public.message_channel, text, text,
                                                uuid, jsonb, timestamptz, uuid, text, uuid, uuid) is
  'Internal: render and queue one customer message from the given wording (see 0083). Returns the message id or null.';

-- ---------------------------------------------------------------------------
-- enqueue_customer_template (replaced; same signature and behaviour): the
-- shop's template for (key, channel) — its wording when it exists and is
-- enabled, else none — handed to enqueue_message_core.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_customer_template(
  p_shop_id        uuid,
  p_customer_id    uuid,
  p_key            public.message_template_key,
  p_channel        public.message_channel default 'sms',
  p_job_id         uuid default null,
  p_extra_vars     jsonb default null,
  p_send_after     timestamptz default null,
  p_sent_by        uuid default null,
  p_request_nonce  text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tpl public.message_templates;
begin
  select * into v_tpl from public.message_templates t
   where t.shop_id = p_shop_id and t.key = p_key and t.channel = p_channel and t.enabled;
  return public.enqueue_message_core(p_shop_id, p_customer_id, p_key, p_channel, v_tpl.subject, v_tpl.body,
                                     p_job_id, p_extra_vars, p_send_after, p_sent_by, p_request_nonce);
end
$$;

-- ---------------------------------------------------------------------------
-- default_message_templates (replaced): every key of message_template_key.
-- The 0032 rows are unchanged; the v2 rows follow the same style (every
-- optional value on a line of its own the message reads well without).
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
     E'Hi {{customer_first_name}}, welcome to your {{shop_name}} membership! We are glad to have you.\nQuestions? Call {{shop_phone}}.',
     true, null),
    ('membership_welcome', 'email', 'Welcome to your membership - {{shop_name}}',
     E'Hi {{customer_first_name}},\n\nWelcome to your {{shop_name}} membership! We are glad to have you.\n\nWhenever you are ready for your next visit, book here: {{booking_page_link}}\n\nQuestions? Call us at {{shop_phone}}.\n\n{{shop_name}}',
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
-- shops_seed_comms (replaced): a new shop gets every default template and
-- its follow-up settings (all off).
-- ---------------------------------------------------------------------------
create or replace function public.shops_seed_comms() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.message_templates (shop_id, key, channel, subject, body, enabled, offset_minutes)
  select new.id, d.key, d.channel, d.subject, d.body, d.enabled, d.offset_minutes
  from public.default_message_templates() d
  on conflict (shop_id, key, channel) do nothing;
  insert into public.followup_settings (shop_id) values (new.id) on conflict (shop_id) do nothing;
  return null;
end
$$;

-- Existing shops get the new templates (missing key / channel rows only;
-- nothing a shop edited is touched). followup_settings were backfilled in
-- 0081.
insert into public.message_templates (shop_id, key, channel, subject, body, enabled, offset_minutes)
select s.id, d.key, d.channel, d.subject, d.body, d.enabled, d.offset_minutes
from public.shops s cross join public.default_message_templates() d
on conflict (shop_id, key, channel) do nothing;

-- ---------------------------------------------------------------------------
-- reset_message_template (replaced): also resets the reminder offsets
-- (appointment_reminder back to its single default offset).
-- ---------------------------------------------------------------------------
create or replace function public.reset_message_template(p_template_id uuid) returns public.message_templates
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t public.message_templates;
  v_d record;
begin
  select * into v_t from public.message_templates t where t.id = p_template_id for update;
  if not found or not public.is_shop_manager(v_t.shop_id) then
    raise exception 'template not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_t.shop_id) then
    raise exception 'only owners and admins can edit message templates' using errcode = '42501';
  end if;
  select * into v_d from public.default_message_templates() d where d.key = v_t.key and d.channel = v_t.channel;
  if not found then
    raise exception 'there is no default wording for % %', v_t.key, v_t.channel using errcode = 'P0002';
  end if;
  update public.message_templates t
     set subject = v_d.subject, body = v_d.body, enabled = v_d.enabled, offset_minutes = v_d.offset_minutes,
         reminder_offsets_minutes = null
   where t.id = v_t.id
  returning * into v_t;
  return v_t;
end
$$;

-- ---------------------------------------------------------------------------
-- public_unsubscribe (0035; replaced, same signature and grants): the
-- opt-out belongs to the ADDRESS the email went to, never to whichever
-- customer the message points at today. comms_suppress already stamps every
-- customer of the shop whose CURRENT email is that address (and withdraws
-- queued email to it); the 0035 version additionally stamped the message's
-- customer, whose email may have changed since, or who may be the survivor
-- of a merge (merge_customers, 0074, moves the duplicate's messages and so
-- its unsubscribe links). That stamp then suppressed the customer's current,
-- different address through customers_comms_optout_sync and blocked all of
-- their email, transactional included, although nobody at that address
-- asked. A customer whose email is no longer the link's address is left
-- untouched: the previous address stays suppressed, so moving back to it
-- opts them out again (customers_comms_suppressed).
-- ---------------------------------------------------------------------------
create or replace function public.public_unsubscribe(p_token uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tok public.comms_unsubscribe_tokens;
begin
  if p_token is null then
    return false;
  end if;
  select * into v_tok from public.comms_unsubscribe_tokens t where t.token = p_token;
  if not found then
    return false;
  end if;
  perform public.comms_suppress(v_tok.shop_id, 'email', v_tok.address, now());
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.comms_omit_lines_without(text, jsonb, text[]),
  public.comms_v2_optional_vars()
from public, anon;
grant execute on function
  public.comms_omit_lines_without(text, jsonb, text[]),
  public.comms_v2_optional_vars()
to authenticated, service_role;

revoke execute on function
  public.enqueue_message_core(uuid, uuid, public.message_template_key, public.message_channel, text, text,
                              uuid, jsonb, timestamptz, uuid, text, uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.enqueue_message_core(uuid, uuid, public.message_template_key, public.message_channel, text, text,
                              uuid, jsonb, timestamptz, uuid, text, uuid, uuid)
to service_role;
