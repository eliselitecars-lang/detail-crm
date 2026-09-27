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
--     re-opens a number or inbox. Conversely a customer whose phone / email
--     changes takes the NEW address's state: the previous address's opt-out
--     stays with that address and does not block the new one
--     (customers_comms_suppressed). sms_opted_out_at blocks ALL SMS;
--     email_opted_out_at blocks all email.
--   * Checked when queueing (queue_message, enqueue_customer_template,
--     campaign audiences) and again when the sender claims a message
--     (claim_queued_messages), so a STOP that arrives after queueing wins.
--   * Marketing — campaigns (0035) and the promotional follow_up template
--     (comms_is_marketing_key) — additionally requires sms_opt_in /
--     email_opt_in, re-checked at claim time: withdrawing consent after a
--     message was queued still stops it. Every marketing SMS carries an
--     opt-out instruction (comms_sms_with_optout) and every marketing email
--     an unsubscribe link /u/<messages.unsubscribe_token>
--     (comms_email_with_unsubscribe; List-Unsubscribe headers use the same
--     token). The token is random per email and is never the message id, so
--     only the recipient (and managers, who may record opt-outs anyway) can
--     use it; transactional email has none. Every token is also recorded in
--     comms_unsubscribe_tokens with the address it was sent to, which
--     outlives the message, so the link keeps working after its customer
--     (and with it the message) is deleted. Transactional templates only
--     need an address.
--   * Staff may record an opt-out (stamped with the server time) but never
--     clear one: SMS opt-outs are cleared only by the customer texting
--     START/UNSTOP/YES (record_inbound_sms); email opt-outs only by service_role.
--     Clearing an opt-out clears it for the address (every customer with it).
--     Changing a customer's address never clears the previous address's
--     opt-out; it only stops applying to that customer.
--
-- Queued messages follow their context until they are handed to the sender:
--   * a message goes only to the customer's CURRENT address: changing a
--     customer's phone / email withdraws what is still queued to the old one
--     (and the claim / a retry cancels anything addressed elsewhere);
--   * appointment messages (booking_*, appointment_reminder, on_the_way,
--     job_started) are withdrawn when the job is cancelled, marked no-show,
--     moved to another customer or deleted, and re-rendered when it is
--     rescheduled (one in flight then is re-rendered if it comes back for a
--     retry); deleting a job withdraws every templated message still
--     queued for it;
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
--      └──── retry ──────┘      (queued, or a retry, may instead become cancelled;
--                               a retried appointment message is re-rendered)
-- Inbound rows are always status 'received' and are written only by
-- service_role (record_inbound_sms).
--
-- Idempotent sends: the staff entry points (queue_message,
-- enqueue_template_message, enqueue_customer_template and 0090's
-- enqueue_document_message) take an optional p_request_nonce — one random
-- value per compose, reused when the client retries. A nonce already used by
-- the same sender in the shop returns that message instead of queueing a
-- second one (messages_request_nonce_key makes a concurrent retry lose the
-- race and read the winner's row).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Customer opt-outs
-- ---------------------------------------------------------------------------
alter table public.customers
  add column sms_opted_out_at   timestamptz,
  add column email_opted_out_at timestamptz;

comment on column public.customers.sms_opted_out_at is
  'Set when this number texts STOP (or staff record an opt-out); mirrors comms_suppressions for every customer with the number. Blocks every SMS. Cleared by START/UNSTOP/YES, or when the customer''s phone changes to a number that has not opted out.';
comment on column public.customers.email_opted_out_at is
  'Set when this address unsubscribes (or staff record an opt-out); mirrors comms_suppressions for every customer with the address. Blocks every email. Cleared when the customer''s email changes to an address that has not opted out.';

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

-- ---------------------------------------------------------------------------
-- shop_sms_numbers — the PLATFORM's binding of a Twilio number to the shop
-- it was provisioned for (supabase/setup/twilio.md). Written only by
-- service_role / postgres (the operator); owners and admins may read their
-- shop's rows. A number is bound to at most one shop (primary key).
--
-- shops.sms_from_number is typed in by the shop's owner/admin, so it must
-- never be what decides who owns a number: a tenant could otherwise claim
-- another shop's number first and lock the real shop out of it. It may only
-- hold a number bound to that same shop (shops_sms_from_number_fk, checked
-- with a readable error by shops_sms_from_number_bound), which also makes it
-- unique across shops. Inbound texts are routed by this binding, never by
-- sms_from_number: a shop that clears its sending number (e.g. to pause
-- texting) still receives the replies and STOPs its customers send to the
-- number it was assigned.
-- Unbinding a number clears it from the shop (ON DELETE SET NULL).
-- Moving a number: delete its row, insert it for the new shop.
-- ---------------------------------------------------------------------------
create table public.shop_sms_numbers (
  phone_number  text primary key check (public.is_valid_e164(phone_number)),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  created_at    timestamptz not null default now(),
  constraint shop_sms_numbers_shop_number_key unique (shop_id, phone_number)
);

comment on table public.shop_sms_numbers is
  'Platform binding of a Twilio number to its shop (service_role only). shops.sms_from_number may only name a number bound to that shop.';

create trigger shop_sms_numbers_05_prevent_shop_change before update on public.shop_sms_numbers
  for each row execute function public.prevent_shop_change();

alter table public.shop_sms_numbers enable row level security;
create policy shop_sms_numbers_select on public.shop_sms_numbers for select to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.shop_sms_numbers from anon;
revoke insert, update, delete, truncate, references, trigger on public.shop_sms_numbers from authenticated;

-- Readable refusal before the foreign key below would reject the write.
create function public.shops_sms_from_number_bound() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  -- (a malformed number is left to the E.164 check constraint)
  if new.sms_from_number is not null and public.is_valid_e164(new.sms_from_number)
     and (tg_op = 'INSERT' or new.sms_from_number is distinct from old.sms_from_number)
     and not exists (select 1 from public.shop_sms_numbers n
                      where n.phone_number = new.sms_from_number and n.shop_id = new.id) then
    raise exception 'the number % is not provisioned for this shop', new.sms_from_number
      using errcode = '23503',
            hint = 'Only a number the platform assigned to this shop can be used for text messages; ask platform support.';
  end if;
  return new;
end
$$;

create trigger shops_30_sms_from_number_bound before insert or update of sms_from_number on public.shops
  for each row execute function public.shops_sms_from_number_bound();

-- The index serves the foreign key below (and sender lookups by number).
create index shops_sms_from_number_idx on public.shops (sms_from_number, id) where sms_from_number is not null;
alter table public.shops
  add constraint shops_sms_from_number_fk foreign key (id, sms_from_number)
    references public.shop_sms_numbers (shop_id, phone_number) on delete set null (sms_from_number);

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
create table public.messages (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  customer_id          uuid,
  job_id               uuid,
  campaign_id          uuid,
  -- the credential of this email's unsubscribe link (/u/<token>); set only
  -- on marketing email (campaigns, comms_is_marketing_key templates), never
  -- derived from the message id, which staff RPCs return to their callers
  unsubscribe_token    uuid,
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
  -- the client's idempotency key for a staff send (see the header)
  request_nonce        text check (request_nonce is null or request_nonce ~ '^[A-Za-z0-9_-]{8,64}$'),
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
    direction = 'outbound' or (template_key is null and campaign_id is null and sent_by is null)),
  constraint messages_unsubscribe_token check (
    unsubscribe_token is null or (direction = 'outbound' and channel = 'email'))
);
create unique index messages_unsubscribe_token_key on public.messages (unsubscribe_token)
  where unsubscribe_token is not null;
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
create unique index messages_request_nonce_key on public.messages (shop_id, sent_by, request_nonce)
  where request_nonce is not null;

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

