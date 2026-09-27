-- ============================================================================
-- 0032 — Message templates (SPEC §4.7) and the template renderer.
--
-- One row per (shop, key, channel). Every shop is seeded with generic,
-- professional default wording (AFTER INSERT ON shops); admins edit, disable
-- or reset them; managers read them. Time-based keys carry offset_minutes:
--   appointment_reminder  minutes relative to scheduled_start (≤ 0; default −1440 = 24 h before)
--   review_request        minutes after completed_at (≥ 0; default 120)
--   follow_up             minutes after completed_at (≥ 0; default 43200 = 30 days)
-- All channels of one key share one offset (kept in sync by trigger), so an
-- automation fires once per job and delivers on every enabled channel.
--
-- Placeholders ({{name}}; unknown ones render as empty text; for missing
-- optional values see "Unavailable links and values" below):
--   {{customer_first_name}}  first name (else company, else last name, else "there")
--   {{customer_name}}        full name (else company)
--   {{shop_name}}            shop name
--   {{shop_phone}}           shop phone, e.g. (205) 555-0100
--   {{job_date}}             appointment date in the shop time zone, e.g. Monday, June 2
--   {{job_time}}             appointment start time in the shop time zone, e.g. 10:00 AM
--   {{job_number}}           job number, e.g. 1001
--   {{vehicle}}              job vehicle, e.g. 2021 Honda Civic
--   {{services}}             job line item names, comma separated
--   {{booking_link}}         link to the customer's booking page  (/booking/<job token>)
--   {{booking_page_link}}    link to the shop's online booking page (/book/<shop slug>);
--                            only while the shop's online booking is on
--   {{quote_link}}           link to the job's quote (/q/<quote token>); once the quote was sent
--   {{invoice_link}}         link to the job's invoice (/i/<invoice token>); once it was issued
--   {{review_link}}          the shop's review URL; once the shop set one
--   {{amount}}               invoice total (else job total), e.g. $1,234.56
--   {{balance}}              balance still due, e.g. $0.00
--   {{invite_link}}          staff invite link (invite template; supplied by the sender)
--   {{unsubscribe_link}}     email unsubscribe link (/u/<token>) of marketing email: campaigns and
--                            follow_up; where the wording does not place it, it is appended as a
--                            footer. Renders empty in SMS and transactional email.
-- Callers of enqueue_customer_template may override/add variables.
-- Unavailable links and values (0033 comms_omit_unavailable_values): a line
-- of a message whose link placeholder (booking_link, booking_page_link,
-- quote_link, invoice_link, review_link) or optional value placeholder
-- (shop_phone, customer_name, job_date, job_time, job_number, vehicle,
-- services, amount, balance) has no value is left out of it, so e.g. a
-- deposit receipt (no invoice yet) omits "View your invoice: …", a
-- membership welcome omits "book here: …" while online booking is off, and
-- a shop without a phone number sends no "Questions? Call us at ." line;
-- quote_sent, invoice_sent and review_request are not sent at all without
-- their quote / invoice / review link (comms_key_required_link). The
-- default wording therefore keeps every optional value on a line of its
-- own that the message reads well without ("Vehicle: …", "Questions? Call
-- …") and never builds its main sentence on one.
-- ============================================================================

create table public.message_templates (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops (id) on delete cascade,
  key             public.message_template_key not null,
  channel         public.message_channel not null,
  subject         text,
  body            text not null,
  enabled         boolean not null default true,
  offset_minutes  integer,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint message_templates_shop_id_id_key unique (shop_id, id),
  constraint message_templates_shop_key_channel_key unique (shop_id, key, channel),
  constraint message_templates_body check (
    char_length(btrim(body)) >= 1
    and char_length(body) <= case channel when 'sms' then 1600 else 20000 end),
  constraint message_templates_subject check (
    case channel
      when 'sms' then subject is null
      else subject is not null and char_length(btrim(subject)) between 1 and 200
    end),
  constraint message_templates_offset check (
    case key
      when 'appointment_reminder' then offset_minutes is not null and offset_minutes between -43200 and 0
      when 'review_request'       then offset_minutes is not null and offset_minutes between 0 and 525600
      when 'follow_up'            then offset_minutes is not null and offset_minutes between 0 and 525600
      else offset_minutes is null
    end),
  constraint message_templates_invite_email check (key <> 'invite' or channel = 'email')
);

comment on table public.message_templates is
  'Per-shop message wording. Placeholders are documented in migration 0032 and render_template().';

-- ---------------------------------------------------------------------------
-- Default wording (single source for seeding and reset_message_template).
-- ---------------------------------------------------------------------------
create function public.default_message_templates()
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
     true, null)
  ) as v(key, channel, subject, body, enabled, offset_minutes)
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- BEFORE INSERT/UPDATE: trim; a new channel row of a time-based key adopts
-- the offset its siblings already use.
create function public.message_templates_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sibling integer;
begin
  new.body := btrim(new.body, E' \t\r\n');
  new.subject := nullif(btrim(new.subject), '');
  if tg_op = 'UPDATE' then
    if new.key <> old.key or new.channel <> old.channel then
      raise exception 'a template''s key and channel cannot be changed' using errcode = '42501';
    end if;
  else
    select t.offset_minutes into v_sibling from public.message_templates t
     where t.shop_id = new.shop_id and t.key = new.key and t.offset_minutes is not null
     limit 1;
    if v_sibling is not null then
      new.offset_minutes := v_sibling;
    end if;
  end if;
  return new;
