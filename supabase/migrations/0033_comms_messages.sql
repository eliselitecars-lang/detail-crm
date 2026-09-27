-- ============================================================================
-- 0033 — Messages (SPEC §4.7): customer opt-outs, the messages table (send
-- queue + two-way history), template variables, staff sending RPCs, the
-- sender pipeline used by the `messaging` edge function, and inbound SMS.
--
-- Consent rules (every outbound path):
--   * Opt-outs belong to the ADDRESS, per shop. comms_suppressions holds
--     every (shop, channel, address) that texted STOP, followed an email
--     unsubscribe link, was recorded as opted out by staff, or was reported
--     unsubscribed by the provider. customers.sms_opted_out_at /
--     email_opted_out_at mirror it on EVERY customer of the shop with that
--     address, including customers created or re-addressed later, so a
--     duplicate, a spouse's record or a deleted-and-recreated customer never
--     re-opens a number or inbox. sms_opted_out_at blocks ALL SMS;
--     email_opted_out_at blocks all email.
--   * Checked when queueing (queue_message, enqueue_customer_template,
--     campaign audiences) and again when the sender claims a message
--     (claim_queued_messages), so a STOP that arrives after queueing wins.
--   * Marketing (campaigns, 0035) additionally requires sms_opt_in /
--     email_opt_in, re-checked at claim time: withdrawing consent after a
--     campaign was launched still stops its queued messages. Transactional
--     templates only need an address.
--   * Staff may record an opt-out (stamped with the server time) but never
--     clear one: SMS opt-outs are cleared only by the customer texting
--     START/UNSTOP (record_inbound_sms); email opt-outs only by service_role.
--     Clearing an opt-out clears it for the address (every customer with it).
--
-- Queued messages follow their context until they are handed to the sender:
--   * appointment messages (booking_*, appointment_reminder, on_the_way,
--     job_started) are withdrawn when the job is cancelled, marked no-show
--     or moved to another customer, and re-rendered when it is rescheduled;
--   * a cancelled campaign's messages are never (re)sent, even ones that
--     were in flight and came back for a retry;
--   * the claim never sends stale messages after a sender outage: job and
--     campaign messages more than 24 hours past their send time (2 hours for
--     on_the_way / job_started) and reminders for appointments that already
--     started are cancelled instead (see comms_withdraw_reason).
--
-- Message lifecycle (outbound):
--   queued ──claim──> sending ──result──> sent ──callback──> delivered
--      ^                 │  └──────────────> failed
--      └──── retry ──────┘      (queued, or a retry, may instead become cancelled)
-- Inbound rows are always status 'received' and are written only by
-- service_role (record_inbound_sms).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Customer opt-outs
-- ---------------------------------------------------------------------------
alter table public.customers
  add column sms_opted_out_at   timestamptz,
  add column email_opted_out_at timestamptz;

comment on column public.customers.sms_opted_out_at is
  'Set when this number texts STOP (or staff record an opt-out); mirrors comms_suppressions for every customer with the number. Blocks every SMS. Cleared only by START/UNSTOP.';
comment on column public.customers.email_opted_out_at is
  'Set when this address unsubscribes (or staff record an opt-out); mirrors comms_suppressions for every customer with the address. Blocks every email.';

create function public.customers_comms_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.sms_opted_out_at is not null then new.sms_opted_out_at := now(); end if;
    if new.email_opted_out_at is not null then new.email_opted_out_at := now(); end if;
    return new;
  end if;
  if old.sms_opted_out_at is not null and new.sms_opted_out_at is null then
    raise exception 'an SMS opt-out can only be cleared by the customer replying START' using errcode = '42501';
  end if;
  if old.email_opted_out_at is not null and new.email_opted_out_at is null then
    raise exception 'an email opt-out can only be cleared by the customer' using errcode = '42501';
  end if;
  new.sms_opted_out_at := case when old.sms_opted_out_at is not null then old.sms_opted_out_at
                               when new.sms_opted_out_at is not null then now() end;
  new.email_opted_out_at := case when old.email_opted_out_at is not null then old.email_opted_out_at
                                 when new.email_opted_out_at is not null then now() end;
  return new;
end
$$;

create trigger customers_30_comms_guard before insert or update on public.customers
  for each row execute function public.customers_comms_guard();

-- Inbound SMS are routed to a shop by its sending number: it must be unique.
create unique index shops_sms_from_number_key on public.shops (sms_from_number)
  where sms_from_number is not null;

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
create table public.messages (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  customer_id          uuid,
  job_id               uuid,
  campaign_id          uuid,
  direction            public.message_direction not null,
  channel              public.message_channel not null,
  to_address           text not null,
  from_address         text check (from_address is null or char_length(from_address) <= 320),
  subject              text check (subject is null or char_length(subject) <= 500),
  body                 text not null,
  status               public.message_status not null,
  send_after           timestamptz not null default now(),
  provider_message_id  text check (provider_message_id is null or char_length(provider_message_id) between 1 and 200),
  error                text check (error is null or char_length(error) <= 2000),
  template_key         public.message_template_key,
  sent_by              uuid references auth.users (id) on delete set null,
  read_at              timestamptz,
  attempts             integer not null default 0 check (attempts between 0 and 100),
  claimed_at           timestamptz,
  sent_at              timestamptz,
  delivered_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint messages_shop_id_id_key unique (shop_id, id),
  -- a deleted customer takes their conversation with them
  constraint messages_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint messages_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id),
  constraint messages_direction_status check ((direction = 'inbound') = (status = 'received')),
  constraint messages_outbound_customer check (direction = 'inbound' or customer_id is not null),
  constraint messages_to_address check (
    case channel when 'sms' then public.is_valid_e164(to_address)
                 else public.is_valid_email(to_address) end),
  constraint messages_inbound_sms check (
    direction = 'outbound' or (channel = 'sms' and from_address is not null and public.is_valid_e164(from_address))),
  constraint messages_subject_channel check (
    case channel when 'sms' then subject is null
                 else direction = 'inbound' or (subject is not null and char_length(btrim(subject)) >= 1) end),
  constraint messages_body check (
    char_length(body) <= case channel when 'sms' then 1600 else 50000 end
    and (direction = 'inbound' or char_length(btrim(body)) >= 1)),
  constraint messages_inbound_fields check (
    direction = 'outbound' or (template_key is null and campaign_id is null and sent_by is null))
);
create index messages_queue_idx on public.messages (send_after, created_at)
  where status = 'queued' and direction = 'outbound';