-- BEFORE INSERT / address change (runs after customers_30_comms_guard): the
-- opt-out stamps mirror comms_suppressions for the customer's CURRENT
-- addresses, whoever writes the row.
--   * INSERT: a customer created with a suppressed number / email starts out
--     opted out (a stamp recorded on the new row is kept too).
--   * phone / email changed to another address: the stamp that belonged to
--     the previous address does not follow the customer; it is recomputed
--     from comms_suppressions for the new address (the new address's
--     opt-out time, or none — also when the address is removed). The
--     previous address stays suppressed, so a later move back to it, or any
--     other record with it, is opted out again. Kept as recorded: a stamp
--     set in the same statement (staff recording an opt-out for the new
--     address; customers_comms_optout_sync then suppresses it) and a stamp
--     recorded while the customer had no address on the channel (the
--     person's opt-out, which then applies to — and suppresses — the first
--     address they give).
-- A suppressed address always drops the channel's marketing opt-in.
create function public.customers_comms_suppressed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if tg_op = 'INSERT'
     or public.comms_address_key('sms', new.phone) is distinct from public.comms_address_key('sms', old.phone) then
    v_at := null;
    if new.phone is not null then
      select s.opted_out_at into v_at from public.comms_suppressions s
       where s.shop_id = new.shop_id and s.channel = 'sms' and s.address = public.comms_address_key('sms', new.phone);
    end if;
    if tg_op = 'UPDATE' and old.phone is not null
       and new.sms_opted_out_at is not distinct from old.sms_opted_out_at then
      new.sms_opted_out_at := v_at;                       -- the previous number's stamp: recomputed
    else
      new.sms_opted_out_at := coalesce(new.sms_opted_out_at, v_at);
    end if;
    if v_at is not null then
      new.sms_opt_in := false;
    end if;
  end if;
  if tg_op = 'INSERT'
     or public.comms_address_key('email', new.email::text)
        is distinct from public.comms_address_key('email', old.email::text) then
    v_at := null;
    if new.email is not null then
      select s.opted_out_at into v_at from public.comms_suppressions s
       where s.shop_id = new.shop_id and s.channel = 'email'
         and s.address = public.comms_address_key('email', new.email::text);
    end if;
    if tg_op = 'UPDATE' and old.email is not null
       and new.email_opted_out_at is not distinct from old.email_opted_out_at then
      new.email_opted_out_at := v_at;                     -- the previous address's stamp: recomputed
    else
      new.email_opted_out_at := coalesce(new.email_opted_out_at, v_at);
    end if;
    if v_at is not null then
      new.email_opt_in := false;
    end if;
  end if;
  return new;
end
$$;

create trigger customers_31_comms_suppressed before insert or update of phone, email on public.customers
  for each row execute function public.customers_comms_suppressed();

-- AFTER an opt-out stamp or an address changes on a customer (staff, STOP,
-- unsubscribe, the provider reporting an unsubscribed number): the address
-- follows — a customer with an opt-out stamp suppresses its current address
-- shop-wide (a new opt-out, or one kept from when the customer had no
-- address on the channel); a stamp cleared WITHOUT an address change
-- (trusted code only; see customers_comms_guard) clears the address for
-- every customer. A stamp dropped because the address changed
-- (customers_comms_suppressed) lifts nothing: the previous address keeps
-- its opt-out.
create function public.customers_comms_optout_sync() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sms_moved   boolean := tg_op = 'UPDATE'
                           and public.comms_address_key('sms', new.phone)
                               is distinct from public.comms_address_key('sms', old.phone);
  v_email_moved boolean := tg_op = 'UPDATE'
                           and public.comms_address_key('email', new.email::text)
                               is distinct from public.comms_address_key('email', old.email::text);