end
$$;

-- AFTER UPDATE OF offset_minutes: all channels of a key share one schedule.
create function public.message_templates_sync_offset() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.message_templates t
     set offset_minutes = new.offset_minutes
   where t.shop_id = new.shop_id and t.key = new.key and t.id <> new.id
     and t.offset_minutes is distinct from new.offset_minutes;
  return null;
end
$$;

create trigger message_templates_05_prevent_shop_change before update on public.message_templates
  for each row execute function public.prevent_shop_change();
create trigger message_templates_10_before_write before insert or update on public.message_templates
  for each row execute function public.message_templates_before_write();
create trigger message_templates_90_set_updated_at before update on public.message_templates
  for each row execute function public.set_updated_at();
create trigger message_templates_sync_offset after update of offset_minutes on public.message_templates
  for each row when (old.offset_minutes is distinct from new.offset_minutes)
  execute function public.message_templates_sync_offset();

-- Seed defaults for a new shop.
create function public.shops_seed_comms() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.message_templates (shop_id, key, channel, subject, body, enabled, offset_minutes)
  select new.id, d.key, d.channel, d.subject, d.body, d.enabled, d.offset_minutes
  from public.default_message_templates() d
  on conflict (shop_id, key, channel) do nothing;
  return null;
end
$$;

create trigger shops_seed_comms after insert on public.shops
  for each row execute function public.shops_seed_comms();

-- Shops that already exist when this migration runs get the defaults too.
insert into public.message_templates (shop_id, key, channel, subject, body, enabled, offset_minutes)
select s.id, d.key, d.channel, d.subject, d.body, d.enabled, d.offset_minutes
from public.shops s cross join public.default_message_templates() d
on conflict (shop_id, key, channel) do nothing;

-- ---------------------------------------------------------------------------
-- reset_message_template (owner/admin): restore default wording, enabled
-- flag and offset of one template.
-- ---------------------------------------------------------------------------
create function public.reset_message_template(p_template_id uuid) returns public.message_templates
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
     set subject = v_d.subject, body = v_d.body, enabled = v_d.enabled, offset_minutes = v_d.offset_minutes
   where t.id = v_t.id
  returning * into v_t;
  return v_t;
end
$$;

-- ---------------------------------------------------------------------------
-- render_template — pure; byte-for-byte equivalent to renderTemplate() in
-- supabase/functions/_shared/templates.ts:
--   * placeholder = "{{", optional spaces/tabs, name [A-Za-z_][A-Za-z0-9_]*,
--     optional spaces/tabs, "}}"; names are case-sensitive
--   * strings verbatim, numbers in JSON form, booleans true/false
--   * unknown names, JSON null, objects and arrays render as ''
--   * single pass: substituted values are never re-scanned
--   * anything else (e.g. "{{ a b }}", "{x}") is left untouched
-- Never raises: a null body renders null, non-object vars count as {}.
-- ---------------------------------------------------------------------------
create function public.render_template(p_body text, p_vars jsonb) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  c_re    constant text := '\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}';
  v_vars  jsonb := case when jsonb_typeof(p_vars) = 'object' then p_vars else '{}'::jsonb end;
  v_parts text[];
  v_names text[];
  v_val   jsonb;
  v_out   text;
begin
  if p_body is null then
    return null;
  end if;
  v_parts := regexp_split_to_array(p_body, c_re);
  select coalesce(array_agg(m.match[1] order by m.ord), '{}')
    into v_names
    from regexp_matches(p_body, c_re, 'g') with ordinality as m(match, ord);
  v_out := v_parts[1];
  for i in 1 .. coalesce(array_length(v_names, 1), 0) loop
    v_val := v_vars -> v_names[i];
    v_out := v_out
             || case jsonb_typeof(v_val)
                  when 'string'  then v_val #>> '{}'
                  when 'number'  then v_val::text
                  when 'boolean' then v_val::text
                  else ''
                end
             || v_parts[i + 1];
  end loop;
  return v_out;
end
$$;

-- ---------------------------------------------------------------------------
-- RLS: managers+ read; owner/admin insert (missing key/channel combos),
-- update and delete. Deleting a template simply stops that message.
-- ---------------------------------------------------------------------------
alter table public.message_templates enable row level security;

create policy message_templates_select on public.message_templates for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy message_templates_insert on public.message_templates for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy message_templates_update on public.message_templates for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy message_templates_delete on public.message_templates for delete to authenticated
  using (public.is_shop_admin(shop_id));

revoke all on public.message_templates from anon;
revoke truncate, references, trigger on public.message_templates from authenticated;

revoke execute on function
  public.message_templates_before_write(),
  public.message_templates_sync_offset(),
  public.shops_seed_comms()
from public, anon, authenticated;

revoke execute on function public.default_message_templates() from public, anon;
grant execute on function public.default_message_templates() to authenticated, service_role;

revoke execute on function public.reset_message_template(uuid) from public, anon;
grant execute on function public.reset_message_template(uuid) to authenticated, service_role;

revoke execute on function public.render_template(text, jsonb) from public, anon;
grant execute on function public.render_template(text, jsonb) to authenticated, service_role;