create index messages_sending_idx on public.messages (claimed_at) where status = 'sending';
create unique index messages_provider_message_id_key on public.messages (provider_message_id)
  where provider_message_id is not null;
create index messages_shop_customer_idx on public.messages (shop_id, customer_id, created_at desc);
create index messages_shop_job_idx on public.messages (shop_id, job_id);
create index messages_shop_campaign_idx on public.messages (shop_id, campaign_id);
create index messages_shop_created_idx on public.messages (shop_id, created_at desc);
create index messages_unread_idx on public.messages (shop_id) where direction = 'inbound' and read_at is null;
create index messages_orphans_idx on public.messages (shop_id, from_address)
  where direction = 'inbound' and customer_id is null;
create index messages_to_queued_idx on public.messages (shop_id, to_address) where status = 'queued';
create index messages_sent_by_idx on public.messages (sent_by);

comment on table public.messages is
  'Outbound send queue + two-way history. Written only by comms RPCs / service_role; staff may only set read_at.';

create trigger messages_05_prevent_shop_change before update on public.messages
  for each row execute function public.prevent_shop_change();
create trigger messages_90_set_updated_at before update on public.messages
  for each row execute function public.set_updated_at();

-- An inbound text from an unknown number is attached to the customer as soon
-- as a customer with that phone exists in the shop.
create function public.customers_attach_inbound_messages() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.messages m
     set customer_id = new.id
   where m.shop_id = new.shop_id and m.direction = 'inbound' and m.customer_id is null
     and m.channel = 'sms' and m.from_address = new.phone;
  return null;
end
$$;

create trigger customers_attach_inbound_messages after insert or update of phone on public.customers
  for each row when (new.phone is not null)
  execute function public.customers_attach_inbound_messages();

alter table public.messages enable row level security;

create policy messages_select on public.messages for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy messages_update on public.messages for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));

revoke all on public.messages from anon;
revoke insert, update, delete, truncate, references, trigger on public.messages from authenticated;
-- staff mark messages read / unread; everything else goes through RPCs
grant update (read_at) on public.messages to authenticated;

-- ---------------------------------------------------------------------------
-- comms_suppressions — shop-scoped opt-outs keyed by address.
--   address: SMS = the E.164 number; email = the lower-cased address.
-- Written only by definer code: comms_suppress (STOP, unsubscribe links,
-- staff / provider opt-outs recorded on a customer) and comms_unsuppress
-- (START, service_role re-subscription). Managers may read it.
-- ---------------------------------------------------------------------------

-- Normal form of an address for a channel (null for a blank address).
create function public.comms_address_key(p_channel public.message_channel, p_address text) returns text
language sql immutable
set search_path = ''
as $$
  select case when p_channel is null or nullif(btrim(p_address), '') is null then null
              when p_channel = 'email'::public.message_channel then lower(btrim(p_address))
              else btrim(p_address) end
$$;

create table public.comms_suppressions (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  channel       public.message_channel not null,
  address       text not null,
  opted_out_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  constraint comms_suppressions_shop_id_id_key unique (shop_id, id),
  constraint comms_suppressions_once unique (shop_id, channel, address),
  constraint comms_suppressions_address check (
    address = public.comms_address_key(channel, address)
    and case channel when 'sms' then public.is_valid_e164(address)
                     else public.is_valid_email(address) end)
);

comment on table public.comms_suppressions is
  'Per-shop opt-outs by address (SMS number / email). Survives customer edits, duplicates and deletes; blocks every outbound path.';

alter table public.comms_suppressions enable row level security;
create policy comms_suppressions_select on public.comms_suppressions for select to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.comms_suppressions from anon;
revoke insert, update, delete, truncate, references, trigger on public.comms_suppressions from authenticated;

-- True when the address may not receive anything on the channel.
create function public.comms_is_suppressed(p_shop_id uuid, p_channel public.message_channel, p_address text)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.comms_suppressions s
                  where s.shop_id = p_shop_id and s.channel = p_channel
                    and s.address = public.comms_address_key(p_channel, p_address))
$$;