begin
  if new.sms_opted_out_at is not null then
    if new.phone is not null and (tg_op = 'INSERT' or old.sms_opted_out_at is null or v_sms_moved) then
      perform public.comms_suppress(new.shop_id, 'sms', new.phone, new.sms_opted_out_at);
    end if;
  elsif tg_op = 'UPDATE' and old.sms_opted_out_at is not null and not v_sms_moved then
    perform public.comms_unsuppress(new.shop_id, 'sms', new.phone);
  end if;

  if new.email_opted_out_at is not null then
    if new.email is not null and (tg_op = 'INSERT' or old.email_opted_out_at is null or v_email_moved) then
      perform public.comms_suppress(new.shop_id, 'email', new.email::text, new.email_opted_out_at);
    end if;
  elsif tg_op = 'UPDATE' and old.email_opted_out_at is not null and not v_email_moved then
    perform public.comms_unsuppress(new.shop_id, 'email', new.email::text);
  end if;
  return null;
end
$$;

create trigger customers_comms_optout_insert after insert on public.customers
  for each row when (new.sms_opted_out_at is not null or new.email_opted_out_at is not null)
  execute function public.customers_comms_optout_sync();
create trigger customers_comms_optout_update after update on public.customers
  for each row when (old.sms_opted_out_at is distinct from new.sms_opted_out_at
                     or old.email_opted_out_at is distinct from new.email_opted_out_at
                     or (new.sms_opted_out_at is not null and old.phone is distinct from new.phone)
                     or (new.email_opted_out_at is not null and old.email::text is distinct from new.email::text))
  execute function public.customers_comms_optout_sync();

-- AFTER a customer's phone / email changes: messages still queued to the
-- previous address are withdrawn, never re-addressed — the old number or
-- inbox may belong to someone else now, and the new one is only messaged by
-- what is queued from here on (with the consent checks that apply then).
-- Messages already handed to the sender are cancelled by the retry check
-- (comms_withdraw_reason) if they come back.
create function public.customers_comms_readdress() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.messages m
     set status = 'cancelled', error = 'the customer''s contact details changed before sending'
   where m.shop_id = new.shop_id and m.customer_id = new.id
     and m.direction = 'outbound' and m.status = 'queued'
     and public.comms_address_key(m.channel, m.to_address)
         is distinct from public.comms_address_key(m.channel, case m.channel when 'sms' then new.phone
                                                                              else new.email::text end);
  return null;
end
$$;

create trigger customers_comms_readdress after update of phone, email on public.customers
  for each row when (old.phone is distinct from new.phone or old.email::text is distinct from new.email::text)
  execute function public.customers_comms_readdress();

-- ---------------------------------------------------------------------------
-- comms_unsubscribe_tokens — the credential of every marketing email's
-- unsubscribe link (messages.unsubscribe_token) with the shop and the
-- address the email went to, recorded when the email is queued
-- (messages_record_unsubscribe_token) and kept while the shop exists.
-- It outlives the message on purpose: deleting a customer deletes their
-- messages (messages_customer_fk), yet the /u/<token> link and the one-click
-- List-Unsubscribe POST in email already delivered must keep working
-- (CAN-SPAM: at least 30 days after sending), and the opt-out they record
-- belongs to the ADDRESS, so any other customer record with it (a
-- duplicate, one created later) is opted out too. public_unsubscribe (0035)
-- resolves tokens here. Like comms_suppressions, it keeps an address after
-- its customer is gone only to honour that person's opt-out.
-- Written only by definer code; no API role can read or write it.
-- ---------------------------------------------------------------------------
create table public.comms_unsubscribe_tokens (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  token       uuid not null,
  address     text not null,
  -- the email it was issued for, while that message exists
  message_id  uuid,
  created_at  timestamptz not null default now(),
  constraint comms_unsubscribe_tokens_shop_id_id_key unique (shop_id, id),
  constraint comms_unsubscribe_tokens_token_key unique (token),
  constraint comms_unsubscribe_tokens_address check (
    address = public.comms_address_key('email', address) and public.is_valid_email(address)),
  constraint comms_unsubscribe_tokens_message_fk foreign key (shop_id, message_id)
    references public.messages (shop_id, id) on delete set null (message_id)
);
create index comms_unsubscribe_tokens_shop_message_idx on public.comms_unsubscribe_tokens (shop_id, message_id);

comment on table public.comms_unsubscribe_tokens is
  'Unsubscribe-link credentials of marketing email (token -> shop + address). Outlives the message so sent links keep working; definer code only.';

alter table public.comms_unsubscribe_tokens enable row level security;
-- No policies: only definer code (and service_role) touches it.
revoke all on public.comms_unsubscribe_tokens from anon, authenticated;

-- AFTER INSERT of a marketing email carrying a token (campaign emails, 0035;
-- comms_is_marketing_key template emails, enqueue_customer_template): the
-- token is recorded with the address it was sent to. Tokens are only ever
-- issued at insert; one set on any other row is never an unsubscribe
-- credential.
create function public.messages_record_unsubscribe_token() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.direction = 'outbound' and new.channel = 'email'
     and (new.campaign_id is not null or public.comms_is_marketing_key(new.template_key)) then
    insert into public.comms_unsubscribe_tokens (shop_id, token, address, message_id)
    values (new.shop_id, new.unsubscribe_token, public.comms_address_key('email', new.to_address), new.id);
  end if;
  return null;
end
$$;

create trigger messages_40_record_unsubscribe_token after insert on public.messages
  for each row when (new.unsubscribe_token is not null)
  execute function public.messages_record_unsubscribe_token();

-- ---------------------------------------------------------------------------
-- Template variables (internal builders + a checked wrapper)
-- ---------------------------------------------------------------------------

-- Customer/shop-level variables (no job). Link variables are null when the
-- link is not available: review_link without a review URL, booking_page_link
-- while the shop's online booking is off (or app_base_url is unset).
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
    'review_link', nullif(btrim(s.review_url), ''),
    -- only while the page has something to book (public_booking_catalog
    -- refuses a shop whose online booking is off)
    'booking_page_link', case when b.enabled then public.app_url('/book/' || s.slug) end)
  from public.shops s
  left join public.booking_settings b on b.shop_id = s.id
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

-- Template keys that are marketing (promotional), not transactional: they
-- need the channel's marketing opt-in (sms_opt_in / email_opt_in) like a
-- campaign, re-checked at send time, and their SMS carry the opt-out line.
create function public.comms_is_marketing_key(p_key public.message_template_key) returns boolean
language sql immutable
set search_path = ''
as $$ select coalesce(p_key::text = 'follow_up', false) $$;

-- A marketing SMS body (≤ 1600 characters) that tells the recipient how to
-- opt out: kept as is when it already carries an opt-out INSTRUCTION
-- ("Reply STOP", "Text STOP", "Txt STOP", "Send STOP" — merely using the
-- word, as in "Stop by Saturday", does not count), else cut to make room
-- for and ended with "Reply STOP to opt out.". Null for a blank body.
create function public.comms_sms_with_optout(p_body text) returns text
language sql immutable
set search_path = ''
as $$
  select case
    when nullif(btrim(p_body, E' \t\r\n'), '') is null then null
    when left(p_body, 1600) ~* '\m(reply|text|txt|send)[[:space:]]+["''“‘]?stop\M' then left(p_body, 1600)
    else left(p_body, 1600 - char_length(E'\nReply STOP to opt out.')) || E'\nReply STOP to opt out.'
  end
$$;

-- A marketing email body (≤ 50000 characters) that carries its unsubscribe
-- link: kept as is when the link already appears in it (the template used
-- {{unsubscribe_link}}), else cut to make room for and ended with
-- "To unsubscribe from these emails, visit: <link>". Unchanged when the
-- body or link is null.
create function public.comms_email_with_unsubscribe(p_body text, p_link text) returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p_body is null or nullif(btrim(p_link), '') is null then p_body
    when strpos(left(p_body, 50000), p_link) > 0 then left(p_body, 50000)
    else left(p_body, 50000 - char_length(E'\n\nTo unsubscribe from these emails, visit: ' || p_link))
         || E'\n\nTo unsubscribe from these emails, visit: ' || p_link
  end
$$;

-- Link placeholders a template text uses whose link is not available in
-- p_vars (missing, null or blank), sorted and distinct. The link variables
-- are exactly those that can be unavailable for a message (LINK_VARS in
-- supabase/functions/messaging/send.ts):
--   booking_link       the job's booking page
--   booking_page_link  the shop's online booking page (only while online booking is on)
--   quote_link         the job's quote (only once sent)
--   invoice_link       the job's invoice (only once issued)
--   review_link        the shop's review URL (only once set)
-- ({{unsubscribe_link}} is not one of them: marketing email always has it,
-- and it renders empty in every other message by design.)
create function public.comms_unavailable_links(p_text text, p_vars jsonb) returns text[]
language sql immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct m.match[1] order by m.match[1]), '{}'::text[])
    from regexp_matches(coalesce(p_text, ''),
                        '\{\{[ \t]*(booking_link|booking_page_link|quote_link|invoice_link|review_link)[ \t]*\}\}',
                        'g') as m(match)
   where jsonb_typeof(case when jsonb_typeof(p_vars) = 'object' then p_vars end -> m.match[1])
           is distinct from 'string'
      or btrim(p_vars ->> m.match[1]) = ''
$$;

-- Placeholders a template text uses that would render blank, sorted and
-- distinct: the unavailable link placeholders (comms_unavailable_links;
-- only when p_links) and the optional VALUE placeholders with no value in
-- p_vars (missing, null, a JSON object / array, or blank text). The optional
-- values are those a shop, customer or job may not have, or that only a
-- job provides:
--   shop_phone     the shop's phone (create_shop's p_phone is optional)
--   customer_name  the customer's full name (none for a record with only a phone / email)
--   job_date, job_time, job_number, vehicle, services, amount, balance
--                  job details (a job may be unscheduled, have no vehicle or
--                  no line items; none of them exist for customer-level messages)
-- (customer_first_name and shop_name always have a value; unsubscribe_link
-- renders empty outside marketing email by design; invite_link is supplied
-- by the invites sender; unknown names are left to render_template.)
create function public.comms_unavailable_values(p_text text, p_vars jsonb, p_links boolean default true)
returns text[]
language sql immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct x.name order by x.name), '{}'::text[])
    from (
      select l.name
        from unnest(public.comms_unavailable_links(p_text, p_vars)) as l(name)
       where coalesce(p_links, true)
      union all
      select m.match[1]
        from regexp_matches(coalesce(p_text, ''),
                            '\{\{[ \t]*(shop_phone|customer_name|job_date|job_time|job_number|vehicle|services|amount|balance)[ \t]*\}\}',
                            'g') as m(match)
       where coalesce(jsonb_typeof(case when jsonb_typeof(p_vars) = 'object' then p_vars end -> m.match[1]), 'null')
               not in ('string', 'number', 'boolean')
          or btrim((case when jsonb_typeof(p_vars) = 'object' then p_vars end) ->> m.match[1]) = ''
    ) x
$$;

-- A template text without the lines that would render something blank
-- (comms_unavailable_values): a line whose link is not available, or that
-- uses an optional value this shop / customer / job does not have, is left
-- out, so an automatic message never ends a sentence with a blank link
-- ("View your invoice: ") or a blank value ("Questions? Call us at .",
-- "Vehicle: "); the blank line that set an omitted paragraph apart goes
-- with it. With p_links false, lines whose only gap is a link are kept (the
-- staff preview shows those blank: the staff send refuses such a message).
-- Unchanged when nothing it uses is missing; null for null.
create function public.comms_omit_unavailable_values(p_text text, p_vars jsonb, p_links boolean default true)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_out     text[] := '{}';
  v_line    text;
  v_omitted boolean := false;