-- Records an opt-out for an address: adds the suppression (idempotent),
-- stamps every customer of the shop with that address (and drops their
-- marketing opt-in for the channel) and withdraws messages still queued to
-- it. Returns true when the address was not suppressed before.
create function public.comms_suppress(
  p_shop_id  uuid,
  p_channel  public.message_channel,
  p_address  text,
  p_at       timestamptz default now()
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_addr text := public.comms_address_key(p_channel, p_address);
  v_at   timestamptz := coalesce(p_at, now());
  v_id   uuid;
begin
  if p_shop_id is null or v_addr is null
     or not (case p_channel when 'sms' then public.is_valid_e164(v_addr) else public.is_valid_email(v_addr) end) then
    raise exception 'a shop, channel and valid address are required' using errcode = '22023';
  end if;

  insert into public.comms_suppressions (shop_id, channel, address, opted_out_at)
  values (p_shop_id, p_channel, v_addr, v_at)
  on conflict (shop_id, channel, address) do nothing
  returning id into v_id;

  if p_channel = 'sms' then
    update public.customers c
       set sms_opted_out_at = coalesce(c.sms_opted_out_at, v_at), sms_opt_in = false
     where c.shop_id = p_shop_id and c.phone = v_addr
       and (c.sms_opted_out_at is null or c.sms_opt_in);
  else
    update public.customers c
       set email_opted_out_at = coalesce(c.email_opted_out_at, v_at), email_opt_in = false
     where c.shop_id = p_shop_id and lower(c.email::text) = v_addr
       and (c.email_opted_out_at is null or c.email_opt_in);
  end if;

  update public.messages m
     set status = 'cancelled', error = 'the recipient opted out before sending'
   where m.shop_id = p_shop_id and m.channel = p_channel and m.direction = 'outbound' and m.status = 'queued'
     and public.comms_address_key(m.channel, m.to_address) = v_addr;
  return v_id is not null;
end
$$;

-- Clears an address's opt-out (START / UNSTOP, or service_role): removes the
-- suppression and the opt-out stamp of every customer of the shop with that
-- address. Marketing opt-ins are NOT restored (they need fresh consent).
-- Returns true when a suppression was removed.
create function public.comms_unsuppress(
  p_shop_id  uuid,
  p_channel  public.message_channel,
  p_address  text
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_addr    text := public.comms_address_key(p_channel, p_address);
  v_removed integer;
begin
  if p_shop_id is null or v_addr is null then
    return false;
  end if;
  delete from public.comms_suppressions s
   where s.shop_id = p_shop_id and s.channel = p_channel and s.address = v_addr;
  get diagnostics v_removed = row_count;
  if p_channel = 'sms' then
    update public.customers c set sms_opted_out_at = null
     where c.shop_id = p_shop_id and c.phone = v_addr and c.sms_opted_out_at is not null;
  else
    update public.customers c set email_opted_out_at = null
     where c.shop_id = p_shop_id and lower(c.email::text) = v_addr and c.email_opted_out_at is not null;
  end if;
  return v_removed > 0;
end
$$;

-- BEFORE INSERT / address change (runs after customers_30_comms_guard): a
-- customer created or re-addressed with a suppressed number / email starts
-- out opted out, whoever writes the row.
create function public.customers_comms_suppressed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if new.phone is not null and (tg_op = 'INSERT' or new.phone is distinct from old.phone) then
    select s.opted_out_at into v_at from public.comms_suppressions s
     where s.shop_id = new.shop_id and s.channel = 'sms' and s.address = new.phone;
    if found then
      new.sms_opted_out_at := coalesce(new.sms_opted_out_at, v_at);
      new.sms_opt_in := false;
    end if;
  end if;
  if new.email is not null and (tg_op = 'INSERT' or new.email::text is distinct from old.email::text) then
    select s.opted_out_at into v_at from public.comms_suppressions s
     where s.shop_id = new.shop_id and s.channel = 'email' and s.address = lower(new.email::text);
    if found then
      new.email_opted_out_at := coalesce(new.email_opted_out_at, v_at);
      new.email_opt_in := false;
    end if;
  end if;
  return new;
end
$$;

create trigger customers_31_comms_suppressed before insert or update of phone, email on public.customers
  for each row execute function public.customers_comms_suppressed();

-- AFTER an opt-out stamp changes on a customer (staff, STOP, unsubscribe,
-- the provider reporting an unsubscribed number): the address follows —
-- a new opt-out suppresses the address shop-wide, a cleared one (trusted
-- code only; see customers_comms_guard) clears it for every customer.
create function public.customers_comms_optout_sync() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.sms_opted_out_at is not null and (tg_op = 'INSERT' or old.sms_opted_out_at is null) then
    if new.phone is not null then
      perform public.comms_suppress(new.shop_id, 'sms', new.phone, new.sms_opted_out_at);
    end if;
  elsif tg_op = 'UPDATE' and old.sms_opted_out_at is not null and new.sms_opted_out_at is null then
    perform public.comms_unsuppress(new.shop_id, 'sms', new.phone);
    if old.phone is distinct from new.phone then
      perform public.comms_unsuppress(new.shop_id, 'sms', old.phone);
    end if;
  end if;

  if new.email_opted_out_at is not null and (tg_op = 'INSERT' or old.email_opted_out_at is null) then
    if new.email is not null then
      perform public.comms_suppress(new.shop_id, 'email', new.email::text, new.email_opted_out_at);
    end if;
  elsif tg_op = 'UPDATE' and old.email_opted_out_at is not null and new.email_opted_out_at is null then
    perform public.comms_unsuppress(new.shop_id, 'email', new.email::text);
    if old.email::text is distinct from new.email::text then
      perform public.comms_unsuppress(new.shop_id, 'email', old.email::text);
    end if;
  end if;
  return null;
end
$$;

create trigger customers_comms_optout_insert after insert on public.customers
  for each row when (new.sms_opted_out_at is not null or new.email_opted_out_at is not null)
  execute function public.customers_comms_optout_sync();
create trigger customers_comms_optout_update after update on public.customers
  for each row when (old.sms_opted_out_at is distinct from new.sms_opted_out_at
                     or old.email_opted_out_at is distinct from new.email_opted_out_at)
  execute function public.customers_comms_optout_sync();

-- ---------------------------------------------------------------------------
-- Template variables (internal builders + a checked wrapper)
-- ---------------------------------------------------------------------------

-- Customer/shop-level variables (no job).
create function public.comms_customer_vars(p_shop_id uuid, p_customer_id uuid) returns jsonb
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
    'review_link', s.review_url,
    'booking_page_link', public.app_url('/book/' || s.slug))
  from public.shops s
  left join public.customers c on c.shop_id = s.id and c.id = p_customer_id
  where s.id = p_shop_id
$$;

-- Every variable for a job (customer vars + appointment, vehicle, services,
-- links and money). Money tables are optional at this layer: quotes,
-- invoices and payments are looked up only when they exist.
create function public.comms_job_vars(p_job_id uuid) returns jsonb
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
  v_i_total   bigint;
  v_i_balance bigint;
  v_paid      bigint := 0;
  v_amount    bigint;
  v_balance   bigint;
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

  if to_regclass('public.invoices') is not null then
    execute 'select i.public_token, i.status::text, i.total_cents, i.balance_cents
               from public.invoices i
              where i.shop_id = $1 and i.job_id = $2 and i.status::text <> ''void''
              order by i.created_at desc limit 1'
      into v_i_token, v_i_status, v_i_total, v_i_balance using v_job.shop_id, v_job.id;
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

  return public.comms_customer_vars(v_job.shop_id, v_job.customer_id) || jsonb_build_object(
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
    'balance', public.format_money(v_balance, v_shop.currency));
end
$$;

-- Checked wrapper: service_role, or owner/admin/manager of the job's shop.
create function public.template_vars_for_job(p_job_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select j.shop_id into v_shop from public.jobs j where j.id = p_job_id;
  if v_shop is null or (auth.uid() is not null and not public.is_shop_manager(v_shop)) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  return public.comms_job_vars(p_job_id);
end
$$;

-- Template keys about a specific appointment: withdrawn when the job is
-- cancelled / no-show / moved to another customer, re-rendered when it is
-- rescheduled.
create function public.comms_is_appointment_key(p_key public.message_template_key) returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(p_key::text in ('booking_request_received', 'booking_confirmed', 'appointment_reminder',
                                  'on_the_way', 'job_started'), false)
$$;

-- Renders a template for a channel: body trimmed and capped (SMS 1600,
-- email 50000 characters); email subject rendered, else the shop name.
-- body is null when the template renders empty.
create function public.comms_render_parts(
  p_channel    public.message_channel,
  p_subject    text,
  p_body       text,
  p_vars       jsonb,
  p_shop_name  text,
  out subject  text,
  out body     text
)
language plpgsql immutable
set search_path = ''
as $$
begin
  body := nullif(btrim(public.render_template(p_body, p_vars), E' \t\r\n'), '');
  if body is null then
    return;
  end if;
  if p_channel = 'sms' then
    body := left(body, 1600);
  else
    body := left(body, 50000);
    subject := coalesce(left(nullif(btrim(public.render_template(p_subject, p_vars)), ''), 500), p_shop_name);
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- enqueue_customer_template — INTERNAL core (service_role and definer code
-- such as integration triggers; performs no caller checks). Queues one
-- message for (key, channel) and returns its id, or null (no-op) when the
-- template is missing/disabled, the customer has no address for the channel,
-- has opted out (or the address is suppressed), the shop has no SMS number,
-- the body renders empty, or it is an appointment message for a cancelled /
-- no-show job. p_extra_vars override/add variables (e.g. a receipt's amount).
-- ---------------------------------------------------------------------------
create function public.enqueue_customer_template(
  p_shop_id      uuid,
  p_customer_id  uuid,
  p_key          public.message_template_key,
  p_channel      public.message_channel default 'sms',
  p_job_id       uuid default null,
  p_extra_vars   jsonb default null,
  p_send_after   timestamptz default null,
  p_sent_by      uuid default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tpl      public.message_templates;
  v_cust     public.customers;
  v_shop     public.shops;
  v_job_cust uuid;
  v_job_st   public.job_status;
  v_to       text;
  v_vars     jsonb;
  v_subject  text;
  v_body     text;
  v_id       uuid;
begin
  if p_shop_id is null or p_customer_id is null or p_key is null or p_channel is null then
    raise exception 'shop, customer, key and channel are required' using errcode = '22023';
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

  select * into v_tpl from public.message_templates t
   where t.shop_id = p_shop_id and t.key = p_key and t.channel = p_channel;
  if not found or not v_tpl.enabled then
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

  v_vars := case when p_job_id is not null then public.comms_job_vars(p_job_id)
                 else public.comms_customer_vars(p_shop_id, p_customer_id) end;
  if jsonb_typeof(p_extra_vars) = 'object' then
    v_vars := v_vars || p_extra_vars;
  end if;

  select r.subject, r.body into v_subject, v_body
    from public.comms_render_parts(p_channel, v_tpl.subject, v_tpl.body, v_vars, v_shop.name) r;
  if v_body is null then
    return null;
  end if;

  insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body,
                               status, send_after, template_key, sent_by)
  values (p_shop_id, p_customer_id, p_job_id, 'outbound', p_channel, v_to, v_subject, v_body,
          'queued', coalesce(p_send_after, now()), p_key, p_sent_by)
  returning id into v_id;
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- enqueue_template_message — checked entry point for a job's template.
--   service_role: any key.  owner/admin/manager: any key for their shop's jobs.
--   technician: only on_the_way / job_started / job_completed, only on jobs
--   assigned to them, sent now.
-- Returns the queued message id or null (see enqueue_customer_template).
-- ---------------------------------------------------------------------------
create function public.enqueue_template_message(
  p_job_id      uuid,
  p_key         public.message_template_key,
  p_send_after  timestamptz default null,
  p_channel     public.message_channel default 'sms'
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_role public.shop_role;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null then
    v_role := public.shop_role_of(v_job.shop_id);
    if v_role is null then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if v_role = 'technician' then
      if not public.is_assigned_to_job(v_job.id) then
        raise exception 'technicians can only message customers of jobs assigned to them' using errcode = '42501';
      end if;
      if p_key not in ('on_the_way', 'job_started', 'job_completed') then
        raise exception 'technicians can only send on-the-way, job-started and job-complete messages'
          using errcode = '42501';
      end if;
      if p_send_after is not null then
        raise exception 'technicians cannot schedule messages' using errcode = '42501';
      end if;
    end if;
  end if;
  if v_job.status in ('cancelled', 'no_show') and public.comms_is_appointment_key(p_key) then
    raise exception 'this appointment is %; its appointment messages can no longer be sent',
      replace(v_job.status::text, '_', '-') using errcode = '55000';
  end if;
  return public.enqueue_customer_template(v_job.shop_id, v_job.customer_id, p_key, p_channel, v_job.id,
                                          null, p_send_after, auth.uid());
end
$$;

-- Preview what a template would send for a job (same access rules as
-- enqueue_template_message). Nothing is queued.
create function public.preview_template_message(
  p_job_id   uuid,
  p_key      public.message_template_key,
  p_channel  public.message_channel default 'sms'
) returns table (enabled boolean, to_address text, subject text, body text)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job  public.jobs;
  v_role public.shop_role;
  v_tpl  public.message_templates;
  v_cust public.customers;
  v_vars jsonb;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null then
    v_role := public.shop_role_of(v_job.shop_id);
    if v_role is null then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if v_role = 'technician' and (not public.is_assigned_to_job(v_job.id)
                                  or p_key not in ('on_the_way', 'job_started', 'job_completed')) then
      raise exception 'not allowed to preview this message' using errcode = '42501';
    end if;
  end if;
  select * into v_tpl from public.message_templates t
   where t.shop_id = v_job.shop_id and t.key = p_key and t.channel = p_channel;
  if not found then
    raise exception 'template not found' using errcode = 'P0002';
  end if;
  select * into v_cust from public.customers c where c.id = v_job.customer_id and c.shop_id = v_job.shop_id;
  v_vars := public.comms_job_vars(v_job.id);
  return query select v_tpl.enabled,
                      case p_channel when 'sms' then v_cust.phone else v_cust.email::text end,
                      public.render_template(v_tpl.subject, v_vars),
                      btrim(public.render_template(v_tpl.body, v_vars), E' \t\r\n');
end
$$;

-- ---------------------------------------------------------------------------
-- queue_message — staff free-form message to a customer (owner/admin/
-- manager). Raises when it cannot be delivered (no address, opted out, SMS
-- not configured) so the sender gets feedback.
-- ---------------------------------------------------------------------------
create function public.queue_message(
  p_shop_id      uuid,
  p_customer_id  uuid,
  p_channel      public.message_channel,
  p_subject      text,
  p_body         text,
  p_job_id       uuid default null
) returns public.messages
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust     public.customers;
  v_shop     public.shops;
  v_job_cust uuid;
  v_body     text := btrim(coalesce(p_body, ''), E' \t\r\n');
  v_subject  text;
  v_to       text;
  v_msg      public.messages;
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can message customers' using errcode = '42501';
  end if;
  if p_channel is null then
    raise exception 'choose sms or email' using errcode = '22023';
  end if;
  select * into v_cust from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if p_job_id is not null then
    select j.customer_id into v_job_cust from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id;
    if not found then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if v_job_cust <> p_customer_id then
      raise exception 'the job belongs to another customer' using errcode = '22023';
    end if;
  end if;
  if v_body = '' then
    raise exception 'the message is empty' using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.id = p_shop_id;

  if p_channel = 'sms' then
    if char_length(v_body) > 1600 then
      raise exception 'text messages are limited to 1600 characters' using errcode = '22023';
    end if;
    if v_cust.phone is null then
      raise exception 'this customer has no mobile number' using errcode = '22023';
    end if;
    if v_cust.sms_opted_out_at is not null or public.comms_is_suppressed(p_shop_id, 'sms', v_cust.phone) then
      raise exception 'this customer has opted out of text messages' using errcode = '55000';
    end if;
    if v_shop.sms_from_number is null then
      raise exception 'text messaging is not set up for this shop' using errcode = '55000';
    end if;
    v_to := v_cust.phone;
  else
    if char_length(v_body) > 50000 then
      raise exception 'the email is too long' using errcode = '22023';
    end if;
    if v_cust.email is null then
      raise exception 'this customer has no email address' using errcode = '22023';
    end if;
    if v_cust.email_opted_out_at is not null or public.comms_is_suppressed(p_shop_id, 'email', v_cust.email::text) then
      raise exception 'this customer has unsubscribed from email' using errcode = '55000';
    end if;
    v_to := v_cust.email::text;
    v_subject := coalesce(left(nullif(btrim(p_subject), ''), 500), 'Message from ' || v_shop.name);
  end if;

  insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body,
                               status, send_after, sent_by)
  values (p_shop_id, p_customer_id, p_job_id, 'outbound', p_channel, v_to, v_subject, v_body,
          'queued', now(), auth.uid())
  returning * into v_msg;
  return v_msg;
end
$$;

-- ---------------------------------------------------------------------------
-- Sender pipeline (service_role; the messaging edge function)
-- ---------------------------------------------------------------------------

-- Why a queued outbound message may no longer be sent (null = send it).
-- Checked by claim_queued_messages for every due message and by
-- mark_message_result before a retry is re-queued. In order:
--   * the customer opted out of the channel, or the address is suppressed;
--   * campaign messages: the campaign was cancelled, or the customer no
--     longer has the channel's marketing opt-in (sms_opt_in / email_opt_in);
--   * appointment messages (comms_is_appointment_key): the job was
--     cancelled, marked no-show or moved to another customer; a reminder
--     whose appointment already started (15 minutes of grace for reminders
--     set to the appointment time itself) or is under way / done;
--   * staleness after a sender outage: on_the_way / job_started more than
--     2 hours past their send time; other job messages (except quotes,
--     invoices and receipts, which stay valid) and campaign messages more
--     than 24 hours past it.
-- Campaigns are created in 0035; the campaign lookup only runs for rows
-- that have a campaign_id.
create function public.comms_withdraw_reason(p_msg public.messages, p_now timestamptz default now())
returns text
language plpgsql stable
set search_path = ''
as $$
declare
  v_now      timestamptz := coalesce(p_now, now());
  v_cust     public.customers;
  v_job      public.jobs;
  v_campaign text;
begin
  if p_msg.id is null or p_msg.direction <> 'outbound' then
    return null;
  end if;

  if p_msg.customer_id is not null then
    select * into v_cust from public.customers c where c.id = p_msg.customer_id and c.shop_id = p_msg.shop_id;
  end if;
  if (p_msg.channel = 'sms' and v_cust.sms_opted_out_at is not null)
     or (p_msg.channel = 'email' and v_cust.email_opted_out_at is not null)
     or public.comms_is_suppressed(p_msg.shop_id, p_msg.channel, p_msg.to_address) then
    return 'the recipient opted out before sending';
  end if;

  if p_msg.campaign_id is not null then
    execute 'select c.status::text from public.campaigns c where c.id = $1 and c.shop_id = $2'
      into v_campaign using p_msg.campaign_id, p_msg.shop_id;
    if v_campaign = 'cancelled' then
      return 'the campaign was cancelled';
    end if;
    if v_cust.id is null
       or not (case p_msg.channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end) then
      return 'the recipient withdrew marketing consent before sending';
    end if;
  end if;

  if p_msg.job_id is not null then
    select * into v_job from public.jobs j where j.id = p_msg.job_id and j.shop_id = p_msg.shop_id;
    if v_job.id is not null and public.comms_is_appointment_key(p_msg.template_key) then
      if v_job.status = 'cancelled' then
        return 'the appointment was cancelled';
      elsif v_job.status = 'no_show' then
        return 'the appointment was marked as a no-show';
      elsif v_job.customer_id is distinct from p_msg.customer_id then
        return 'the appointment now belongs to another customer';
      elsif p_msg.template_key = 'appointment_reminder'
            and (v_job.status in ('in_progress', 'completed') or v_job.scheduled_start is null
                 or v_job.scheduled_start <= v_now - interval '15 minutes') then
        return 'the appointment has already started';
      end if;
    end if;
  end if;

  if p_msg.job_id is not null and p_msg.template_key in ('on_the_way', 'job_started')
     and p_msg.send_after < v_now - interval '2 hours' then
    return 'the message is too old to send';
  end if;
  if (p_msg.campaign_id is not null
      or (p_msg.job_id is not null
          and (p_msg.template_key is null or p_msg.template_key not in ('quote_sent', 'invoice_sent', 'payment_receipt'))))
     and p_msg.send_after < v_now - interval '24 hours' then
    return 'the message is too old to send';
  end if;
  return null;
end
$$;

-- Locks up to p_limit due queued messages (FOR UPDATE SKIP LOCKED, so
-- concurrent workers never get the same row), marks them 'sending' and
-- returns what the sender needs. Due rows that may no longer be sent are
-- settled instead of returned: any comms_withdraw_reason (opted out /
-- suppressed, cancelled campaign, withdrawn marketing consent, cancelled or
-- no-show appointment, stale) → cancelled with that reason; SMS without a
-- shop sending number → failed. Rows stuck in 'sending' for 15 minutes
-- (crashed worker) are failed rather than retried, to never double-send.
create function public.claim_queued_messages(p_limit integer default 50, p_now timestamptz default now())
returns table (
  id            uuid,
  shop_id       uuid,
  channel       public.message_channel,
  to_address    text,
  from_address  text,
  subject       text,
  body          text,
  attempts      integer,
  shop_name     text,
  reply_to      text,
  customer_id   uuid,
  job_id        uuid,
  campaign_id   uuid,
  template_key  public.message_template_key
)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_now   timestamptz := coalesce(p_now, now());
begin
  update public.messages m
     set status = 'failed',
         error = 'the send attempt timed out; the message may not have been delivered'
   where m.id in (select s.id from public.messages s
                   where s.status = 'sending' and s.claimed_at < v_now - interval '15 minutes'
                   for update skip locked);

  return query
  with cand as (
    select m.id
      from public.messages m
     where m.status = 'queued' and m.direction = 'outbound' and m.send_after <= v_now
     order by m.send_after, m.created_at, m.id
     limit v_limit
     for update skip locked
  ), info as (
    select c.id,
           public.comms_withdraw_reason(q, v_now) as withdraw,
           (q.channel = 'sms' and s.sms_from_number is null) as no_sender,
           s.sms_from_number, s.name as shop_name, s.email::text as shop_email
      from cand c
      join public.messages q on q.id = c.id
      join public.shops s on s.id = q.shop_id
  ), upd as (
    update public.messages m
       set status = case when i.withdraw is not null then 'cancelled'::public.message_status
                         when i.no_sender then 'failed'::public.message_status
                         else 'sending'::public.message_status end,
           error = case when i.withdraw is not null then i.withdraw
                        when i.no_sender then 'text messaging is not set up for this shop'
                        else m.error end,
           attempts = case when i.withdraw is not null or i.no_sender then m.attempts else m.attempts + 1 end,
           claimed_at = case when i.withdraw is not null or i.no_sender then m.claimed_at else v_now end,
           from_address = case when m.channel = 'sms' and i.withdraw is null and not i.no_sender
                               then i.sms_from_number else m.from_address end
      from info i
     where m.id = i.id
    returning m.id, m.shop_id, m.channel, m.to_address, m.from_address, m.subject, m.body, m.attempts,
              m.status, m.send_after, m.created_at, i.shop_name, i.shop_email, m.customer_id, m.job_id,
              m.campaign_id, m.template_key
  )
  select u.id, u.shop_id, u.channel, u.to_address, u.from_address, u.subject, u.body, u.attempts,
         u.shop_name, u.shop_email, u.customer_id, u.job_id, u.campaign_id, u.template_key
    from upd u
   where u.status = 'sending'
   order by u.send_after, u.created_at, u.id;
end
$$;

-- Result of a send attempt for a claimed message.
--   sent / delivered / failed  — final provider answer (from 'sending'; a late
--                                'delivered'/'failed' may follow 'sent'; a
--                                provider success corrects a 'failed' row,
--                                e.g. one the stuck-send sweep timed out)
--   queued                     — transient failure: retry with exponential
--                                backoff (2^attempts minutes after p_now);
--                                after 5 attempts the message fails instead,
--                                and a message that may no longer be sent
--                                (comms_withdraw_reason, e.g. its campaign
--                                was cancelled meanwhile) is cancelled.
-- Replaying the same result is a no-op.
create function public.mark_message_result(
  p_id            uuid,
  p_status        public.message_status,
  p_provider_id   text default null,
  p_error         text default null,
  p_from_address  text default null,
  p_now           timestamptz default now()
) returns public.messages
language plpgsql security definer
set search_path = ''
as $$
declare
  v_msg    public.messages;
  v_error  text := left(nullif(btrim(coalesce(p_error, '')), ''), 2000);
  v_now    timestamptz := coalesce(p_now, now());
  v_reason text;
begin
  if p_status is null or p_status not in ('sent', 'delivered', 'failed', 'queued') then
    raise exception 'result must be sent, delivered, failed or queued (retry)' using errcode = '22023';
  end if;
  select * into v_msg from public.messages m where m.id = p_id and m.direction = 'outbound' for update;
  if not found then
    raise exception 'message not found' using errcode = 'P0002';
  end if;

  if v_msg.status = p_status and p_status <> 'queued' then
    return v_msg;                                   -- replay
  end if;
  if not (v_msg.status = 'sending'
          or (v_msg.status = 'sent' and p_status in ('delivered', 'failed'))
          or (v_msg.status = 'failed' and p_status in ('sent', 'delivered'))) then
    raise exception 'message is % and cannot become %', v_msg.status, p_status using errcode = '55000';
  end if;

  begin
    if p_status = 'queued' then
      v_reason := public.comms_withdraw_reason(v_msg, v_now);
      if v_reason is not null then
        update public.messages m
           set status = 'cancelled', error = v_reason, claimed_at = null,
               provider_message_id = coalesce(p_provider_id, m.provider_message_id)
         where m.id = v_msg.id returning * into v_msg;
      elsif v_msg.attempts >= 5 then
        update public.messages m
           set status = 'failed', error = coalesce(v_error, 'sending failed after 5 attempts'),
               provider_message_id = coalesce(p_provider_id, m.provider_message_id)
         where m.id = v_msg.id returning * into v_msg;
      else
        update public.messages m
           set status = 'queued', error = v_error, claimed_at = null,
               send_after = v_now + make_interval(mins => power(2, greatest(m.attempts, 0))::integer)
         where m.id = v_msg.id returning * into v_msg;
      end if;
    else
      update public.messages m
         set status = p_status,
             provider_message_id = coalesce(p_provider_id, m.provider_message_id),
             from_address = coalesce(left(nullif(btrim(p_from_address), ''), 320), m.from_address),
             error = case when p_status = 'failed' then coalesce(v_error, 'sending failed') end,
             sent_at = case when p_status in ('sent', 'delivered') then coalesce(m.sent_at, v_now) else m.sent_at end,
             delivered_at = case when p_status = 'delivered' then coalesce(m.delivered_at, v_now) else m.delivered_at end
       where m.id = v_msg.id returning * into v_msg;
    end if;
  exception when unique_violation then
    raise exception 'provider message id % is already recorded on another message', p_provider_id
      using errcode = '23505';
  end;
  return v_msg;
end
$$;

-- Delivery callbacks (Twilio status webhook / email events) keyed by the
-- provider's message id. Status only moves forward:
--   sending → sent → delivered;  sending|sent → failed;  failed → delivered
-- Anything else (unknown id, stale or duplicate callback) is ignored.
-- Returns the message id, or null when no message has that provider id.
create function public.update_message_status_by_provider_id(
  p_provider_id  text,
  p_status       public.message_status,
  p_error        text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_msg public.messages;
begin
  if p_status is null or p_status not in ('sent', 'delivered', 'failed') then
    raise exception 'status must be sent, delivered or failed' using errcode = '22023';
  end if;
  if p_provider_id is null or btrim(p_provider_id) = '' then
    raise exception 'provider id is required' using errcode = '22023';
  end if;
  select * into v_msg from public.messages m
   where m.provider_message_id = p_provider_id and m.direction = 'outbound' for update;
  if not found then
    return null;
  end if;
  if (p_status = 'sent' and v_msg.status = 'sending')
     or (p_status = 'delivered' and v_msg.status in ('sending', 'sent', 'failed'))
     or (p_status = 'failed' and v_msg.status in ('sending', 'sent')) then
    update public.messages m
       set status = p_status,
           error = case when p_status = 'failed'
                        then coalesce(left(nullif(btrim(coalesce(p_error, '')), ''), 2000), 'delivery failed') end,
           sent_at = case when p_status in ('sent', 'delivered') then coalesce(m.sent_at, now()) else m.sent_at end,
           delivered_at = case when p_status = 'delivered' then coalesce(m.delivered_at, now()) else m.delivered_at end
     where m.id = v_msg.id;
  end if;
  return v_msg.id;
end
$$;

-- ---------------------------------------------------------------------------
-- record_inbound_sms (service_role; Twilio inbound webhook, signature already
-- verified by the edge function). Routes by the To number to the shop and by
-- the From number to the most recently created matching customer of that
-- shop (active customers first). Handles carrier opt-out keywords for the
-- NUMBER (comms_suppressions + every customer of the shop with it, including
-- customers created with it later):
--   STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, OPTOUT, REVOKE → opt out
--   START, UNSTOP                                                → opt back in
-- Unknown senders are stored with customer_id null. Staff (owner/admin/
-- manager) get an 'inbound_message' notification. Idempotent per provider
-- id (Twilio retries). Returns no row when no shop uses the To number.
-- ---------------------------------------------------------------------------
create function public.record_inbound_sms(
  p_to           text,
  p_from         text,
  p_body         text,
  p_provider_id  text default null
) returns table (message_id uuid, shop_id uuid, customer_id uuid, opt_action text)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_to      text := btrim(coalesce(p_to, ''));
  v_from    text := btrim(coalesce(p_from, ''));
  v_body    text := left(coalesce(p_body, ''), 1600);
  v_pid     text := nullif(btrim(coalesce(p_provider_id, '')), '');
  v_shop    public.shops;
  v_cust    public.customers;
  v_kw      text;
  v_action  text;
  v_existing public.messages;
  v_id      uuid;
  v_who     text;
begin
  if not public.is_valid_e164(v_to) or not public.is_valid_e164(v_from) then
    raise exception 'to and from must be E.164 phone numbers' using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.sms_from_number = v_to;
  if not found then
    return;
  end if;

  if v_pid is not null then
    select * into v_existing from public.messages m where m.provider_message_id = v_pid;
    if found then
      return query select v_existing.id, v_existing.shop_id, v_existing.customer_id, null::text;
      return;
    end if;
  end if;

  select * into v_cust from public.customers c
   where c.shop_id = v_shop.id and c.phone = v_from
   order by (c.archived_at is null) desc, c.created_at desc, c.id
   limit 1;

  v_kw := upper(regexp_replace(btrim(v_body), '[[:space:][:punct:]]+$', ''));
  if v_kw in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'OPTOUT', 'REVOKE') then
    v_action := 'opt_out';
    -- the number is suppressed even when no customer has it yet
    perform public.comms_suppress(v_shop.id, 'sms', v_from, now());
  elsif v_kw in ('START', 'UNSTOP') then
    v_action := 'opt_in';
    perform public.comms_unsuppress(v_shop.id, 'sms', v_from);
  end if;

  begin
    insert into public.messages (shop_id, customer_id, direction, channel, to_address, from_address, body,
                                 status, provider_message_id, send_after)
    values (v_shop.id, v_cust.id, 'inbound', 'sms', v_to, v_from, v_body, 'received', v_pid, now())
    returning id into v_id;
  exception when unique_violation then
    -- a concurrent delivery of the same webhook won the race
    select * into v_existing from public.messages m where m.provider_message_id = v_pid;
    return query select v_existing.id, v_existing.shop_id, v_existing.customer_id, null::text;
    return;
  end;

  v_who := coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(v_cust.first_name), ''),
                                                nullif(btrim(v_cust.last_name), ''))), ''),
                    nullif(btrim(v_cust.company), ''), public.format_phone(v_from));
  perform public.notify_shop_staff(
    v_shop.id, array['owner', 'admin', 'manager']::public.shop_role[], 'inbound_message',
    case v_action
      when 'opt_out' then v_who || ' opted out of text messages'
      when 'opt_in'  then v_who || ' opted back in to text messages'
      else 'New text from ' || v_who
    end,
    nullif(left(v_body, 280), ''));

  return query select v_id, v_shop.id, v_cust.id, v_action;