begin
  if p_text is null or cardinality(public.comms_unavailable_values(p_text, p_vars, p_links)) = 0 then
    return p_text;
  end if;
  foreach v_line in array string_to_array(p_text, E'\n') loop
    if cardinality(public.comms_unavailable_values(v_line, p_vars, p_links)) > 0 then
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

-- The link a template key exists to deliver. Such a message is not sent at
-- all while its template uses that link and it is not available (a quote
-- that was never sent, an invoice still in draft, a shop without a review
-- URL): without it the message has no point.
create function public.comms_key_required_link(p_key public.message_template_key) returns text
language sql immutable
set search_path = ''
as $$
  select case p_key::text when 'quote_sent' then 'quote_link'
                          when 'invoice_sent' then 'invoice_link'
                          when 'review_request' then 'review_link' end
$$;

-- Renders a template for a channel: lines whose link is not available or
-- whose optional value is missing are left out
-- (comms_omit_unavailable_values), body trimmed and capped (SMS
-- 1600, email 50000 characters); email subject rendered, else the shop
-- name. body is null when the template renders empty.
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
  body := nullif(btrim(public.render_template(public.comms_omit_unavailable_values(p_body, p_vars), p_vars),
                       E' \t\r\n'), '');
  if body is null then
    return;
  end if;
  if p_channel = 'sms' then
    body := left(body, 1600);
  else
    body := left(body, 50000);
    subject := coalesce(left(nullif(btrim(public.render_template(
                                 public.comms_omit_unavailable_values(p_subject, p_vars), p_vars)), ''), 500),
                        p_shop_name);
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- enqueue_customer_template — INTERNAL core (service_role and definer code
-- such as integration triggers; performs no caller checks). Queues one
-- message for (key, channel) and returns its id, or null (no-op) when the
-- template is missing/disabled, the customer has no address for the channel,
-- has opted out (or the address is suppressed), the shop has no SMS number,
-- the body renders empty (lines whose link is not available or whose
-- optional value is missing are left out: comms_render_parts), the wording uses the link the key exists to deliver
-- and it is not available (comms_key_required_link: an unsent quote, an
-- unissued invoice, no review URL), the wording uses an app link ({{booking_link}},
-- {{quote_link}} …; comms_uses_app_links) while platform_config has no
-- app_base_url, it is an appointment message for a cancelled /
-- no-show job, or it is a marketing template (comms_is_marketing_key) and
-- the customer has not opted in to marketing on the channel (or, for
-- email, no app URL is configured to build its unsubscribe link). Marketing
-- SMS get the opt-out line; marketing email gets a fresh unsubscribe token,
-- {{unsubscribe_link}} and the unsubscribe footer unless the wording
-- already places the link. p_extra_vars override/add variables (e.g. a
-- receipt's amount) except unsubscribe_link. p_request_nonce (see the
-- header): a nonce p_sent_by already used in the shop returns that message.
-- ---------------------------------------------------------------------------
create function public.enqueue_customer_template(
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
  v_tpl      public.message_templates;
  v_cust     public.customers;
  v_shop     public.shops;
  v_job_cust uuid;
  v_job_st   public.job_status;
  v_to       text;
  v_vars     jsonb;
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

  select * into v_tpl from public.message_templates t
   where t.shop_id = p_shop_id and t.key = p_key and t.channel = p_channel;
  if not found or not v_tpl.enabled then
    return null;
  end if;
  -- never queue a message whose customer link would render blank
  if public.app_url('/') is null
     and (public.comms_uses_app_links(v_tpl.body) or (p_channel = 'email' and public.comms_uses_app_links(v_tpl.subject))) then
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
     and not (case p_channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end) then
    return null;
  end if;

  v_vars := case when p_job_id is not null then public.comms_job_vars(p_job_id)
                 else public.comms_customer_vars(p_shop_id, p_customer_id) end;
  if jsonb_typeof(p_extra_vars) = 'object' then
    v_vars := v_vars || p_extra_vars;
  end if;
  v_need := public.comms_key_required_link(p_key);
  if v_need = any (public.comms_unavailable_links(
                     v_tpl.body || case when p_channel = 'email' then E'\n' || coalesce(v_tpl.subject, '') else '' end,
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

  select r.subject, r.body into v_subject, v_body
    from public.comms_render_parts(p_channel, v_tpl.subject, v_tpl.body, v_vars, v_shop.name) r;
  if v_body is null then
    return null;
  end if;
  if public.comms_is_marketing_key(p_key) then
    v_body := case p_channel when 'sms' then public.comms_sms_with_optout(v_body)
                             else public.comms_email_with_unsubscribe(v_body, v_unsub) end;
  end if;

  if p_request_nonce is null then
    insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body,
                                 status, send_after, template_key, sent_by, unsubscribe_token)
    values (p_shop_id, p_customer_id, p_job_id, 'outbound', p_channel, v_to, v_subject, v_body,
            'queued', coalesce(p_send_after, now()), p_key, p_sent_by, v_token)
    returning id into v_id;
    return v_id;
  end if;
  begin
    insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body,
                                 status, send_after, template_key, sent_by, unsubscribe_token, request_nonce)
    values (p_shop_id, p_customer_id, p_job_id, 'outbound', p_channel, v_to, v_subject, v_body,
            'queued', coalesce(p_send_after, now()), p_key, p_sent_by, v_token, p_request_nonce)
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

-- Shape of a client idempotency key (messages.request_nonce).
create function public.comms_valid_request_nonce(p_nonce text) returns boolean
language sql immutable
set search_path = ''
as $$ select p_nonce is not null and p_nonce ~ '^[A-Za-z0-9_-]{8,64}$' $$;

-- ---------------------------------------------------------------------------
-- enqueue_template_message — checked entry point for a job's template.
--   service_role: any key.  owner/admin/manager: any key for their shop's jobs.
--   technician: only on_the_way / job_started / job_completed, only on jobs
--   assigned to them, sent now.
-- Raises 55000 when the template needs customer links (or an unsubscribe
-- link) and app_base_url is not configured, instead of queueing nothing.
-- Returns the queued message id or null (see enqueue_customer_template).
-- ---------------------------------------------------------------------------
create function public.enqueue_template_message(
  p_job_id         uuid,
  p_key            public.message_template_key,
  p_send_after     timestamptz default null,
  p_channel        public.message_channel default 'sms',
  p_request_nonce  text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_role public.shop_role;
  v_id   uuid;
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
  -- a retry of a send that already queued returns it, whatever changed since
  if p_request_nonce is not null then
    if not public.comms_valid_request_nonce(p_request_nonce) then
      raise exception 'request_nonce must be 8-64 letters, digits, - or _' using errcode = '22023';
    end if;
    select m.id into v_id from public.messages m
     where m.shop_id = v_job.shop_id and m.sent_by is not distinct from auth.uid() and m.request_nonce = p_request_nonce;
    if found then
      return v_id;
    end if;
  end if;
  if v_job.status in ('cancelled', 'no_show') and public.comms_is_appointment_key(p_key) then
    raise exception 'this appointment is %; its appointment messages can no longer be sent',
      replace(v_job.status::text, '_', '-') using errcode = '55000';
  end if;
  if public.app_url('/') is null and exists (
       select 1 from public.message_templates t
        where t.shop_id = v_job.shop_id and t.key = p_key and t.channel = p_channel and t.enabled
          and (public.comms_uses_app_links(t.body)
               or (p_channel = 'email' and (public.comms_uses_app_links(t.subject)
                                            or public.comms_is_marketing_key(p_key))))) then
    raise exception 'customer links are not set up on this platform yet, so this message cannot be sent'
      using errcode = '55000',
            hint = 'The platform operator must set app_base_url (supabase/setup/cron.sql).';
  end if;
  return public.enqueue_customer_template(v_job.shop_id, v_job.customer_id, p_key, p_channel, v_job.id,
                                          null, p_send_after, auth.uid(), p_request_nonce);
end
$$;

-- Preview what a template would send for a job (same access rules as
-- enqueue_template_message). Nothing is queued. Links that are not available
-- render blank here, so staff see what is missing (the messaging function's
-- staff send refuses such a message: missing_link); only automatic sending
-- leaves those lines out (comms_render_parts). Lines with a missing optional
-- value (no shop phone, no vehicle …) are left out here too, as they are
-- from every message queued (comms_omit_unavailable_values).
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
  -- Technicians send these messages but may not act as the customer: the
  -- job / quote / invoice tokens inside the link variables are customer
  -- credentials (0042 hides jobs.public_token from them), so a technician's
  -- preview shows a label where a link will go.
  if v_role = 'technician' then
    v_vars := v_vars || coalesce((select jsonb_object_agg(e.key, '[' || replace(e.key, '_', ' ') || ']')
                                    from jsonb_each(v_vars) e
                                   where e.key in ('booking_link', 'quote_link', 'invoice_link')
                                     and jsonb_typeof(e.value) = 'string'), '{}'::jsonb);
  end if;
  -- a marketing email gets its own unsubscribe link when queued; the preview
  -- shows where it goes (and the footer when the wording does not place it)
  if p_channel = 'email' and public.comms_is_marketing_key(p_key) then
    v_vars := v_vars || jsonb_build_object('unsubscribe_link', '[unsubscribe link]');
  end if;
  -- lines with a missing optional value are left out exactly as when the
  -- message is queued; lines whose only gap is a link are kept (blank)
  return query select v_tpl.enabled,
                      case p_channel when 'sms' then v_cust.phone else v_cust.email::text end,
                      public.render_template(public.comms_omit_unavailable_values(v_tpl.subject, v_vars, false), v_vars),
                      case when p_channel = 'email' and public.comms_is_marketing_key(p_key)
                           then public.comms_email_with_unsubscribe(
                                  btrim(public.render_template(
                                          public.comms_omit_unavailable_values(v_tpl.body, v_vars, false), v_vars),
                                        E' \t\r\n'), '[unsubscribe link]')
                           else btrim(public.render_template(
                                        public.comms_omit_unavailable_values(v_tpl.body, v_vars, false), v_vars),
                                      E' \t\r\n') end;
end
$$;

-- ---------------------------------------------------------------------------
-- queue_message — staff free-form message to a customer (owner/admin/
-- manager). Raises when it cannot be delivered (no address, opted out, SMS
-- not configured) so the sender gets feedback. p_request_nonce (see the
-- header): a retry returns the message the first call queued.
-- ---------------------------------------------------------------------------
create function public.queue_message(
  p_shop_id        uuid,
  p_customer_id    uuid,
  p_channel        public.message_channel,
  p_subject        text,
  p_body           text,
  p_job_id         uuid default null,
  p_request_nonce  text default null
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
  v_conname  text;
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can message customers' using errcode = '42501';
  end if;
  if p_request_nonce is not null then
    if not public.comms_valid_request_nonce(p_request_nonce) then
      raise exception 'request_nonce must be 8-64 letters, digits, - or _' using errcode = '22023';
    end if;
    select * into v_msg from public.messages m
     where m.shop_id = p_shop_id and m.sent_by = auth.uid() and m.request_nonce = p_request_nonce;
    if found then
      return v_msg;                         -- a retry of a send that already queued
    end if;
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

  begin
    insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body,
                                 status, send_after, sent_by, request_nonce)
    values (p_shop_id, p_customer_id, p_job_id, 'outbound', p_channel, v_to, v_subject, v_body,
            'queued', now(), auth.uid(), p_request_nonce)
    returning * into v_msg;
  exception when unique_violation then
    get stacked diagnostics v_conname = constraint_name;
    if v_conname is distinct from 'messages_request_nonce_key' then
      raise;
    end if;
    -- a concurrent retry with the same nonce won the race
    select * into v_msg from public.messages m
     where m.shop_id = p_shop_id and m.sent_by = auth.uid() and m.request_nonce = p_request_nonce;
  end;
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
--   * the customer's current phone / email for the channel is no longer the
--     address the message was queued to (or was removed);
--   * campaign messages: the campaign was cancelled; campaign and marketing
--     template messages (comms_is_marketing_key): the customer no longer
--     has the channel's marketing opt-in (sms_opt_in / email_opt_in);
--   * appointment messages (comms_is_appointment_key): the job was deleted
--     (appointment messages always name their job, so one without a job
--     lost it), cancelled, marked no-show or moved to another customer; a
--     reminder whose appointment already started or is under way / done
--     (15 minutes of grace only for a reminder that was due at the
--     appointment time itself: offset 0, per its job_automation_log row);
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
  v_at_start boolean;
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
  if v_cust.id is not null
     and public.comms_address_key(p_msg.channel, p_msg.to_address)
         is distinct from public.comms_address_key(p_msg.channel, case p_msg.channel when 'sms' then v_cust.phone
                                                                                     else v_cust.email::text end) then
    return 'the customer''s contact details changed before sending';
  end if;

  if p_msg.campaign_id is not null then
    execute 'select c.status::text from public.campaigns c where c.id = $1 and c.shop_id = $2'
      into v_campaign using p_msg.campaign_id, p_msg.shop_id;
    if v_campaign = 'cancelled' then
      return 'the campaign was cancelled';
    end if;
  end if;
  if p_msg.campaign_id is not null or public.comms_is_marketing_key(p_msg.template_key) then
    if v_cust.id is null
       or not (case p_msg.channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end) then
      return 'the recipient withdrew marketing consent before sending';
    end if;
  end if;

  if p_msg.job_id is null and public.comms_is_appointment_key(p_msg.template_key) then
    return 'the appointment was deleted';
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
      elsif p_msg.template_key = 'appointment_reminder' and v_job.scheduled_start <= v_now then
        -- the 15 minutes of grace are only for a reminder that was due at the
        -- start itself (offset 0): the automation log row it was queued
        -- under is for this start and due at it (0034). Any earlier reminder
        -- (1 hour, 24 hours, sent by hand …) is withdrawn once it started.
        v_at_start := false;
        if to_regclass('public.job_automation_log') is not null then
          execute 'select exists (select 1 from public.job_automation_log l
                                   where l.shop_id = $1 and l.job_id = $2 and l.key = ''appointment_reminder''
                                     and $3 = any (l.message_ids) and l.scheduled_for = $4
                                     and l.due_at >= l.scheduled_for)'
            into v_at_start using p_msg.shop_id, p_msg.job_id, p_msg.id, v_job.scheduled_start;
        end if;
        if not v_at_start then
          return 'the appointment has already started';
        end if;
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
-- returns what the sender needs (unsubscribe_token: marketing email only,
-- for its List-Unsubscribe headers). Due rows that may no longer be sent are
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
  template_key  public.message_template_key,
  unsubscribe_token uuid
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
              m.campaign_id, m.template_key, m.unsubscribe_token
  )
  select u.id, u.shop_id, u.channel, u.to_address, u.from_address, u.subject, u.body, u.attempts,
         u.shop_name, u.shop_email, u.customer_id, u.job_id, u.campaign_id, u.template_key, u.unsubscribe_token
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
--                                was cancelled meanwhile) is cancelled; an
--                                appointment message is re-rendered for the
--                                job as it is now (messages_30_retry_rerender;
--                                a reminder for a time the job moved away
--                                from is cancelled, 0034).
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
-- verified by the edge function). Routes by the To number to the shop the
-- platform bound it to (shop_sms_numbers — whether or not the shop currently
-- sends from it, so replies and STOPs to a paused number are never lost)
-- and by the From number to the most recently created matching customer of
-- that shop (active customers first). Handles carrier opt-out keywords for the
-- NUMBER (comms_suppressions + every customer of the shop with it, including
-- customers created with it later):
--   STOP, STOPALL, UNSUBSCRIBE, CANCEL, END, QUIT, OPTOUT, REVOKE → opt out
--   START, UNSTOP, YES                                           → opt back in
-- Unknown senders are stored with customer_id null. Staff (owner/admin/
-- manager) get an 'inbound_message' notification. Idempotent per provider
-- id (Twilio retries). Returns no row when the To number is bound to no shop.
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
  select s.* into v_shop
    from public.shop_sms_numbers n join public.shops s on s.id = n.shop_id
   where n.phone_number = v_to;
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
  elsif v_kw in ('START', 'UNSTOP', 'YES') then
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
    nullif(left(v_body, 280), ''),
    p_customer_id => v_cust.id);

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