end
$$;

-- ---------------------------------------------------------------------------
-- Jobs: queued appointment messages follow the appointment.
--   cancelled / no_show           → withdrawn (cancelled with the reason)
--   moved to another customer     → withdrawn (the old customer's copy; its
--                                   booking link was rotated anyway)
--   rescheduled                   → re-rendered from the current template
--                                   with the new date and time (withdrawn if
--                                   it now renders empty)
-- Messages already handed to the sender are not touched; the claim re-checks
-- the same rules (comms_withdraw_reason) for anything that slips past.
-- ---------------------------------------------------------------------------
create function public.jobs_comms_sync_queued() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_reason text;
  v_m      public.messages;
  v_tpl    public.message_templates;
  v_vars   jsonb;
  v_shop   text;
  v_subj   text;
  v_body   text;
begin
  if new.status in ('cancelled', 'no_show') and old.status is distinct from new.status then
    v_reason := case new.status when 'cancelled' then 'the appointment was cancelled'
                                else 'the appointment was marked as a no-show' end;
    update public.messages m
       set status = 'cancelled', error = v_reason
     where m.shop_id = new.shop_id and m.job_id = new.id and m.direction = 'outbound' and m.status = 'queued'
       and public.comms_is_appointment_key(m.template_key);
    return null;
  end if;

  if new.customer_id is distinct from old.customer_id then
    update public.messages m
       set status = 'cancelled', error = 'the appointment now belongs to another customer'
     where m.shop_id = new.shop_id and m.job_id = new.id and m.direction = 'outbound' and m.status = 'queued'
       and public.comms_is_appointment_key(m.template_key)
       and m.customer_id is distinct from new.customer_id;
  end if;

  if new.scheduled_start is distinct from old.scheduled_start and new.status not in ('cancelled', 'no_show') then
    for v_m in
      select * from public.messages m
       where m.shop_id = new.shop_id and m.job_id = new.id and m.direction = 'outbound' and m.status = 'queued'
         and public.comms_is_appointment_key(m.template_key)
       order by m.created_at, m.id
       for update
    loop
      select * into v_tpl from public.message_templates t
       where t.shop_id = new.shop_id and t.key = v_m.template_key and t.channel = v_m.channel;
      if v_vars is null then
        v_vars := public.comms_job_vars(new.id);
        select s.name into v_shop from public.shops s where s.id = new.shop_id;
      end if;
      v_subj := null;
      v_body := null;
      if v_tpl.id is not null then
        select r.subject, r.body into v_subj, v_body
          from public.comms_render_parts(v_m.channel, v_tpl.subject, v_tpl.body, v_vars, v_shop) r;
      end if;
      if v_body is null then
        update public.messages m
           set status = 'cancelled', error = 'the appointment changed and the message no longer applies'
         where m.id = v_m.id;
      else
        update public.messages m set body = v_body, subject = v_subj where m.id = v_m.id;
      end if;
    end loop;
  end if;
  return null;