-- BEFORE a job is deleted: templated messages still queued for it (booking
-- confirmations, reminders, on-the-way, review requests, …) are withdrawn —
-- they describe an appointment that no longer exists and would otherwise
-- lose their job link (messages_job_fk sets job_id null) and every job
-- check with it. Free-form staff messages stay queued: a person wrote them
-- and they carry no rendered job details. Appointment messages that were in
-- flight are cancelled if they come back for a retry (comms_withdraw_reason:
-- an appointment message without a job). If the delete is refused later
-- (e.g. the job has an invoice), the withdrawal rolls back with it.
create function public.jobs_comms_withdraw_on_delete() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  -- the whole shop is being deleted (cascade): its messages go with it
  if not exists (select 1 from public.shops s where s.id = old.shop_id) then
    return old;
  end if;
  update public.messages m
     set status = 'cancelled', error = 'the appointment was deleted'
   where m.shop_id = old.shop_id and m.job_id = old.id and m.direction = 'outbound' and m.status = 'queued'
     and m.template_key is not null;
  return old;
end
$$;

create trigger jobs_zz_comms_withdraw_on_delete before delete on public.jobs
  for each row execute function public.jobs_comms_withdraw_on_delete();

-- BEFORE a message comes back for a retry (sending → queued, only
-- mark_message_result does this): an appointment message is re-rendered
-- from its current template and job, exactly as jobs_comms_sync_queued
-- re-renders queued ones. A message handed to the sender is not touched
-- when its job is rescheduled, so without this a retry after a reschedule
-- would go out with the previous date and time. Withdrawn if it now renders
-- empty or its template is gone. (Reminders whose appointment moved to
-- another time are withdrawn before this by messages_20_retry_reminder_time,
-- 0034: the new time gets its own reminder.)
create function public.messages_comms_retry_rerender() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tpl  public.message_templates;
  v_vars jsonb;
  v_shop text;
  v_subj text;
  v_body text;