end
$$;

create trigger jobs_zz_comms_sync_queued after update on public.jobs
  for each row when (old.status is distinct from new.status
                     or old.customer_id is distinct from new.customer_id
                     or old.scheduled_start is distinct from new.scheduled_start)
  execute function public.jobs_comms_sync_queued();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.customers_comms_guard(),
  public.customers_attach_inbound_messages(),
  public.customers_comms_suppressed(),
  public.customers_comms_optout_sync(),
  public.jobs_comms_sync_queued()
from public, anon, authenticated;

-- pure helpers (no data access)
revoke execute on function
  public.comms_address_key(public.message_channel, text),
  public.comms_is_appointment_key(public.message_template_key),
  public.comms_render_parts(public.message_channel, text, text, jsonb, text)
from public, anon;
grant execute on function
  public.comms_address_key(public.message_channel, text),
  public.comms_is_appointment_key(public.message_template_key),
  public.comms_render_parts(public.message_channel, text, text, jsonb, text)
to authenticated, service_role;

-- internal builders / service-only pipeline
revoke execute on function
  public.comms_is_suppressed(uuid, public.message_channel, text),
  public.comms_suppress(uuid, public.message_channel, text, timestamptz),
  public.comms_unsuppress(uuid, public.message_channel, text),
  public.comms_withdraw_reason(public.messages, timestamptz),
  public.comms_customer_vars(uuid, uuid),
  public.comms_job_vars(uuid),
  public.enqueue_customer_template(uuid, uuid, public.message_template_key, public.message_channel, uuid, jsonb,
                                   timestamptz, uuid),
  public.claim_queued_messages(integer, timestamptz),
  public.mark_message_result(uuid, public.message_status, text, text, text, timestamptz),
  public.update_message_status_by_provider_id(text, public.message_status, text),
  public.record_inbound_sms(text, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.comms_is_suppressed(uuid, public.message_channel, text),
  public.comms_suppress(uuid, public.message_channel, text, timestamptz),
  public.comms_unsuppress(uuid, public.message_channel, text),
  public.comms_withdraw_reason(public.messages, timestamptz),
  public.comms_customer_vars(uuid, uuid),
  public.comms_job_vars(uuid),
  public.enqueue_customer_template(uuid, uuid, public.message_template_key, public.message_channel, uuid, jsonb,
                                   timestamptz, uuid),
  public.claim_queued_messages(integer, timestamptz),
  public.mark_message_result(uuid, public.message_status, text, text, text, timestamptz),
  public.update_message_status_by_provider_id(text, public.message_status, text),
  public.record_inbound_sms(text, text, text, text)
to service_role;

-- staff entry points (checked inside)
revoke execute on function
  public.template_vars_for_job(uuid),
  public.enqueue_template_message(uuid, public.message_template_key, timestamptz, public.message_channel),
  public.preview_template_message(uuid, public.message_template_key, public.message_channel),
  public.queue_message(uuid, uuid, public.message_channel, text, text, uuid)
from public, anon;
grant execute on function
  public.template_vars_for_job(uuid),
  public.enqueue_template_message(uuid, public.message_template_key, timestamptz, public.message_channel),
  public.preview_template_message(uuid, public.message_template_key, public.message_channel),
  public.queue_message(uuid, uuid, public.message_channel, text, text, uuid)
to authenticated, service_role;