begin
  if new.status <> 'queued' or old.status <> 'sending' or new.direction <> 'outbound' or new.job_id is null
     or not public.comms_is_appointment_key(new.template_key) then
    return new;
  end if;
  select * into v_tpl from public.message_templates t
   where t.shop_id = new.shop_id and t.key = new.template_key and t.channel = new.channel;
  v_vars := public.comms_job_vars(new.job_id);
  if v_tpl.id is not null and v_vars is not null then
    select s.name into v_shop from public.shops s where s.id = new.shop_id;
    select r.subject, r.body into v_subj, v_body
      from public.comms_render_parts(new.channel, v_tpl.subject, v_tpl.body, v_vars, v_shop) r;
  end if;
  if v_body is null then
    new.status := 'cancelled';
    new.error := 'the appointment changed and the message no longer applies';
    new.claimed_at := null;
  else
    new.body := v_body;
    new.subject := v_subj;
  end if;
  return new;
end
$$;

create trigger messages_30_retry_rerender before update of status on public.messages
  for each row when (old.status = 'sending' and new.status = 'queued')
  execute function public.messages_comms_retry_rerender();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.shops_sms_from_number_bound(),
  public.customers_comms_guard(),
  public.customers_attach_inbound_messages(),
  public.customers_comms_suppressed(),
  public.customers_comms_optout_sync(),
  public.customers_comms_readdress(),
  public.jobs_comms_sync_queued(),
  public.jobs_comms_withdraw_on_delete(),
  public.messages_comms_retry_rerender(),
  public.messages_record_unsubscribe_token()
from public, anon, authenticated;

-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.preview_template_message(uuid, public.message_template_key, public.message_channel) is
  '@nullable: to_address, subject';
comment on function public.claim_queued_messages(integer, timestamptz) is
  '@nullable: from_address, subject, reply_to, customer_id, job_id, campaign_id, template_key, unsubscribe_token';
comment on function public.record_inbound_sms(text, text, text, text) is '@nullable: customer_id, opt_action';

-- pure helpers (no data access)
revoke execute on function
  public.comms_address_key(public.message_channel, text),
  public.comms_is_appointment_key(public.message_template_key),
  public.comms_is_marketing_key(public.message_template_key),
  public.comms_sms_with_optout(text),
  public.comms_email_with_unsubscribe(text, text),
  public.comms_unavailable_links(text, jsonb),
  public.comms_unavailable_values(text, jsonb, boolean),
  public.comms_omit_unavailable_values(text, jsonb, boolean),
  public.comms_key_required_link(public.message_template_key),
  public.comms_render_parts(public.message_channel, text, text, jsonb, text),
  public.comms_valid_request_nonce(text)
from public, anon;
grant execute on function
  public.comms_address_key(public.message_channel, text),
  public.comms_is_appointment_key(public.message_template_key),
  public.comms_is_marketing_key(public.message_template_key),
  public.comms_sms_with_optout(text),
  public.comms_email_with_unsubscribe(text, text),
  public.comms_unavailable_links(text, jsonb),
  public.comms_unavailable_values(text, jsonb, boolean),
  public.comms_omit_unavailable_values(text, jsonb, boolean),
  public.comms_key_required_link(public.message_template_key),
  public.comms_render_parts(public.message_channel, text, text, jsonb, text),
  public.comms_valid_request_nonce(text)
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
                                   timestamptz, uuid, text),
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
                                   timestamptz, uuid, text),
  public.claim_queued_messages(integer, timestamptz),
  public.mark_message_result(uuid, public.message_status, text, text, text, timestamptz),
  public.update_message_status_by_provider_id(text, public.message_status, text),
  public.record_inbound_sms(text, text, text, text)
to service_role;

-- staff entry points (checked inside)
revoke execute on function
  public.template_vars_for_job(uuid),
  public.enqueue_template_message(uuid, public.message_template_key, timestamptz, public.message_channel, text),
  public.preview_template_message(uuid, public.message_template_key, public.message_channel),
  public.queue_message(uuid, uuid, public.message_channel, text, text, uuid, text)
from public, anon;
grant execute on function
  public.template_vars_for_job(uuid),
  public.enqueue_template_message(uuid, public.message_template_key, timestamptz, public.message_channel, text),
  public.preview_template_message(uuid, public.message_template_key, public.message_channel),
  public.queue_message(uuid, uuid, public.message_channel, text, text, uuid, text)
to authenticated, service_role;
