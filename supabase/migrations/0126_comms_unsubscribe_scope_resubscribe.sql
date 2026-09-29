-- ============================================================================
-- 0126 — The marketing unsubscribe link ends marketing consent only, and
-- only the customer can restore it.
--
-- Before: public_unsubscribe (0083) called comms_suppress, which stamps
-- email_opted_out_at on every customer with the address, and that stamp
-- blocks ALL email (0033: queue_message 55000 'this customer has
-- unsubscribed from email'; enqueue_message_core; the claim). One click on a
-- promotion's footer therefore also stopped the customer's appointment
-- confirmations, reminders, invoices and receipts. customers_comms_guard
-- refused to clear the stamp in any client context ('an email opt-out can
-- only be cleared by the customer') while no customer-facing way back
-- existed, so nobody — the customer included — could ever opt back in.
--
-- Now (CAN-SPAM / GDPR: an unsubscribe from commercial email does not end
-- transactional email):
--
-- 1. comms_suppressions.scope ('marketing' | 'all', default 'all') and
--    .source ('link' | 'list_unsubscribe' | 'staff' | 'customer_all' |
--    'sms_stop' | 'portal'; null = recorded before 0126 / other trusted
--    code). Existing rows are 'all', so no existing opt-out is loosened.
--    SMS rows are always 'all' (STOP ends every text).
--      * comms_suppress(shop, channel, address, at, p_scope default 'all',
--        p_source default null): 'all' is 0033's full opt-out (stamps
--        email_opted_out_at / sms_opted_out_at, withdraws everything queued
--        to the address); 'marketing' only turns email_opt_in off for every
--        customer with the address and withdraws queued marketing email to
--        it — no stamp. An 'all' opt-out upgrades a 'marketing' row.
--      * comms_is_suppressed(shop, channel, address) — true for 'all' rows
--        only: what blocks every message (queue_message,
--        enqueue_message_core, the claim).
--      * comms_is_marketing_suppressed(shop, channel, address) — true for
--        any row: what blocks promotions. Checked by
--          - the claim-time re-check (comms_withdraw_reason, 0109 body):
--            a campaign / marketing-key / unsubscribe-token message to such
--            an address is withdrawn ('the recipient unsubscribed from
--            marketing before sending');
--          - messages_01_marketing_suppressed (BEFORE INSERT): a marketing
--            template message (enqueue_message_core: follow_up,
--            service_followup) to such an address is not inserted, so the
--            queueing code returns null — nothing queued;
--          - campaign audiences (campaign_audience_customers, 0035) already
--            exclude every suppressed address, whatever its scope.
--    STOP texts record source 'sms_stop' (record_inbound_sms, 0074 body);
--    opt-outs recorded on a customer record (staff, the provider)
--    'staff' (customers_comms_optout_sync, 0033 body).
--
-- 2. The /u/<token> page (public, anon):
--      public_unsubscribe(p_token, p_source default 'link') — scope
--        'marketing' ('list_unsubscribe' for the RFC 8058 one-click POST
--        the messaging function makes; anything else is 'link'): the
--        address stops getting marketing, keeps confirmations, reminders,
--        invoices and receipts. Signature changed (DROP + CREATE; callers
--        passing only p_token are unchanged).
--      public_unsubscribe_all(p_token) — "also stop appointment and invoice
--        email": scope 'all', source 'customer_all' (0083's full block).
--      public_resubscribe(p_token) — the customer opts back in: the
--        address's suppression is removed (comms_unsuppress: any scope, the
--        opt-out stamps with it) and email_opt_in turns on for the shop's
--        customers whose CURRENT email is the token's address (not
--        archived, not erased); one customer_consent_events row each
--        (action 'opt_in', source 'resubscribe_link', the caller's
--        connection as client_ip_scope). False for an unknown token or when
--        no such customer exists (then nothing changes: the suppression
--        stays with the address).
--      public_unsubscribe_info(p_token) — + scope ('marketing' | 'all' |
--        null) and can_resubscribe (a current customer has the address);
--        unsubscribed now means any scope.
--    Each is a POST (PostgREST RPC); the page never changes anything on GET.
--
-- 3. Nobody but the customer restores consent. customers_comms_guard (0033
--    body) now also covers email_opt_in: setting it on (insert, a false ->
--    true change, or a new address) while the address has ANY email
--    suppression
--      * from a client (staff through PostgREST) turning it on (an insert
--        with it on, or false -> true): 42501 'this address unsubscribed;
--        only the customer can opt back in (their unsubscribe link or the
--        client portal)'; an opt-in carried over to a new, unsubscribed
--        address just ends up off (as 0033 did);
--      * from trusted code — import_customers (0114), merge_customers
--        (0074), the membership join's consent once paid (0110), online
--        booking, lead forms, service_role: the opt-in silently stays off.
--    Clearing email_opted_out_at from a client stays refused (0033).
--    The customer's own paths remove the suppression first, so they pass:
--      public_resubscribe (above), and
--      portal_set_email_marketing(p_customer_id, p_opt_in) — signed-in
--        client whose confirmed auth email equals the customer's email
--        (else P0002): on = comms_unsuppress + email_opt_in true for that
--        customer; off = a 'marketing' suppression (source 'portal'). Both
--        log a consent event (source 'portal'). Returns the new opt-in.
--      portal_email_marketing() — the signed-in client's customers of every
--        shop whose email is their confirmed email: [{customer_id,
--        shop_slug, shop_name, email, email_opt_in, unsubscribed_scope,
--        unsubscribed_at}] for the portal toggle.
--
-- 4. customer_consent_events (shop_id, customer_id, channel, address_key,
--    action 'opt_in' | 'opt_out', source 'resubscribe_link' | 'portal',
--    client_ip (client_ip_scope), created_at): the record of consent the
--    customer gave back. Managers read; definer code writes. Removed with
--    the customer (FK cascade) and when the customer is erased (0125).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. comms_suppressions: scope + source
-- ---------------------------------------------------------------------------
alter table public.comms_suppressions
  add column scope text not null default 'all',
  add column source text,
  add constraint comms_suppressions_scope check (scope in ('marketing', 'all')),
  add constraint comms_suppressions_source check (
    source is null or source in ('link', 'list_unsubscribe', 'staff', 'customer_all', 'sms_stop', 'portal')),
  -- a STOP ends every text: SMS has no marketing-only opt-out
  add constraint comms_suppressions_sms_all check (channel = 'email' or scope = 'all');

comment on table public.comms_suppressions is
  'Per-shop opt-outs by address (SMS number / email). Survives customer edits, duplicates and deletes. scope ''all'' blocks every outbound message; ''marketing'' (email only: the unsubscribe link, 0126) blocks promotions but not confirmations, reminders, invoices or receipts.';
comment on column public.comms_suppressions.scope is
  '''all'' (0033 opt-out: nothing is sent to the address) or ''marketing'' (email only: marketing email stops, transactional email continues). Rows from before 0126 are ''all''.';
comment on column public.comms_suppressions.source is
  'How the opt-out was recorded: link (/u/ page), list_unsubscribe (one-click header), staff (recorded on a customer record, or reported by the provider), customer_all (the /u/ page''s "also stop appointment and invoice email"), sms_stop (STOP text), portal (client portal toggle). Null: before 0126 or other trusted code.';

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------
-- True when the address may not receive anything on the channel ('all').
create or replace function public.comms_is_suppressed(p_shop_id uuid, p_channel public.message_channel, p_address text)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.comms_suppressions s
                  where s.shop_id = p_shop_id and s.channel = p_channel
                    and s.address = public.comms_address_key(p_channel, p_address)
                    and s.scope = 'all')
$$;

-- True when the address may not receive marketing on the channel (any scope).
create function public.comms_is_marketing_suppressed(p_shop_id uuid, p_channel public.message_channel, p_address text)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.comms_suppressions s
                  where s.shop_id = p_shop_id and s.channel = p_channel
                    and s.address = public.comms_address_key(p_channel, p_address))
$$;

comment on function public.comms_is_suppressed(uuid, public.message_channel, text) is
  'Internal (0033; 0126): the address opted out of everything on the channel (a scope ''all'' suppression).';
comment on function public.comms_is_marketing_suppressed(uuid, public.message_channel, text) is
  'Internal (0126): the address may not get marketing on the channel (any suppression, marketing-only included).';
revoke execute on function public.comms_is_marketing_suppressed(uuid, public.message_channel, text)
  from public, anon, authenticated;
grant execute on function public.comms_is_marketing_suppressed(uuid, public.message_channel, text) to service_role;

-- ---------------------------------------------------------------------------
-- comms_suppress — + scope and source (0033 body otherwise)
-- ---------------------------------------------------------------------------
drop function public.comms_suppress(uuid, public.message_channel, text, timestamptz);

create function public.comms_suppress(
  p_shop_id  uuid,
  p_channel  public.message_channel,
  p_address  text,
  p_at       timestamptz default now(),
  p_scope    text default 'all',
  p_source   text default null
) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_addr  text := public.comms_address_key(p_channel, p_address);
  v_at    timestamptz := coalesce(p_at, now());
  v_scope text := coalesce(p_scope, 'all');
  v_id    uuid;
begin
  if p_shop_id is null or v_addr is null
     or not (case p_channel when 'sms' then public.is_valid_e164(v_addr) else public.is_valid_email(v_addr) end) then
    raise exception 'a shop, channel and valid address are required' using errcode = '22023';
  end if;
  if v_scope not in ('marketing', 'all') or (v_scope = 'marketing' and p_channel <> 'email') then
    raise exception 'scope must be all, or marketing for email' using errcode = '22023';
  end if;

  insert into public.comms_suppressions as s (shop_id, channel, address, opted_out_at, scope, source)
  values (p_shop_id, p_channel, v_addr, v_at, v_scope, p_source)
  on conflict (shop_id, channel, address) do update
     set scope = 'all', source = coalesce(excluded.source, s.source), opted_out_at = excluded.opted_out_at
   where s.scope = 'marketing' and excluded.scope = 'all'
  returning s.id into v_id;

  if p_channel = 'sms' then
    update public.customers c
       set sms_opted_out_at = coalesce(c.sms_opted_out_at, v_at), sms_opt_in = false
     where c.shop_id = p_shop_id and c.phone = v_addr
       and (c.sms_opted_out_at is null or c.sms_opt_in);
  elsif v_scope = 'all' then
    update public.customers c
       set email_opted_out_at = coalesce(c.email_opted_out_at, v_at), email_opt_in = false
     where c.shop_id = p_shop_id and lower(c.email::text) = v_addr
       and (c.email_opted_out_at is null or c.email_opt_in);
  else
    -- marketing only: consent ends, transactional email continues
    update public.customers c
       set email_opt_in = false
     where c.shop_id = p_shop_id and lower(c.email::text) = v_addr and c.email_opt_in;
  end if;

  update public.messages m
     set status = 'cancelled', error = 'the recipient opted out before sending'
   where m.shop_id = p_shop_id and m.channel = p_channel and m.direction = 'outbound' and m.status = 'queued'
     and public.comms_address_key(m.channel, m.to_address) = v_addr
     and (v_scope = 'all'
          or m.campaign_id is not null or m.unsubscribe_token is not null
          or public.comms_is_marketing_key(m.template_key));
  return v_id is not null;
end
$$;

comment on function public.comms_suppress(uuid, public.message_channel, text, timestamptz, text, text) is
  'Internal (0033; 0126): records an opt-out for an address. scope ''all'' stamps every customer of the shop with the address (and drops their marketing opt-in) and withdraws everything queued to it; ''marketing'' (email only) drops the email marketing opt-in and withdraws queued marketing email only. An ''all'' opt-out upgrades a ''marketing'' one. Returns true when the address was not suppressed at that scope before.';
revoke execute on function public.comms_suppress(uuid, public.message_channel, text, timestamptz, text, text)
  from public, anon, authenticated;
grant execute on function public.comms_suppress(uuid, public.message_channel, text, timestamptz, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- customers: stamps follow 'all' opt-outs only; marketing consent follows
-- every opt-out of the address
-- ---------------------------------------------------------------------------
-- customers_comms_suppressed (0033 body): an email stamp is recomputed from
-- the address's 'all' suppression; any suppression turns the opt-in off.
create or replace function public.customers_comms_suppressed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_at  timestamptz;
  v_any boolean;
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
    v_any := false;
    if new.email is not null then
      v_any := exists (select 1 from public.comms_suppressions x
                        where x.shop_id = new.shop_id and x.channel = 'email'
                          and x.address = public.comms_address_key('email', new.email::text));
      v_at := (select max(x.opted_out_at) from public.comms_suppressions x
                where x.shop_id = new.shop_id and x.channel = 'email' and x.scope = 'all'
                  and x.address = public.comms_address_key('email', new.email::text));
    end if;
    if tg_op = 'UPDATE' and old.email is not null
       and new.email_opted_out_at is not distinct from old.email_opted_out_at then
      new.email_opted_out_at := v_at;                     -- the previous address's stamp: recomputed
    else
      new.email_opted_out_at := coalesce(new.email_opted_out_at, v_at);
    end if;
    if coalesce(v_any, false) then
      new.email_opt_in := false;
    end if;
  end if;
  return new;
end
$$;

-- customers_comms_optout_sync (0033 body): opt-outs recorded on a customer
-- record are 'staff' opt-outs of scope 'all'.
create or replace function public.customers_comms_optout_sync() returns trigger
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
      perform public.comms_suppress(new.shop_id, 'sms', new.phone, new.sms_opted_out_at, 'all', 'staff');
    end if;
  elsif tg_op = 'UPDATE' and old.sms_opted_out_at is not null and not v_sms_moved then
    perform public.comms_unsuppress(new.shop_id, 'sms', new.phone);
  end if;

  if new.email_opted_out_at is not null then
    if new.email is not null and (tg_op = 'INSERT' or old.email_opted_out_at is null or v_email_moved) then
      perform public.comms_suppress(new.shop_id, 'email', new.email::text, new.email_opted_out_at, 'all', 'staff');
    end if;
  elsif tg_op = 'UPDATE' and old.email_opted_out_at is not null and not v_email_moved then
    perform public.comms_unsuppress(new.shop_id, 'email', new.email::text);
  end if;
  return null;
end
$$;

-- customers_comms_guard (0033 body) + the email marketing consent rule
create or replace function public.customers_comms_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- 0126: marketing email consent for an address that unsubscribed comes
  -- back only from the customer (public_resubscribe / the portal toggle,
  -- which remove the suppression first). Staff get an error; trusted code
  -- (imports, merges, bookings, joins, service_role) keeps the opt-in off.
  if new.email_opt_in and new.email is not null
     and (tg_op = 'INSERT' or not old.email_opt_in
          or public.comms_address_key('email', new.email::text)
             is distinct from public.comms_address_key('email', old.email::text))
     and exists (select 1 from public.comms_suppressions s
                  where s.shop_id = new.shop_id and s.channel = 'email'
                    and s.address = public.comms_address_key('email', new.email::text)) then
    -- staff turning it on get an error; an opt-in carried over to a new
    -- address, and trusted code, just end up off
    if public.is_client_context() and (tg_op = 'INSERT' or not old.email_opt_in) then
      raise exception 'this address unsubscribed; only the customer can opt back in (their unsubscribe link or the client portal)'
        using errcode = '42501';
    end if;
    new.email_opt_in := false;
  end if;

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

comment on column public.customers.email_opted_out_at is
  'Set when this address opts out of ALL email (the unsubscribe page''s "also stop appointment and invoice email", or staff record an opt-out); mirrors scope ''all'' comms_suppressions for every customer with the address. Blocks every email. A marketing-only unsubscribe (0126) leaves it null and turns email_opt_in off. Cleared when the customer resubscribes, or when their email changes to an address that has not opted out.';
comment on column public.customers.email_opt_in is
  'Marketing email consent. Cannot be turned on while the address has an email suppression, except by the customer (public_resubscribe / portal_set_email_marketing, 0126): staff get 42501, trusted code keeps it off.';

-- ---------------------------------------------------------------------------
-- Marketing gates
-- ---------------------------------------------------------------------------
-- A marketing template message (not a campaign: its audience already
-- excludes suppressed addresses and its recipient row needs the message) to
-- an address that unsubscribed is never inserted: the queueing code
-- (enqueue_message_core) gets no row, i.e. nothing was queued.
create function public.messages_marketing_suppressed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.comms_is_marketing_suppressed(new.shop_id, new.channel, new.to_address) then
    return null;
  end if;
  return new;
end
$$;

comment on function public.messages_marketing_suppressed() is
  'Internal (0126): a marketing template message (follow_up / service_followup, or any outbound message with an unsubscribe token that is not a campaign''s) to an address with any suppression is not inserted — nothing is queued.';
revoke execute on function public.messages_marketing_suppressed() from public, anon, authenticated;

create trigger messages_01_marketing_suppressed before insert on public.messages
  for each row
  when (new.direction = 'outbound' and new.campaign_id is null
        and (new.unsubscribe_token is not null or public.comms_is_marketing_key(new.template_key)))
  execute function public.messages_marketing_suppressed();

-- The claim-time re-check (0109 body + the marketing suppression).
create or replace function public.comms_withdraw_reason(p_msg public.messages, p_now timestamptz default now())
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
  v_quote    public.quotes;
  v_inv      public.invoices;
  v_tz       text;
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
  if p_msg.campaign_id is not null or public.comms_is_marketing_key(p_msg.template_key)
     or p_msg.unsubscribe_token is not null then
    -- 0126: an address that unsubscribed from marketing only (the /u/ link)
    -- still gets transactional messages, never a promotion
    if public.comms_is_marketing_suppressed(p_msg.shop_id, p_msg.channel, p_msg.to_address) then
      return 'the recipient unsubscribed from marketing before sending';
    end if;
    if v_cust.id is null
       or not (case p_msg.channel when 'sms' then v_cust.sms_opt_in else v_cust.email_opt_in end) then
      return 'the recipient withdrew marketing consent before sending';
    elsif v_cust.archived_at is not null then
      -- archived = soft-deleted (SPEC §2): no promotions, as campaigns and
      -- enqueue_message_core already exclude them when queueing
      return 'the customer was archived before sending';
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

  -- document follow-ups (0085): only while the document still needs them
  if p_msg.template_key = 'quote_reminder' then
    if p_msg.quote_id is not null then
      select * into v_quote from public.quotes q where q.id = p_msg.quote_id and q.shop_id = p_msg.shop_id;
    end if;
    if v_quote.id is null then
      return 'the quote was deleted';
    elsif v_quote.status not in ('sent', 'viewed') then
      return 'the quote was already answered';
    elsif v_quote.customer_id is distinct from p_msg.customer_id then
      return 'the quote now belongs to another customer';
    end if;
    select s.timezone into v_tz from public.shops s where s.id = p_msg.shop_id;
    if v_quote.valid_until is not null and public.quote_validity_end(v_quote.valid_until, v_tz) <= v_now then
      return 'the quote has expired';
    elsif v_quote.followups_paused then
      return 'follow-ups were paused for this quote';
    end if;
  elsif p_msg.template_key = 'deposit_reminder' then
    if v_job.id is null then
      return 'the appointment was deleted';
    elsif v_job.status in ('cancelled', 'no_show') then
      return 'the appointment was cancelled';
    elsif v_job.status not in ('requested', 'scheduled', 'confirmed') then
      return 'the appointment has already started';
    elsif v_job.customer_id is distinct from p_msg.customer_id then
      -- the reminder carries the job's /booking link (read + cancel): never
      -- to whoever the appointment belonged to before
      return 'the appointment now belongs to another customer';
    elsif v_job.deposit_followups_paused then
      return 'follow-ups were paused for this appointment';
    elsif public.comms_deposit_due_cents(v_job.id) <= 0 then
      return 'the deposit was paid';
    end if;
  elsif p_msg.template_key in ('invoice_reminder', 'invoice_overdue') then
    if p_msg.invoice_id is not null then
      select * into v_inv from public.invoices i where i.id = p_msg.invoice_id and i.shop_id = p_msg.shop_id;
    end if;
    if v_inv.id is null then
      return 'the invoice was deleted';
    elsif v_inv.status = 'void' then
      return 'the invoice was voided';
    elsif v_inv.status not in ('open', 'partially_paid') or v_inv.balance_cents <= 0 then
      return 'the invoice was paid';
    elsif public.comms_invoice_due_cents(v_inv.id, v_now) <= 0 then
      return 'a payment for the invoice balance is on its way';
    elsif v_inv.customer_id is distinct from p_msg.customer_id then
      return 'the invoice now belongs to another customer';
    elsif public.invoice_bills_only_cancelled_jobs(v_inv.id) then
      return 'the appointment was cancelled';
    elsif v_inv.followups_paused then
      return 'follow-ups were paused for this invoice';
    end if;
  end if;

  if p_msg.job_id is not null and p_msg.template_key in ('on_the_way', 'job_started')
     and p_msg.send_after < v_now - interval '2 hours' then
    return 'the message is too old to send';
  end if;
  if (p_msg.campaign_id is not null
      or p_msg.template_key in ('quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue',
                                'service_followup')
      or (p_msg.job_id is not null
          and (p_msg.template_key is null or p_msg.template_key not in ('quote_sent', 'invoice_sent', 'payment_receipt'))))
     and p_msg.send_after < v_now - interval '24 hours' then
    return 'the message is too old to send';
  end if;
  return null;
end
$$;

-- STOP texts are recorded as source sms_stop (0074 body).
create or replace function public.record_inbound_sms(
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

  v_cust := public.comms_inbound_sms_customer(v_shop.id, v_from);

  v_kw := upper(regexp_replace(btrim(v_body), '[[:space:][:punct:]]+$', ''));
  if v_kw in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'OPTOUT', 'REVOKE') then
    v_action := 'opt_out';
    -- the number is suppressed even when no customer has it yet
    perform public.comms_suppress(v_shop.id, 'sms', v_from, now(), 'all', 'sms_stop');
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
-- 4. customer_consent_events
-- ---------------------------------------------------------------------------
create table public.customer_consent_events (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  customer_id  uuid not null,
  channel      public.message_channel not null,
  address_key  text not null,
  action       text not null check (action in ('opt_in', 'opt_out')),
  source       text not null check (source in ('resubscribe_link', 'portal')),
  -- the caller's connection (client_ip_scope: an IPv4 address or an IPv6 /64)
  client_ip    inet,
  created_at   timestamptz not null default now(),
  constraint customer_consent_events_shop_id_id_key unique (shop_id, id),
  constraint customer_consent_events_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint customer_consent_events_address check (address_key = public.comms_address_key(channel, address_key))
);
create index customer_consent_events_shop_customer_idx on public.customer_consent_events (shop_id, customer_id, created_at desc);

comment on table public.customer_consent_events is
  'Marketing consent the customer gave or withdrew themselves (0126): the /u/ page''s resubscribe and the client portal toggle — address, action, source, the connection (client_ip_scope) and when. Managers read; written only by definer code. Deleted with the customer, and when the customer is erased (0125).';

alter table public.customer_consent_events enable row level security;
create policy customer_consent_events_select on public.customer_consent_events for select to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.customer_consent_events from anon;
revoke insert, update, delete, truncate, references, trigger on public.customer_consent_events from authenticated;

-- erasing a customer (0125) removes their consent history with the address
create function public.customers_erase_consent_events() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.customer_consent_events e where e.shop_id = new.shop_id and e.customer_id = new.id;
  return null;
end
$$;
revoke execute on function public.customers_erase_consent_events() from public, anon, authenticated;

create trigger customers_zz_erase_consent_events after update of erased_at on public.customers
  for each row when (old.erased_at is null and new.erased_at is not null)
  execute function public.customers_erase_consent_events();

-- ---------------------------------------------------------------------------
-- 2. The /u/<token> page
-- ---------------------------------------------------------------------------
drop function public.public_unsubscribe(uuid);

create function public.public_unsubscribe(p_token uuid, p_source text default 'link') returns boolean
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
  perform public.comms_suppress(v_tok.shop_id, 'email', v_tok.address, now(), 'marketing',
                                case when p_source = 'list_unsubscribe' then 'list_unsubscribe' else 'link' end);
  return true;
end
$$;

comment on function public.public_unsubscribe(uuid, text) is
  'The /u/<token> page and the one-click List-Unsubscribe POST (0035; 0083; 0126): the address the marketing email went to stops getting marketing email from the shop (a ''marketing'' suppression: email_opt_in off for every customer with it) and keeps getting confirmations, reminders, invoices and receipts. p_source ''list_unsubscribe'' for the one-click POST, else ''link''. False for an unknown token.';

create function public.public_unsubscribe_all(p_token uuid) returns boolean
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
  perform public.comms_suppress(v_tok.shop_id, 'email', v_tok.address, now(), 'all', 'customer_all');
  return true;
end
$$;

comment on function public.public_unsubscribe_all(uuid) is
  'The /u/<token> page''s "also stop appointment and invoice email" (0126): the address opts out of ALL email from the shop (scope ''all'': every customer with it is stamped email_opted_out_at). False for an unknown token.';

create function public.public_resubscribe(p_token uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tok  public.comms_unsubscribe_tokens;
  v_ip   inet := public.client_ip_scope(public.form_signer_ip());
  v_id   uuid;
begin
  if p_token is null then
    return false;
  end if;
  select * into v_tok from public.comms_unsubscribe_tokens t where t.token = p_token;
  if not found then
    return false;
  end if;
  -- someone to opt in: a current customer of the shop with that email
  perform 1 from public.customers c
   where c.shop_id = v_tok.shop_id and lower(c.email::text) = v_tok.address
     and c.archived_at is null and c.erased_at is null
   for update;
  if not found then
    return false;
  end if;
  perform public.comms_unsuppress(v_tok.shop_id, 'email', v_tok.address);
  for v_id in
    update public.customers c set email_opt_in = true
     where c.shop_id = v_tok.shop_id and lower(c.email::text) = v_tok.address
       and c.archived_at is null and c.erased_at is null
    returning c.id
  loop
    insert into public.customer_consent_events (shop_id, customer_id, channel, address_key, action, source, client_ip)
    values (v_tok.shop_id, v_id, 'email', v_tok.address, 'opt_in', 'resubscribe_link', v_ip);
  end loop;
  return true;
end
$$;

comment on function public.public_resubscribe(uuid) is
  'The /u/<token> page''s Resubscribe (0126; POST only): the person at the address opts back in — the address''s email suppression is removed (any scope) and email_opt_in turns on for the shop''s customers whose current email is that address (not archived / erased), each logged in customer_consent_events. False for an unknown token or when no such customer exists (nothing changes).';

-- public_unsubscribe_info (0090 body) + scope / can_resubscribe
create or replace function public.public_unsubscribe_info(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tok   public.comms_unsubscribe_tokens;
  v_shop  public.shops;
  v_scope text;
begin
  if p_token is not null then
    select * into v_tok from public.comms_unsubscribe_tokens t where t.token = p_token;
  end if;
  if v_tok.token is null then
    raise exception 'unsubscribe link not found' using errcode = 'PT404';
  end if;
  select * into v_shop from public.shops s where s.id = v_tok.shop_id;
  if not found then
    raise exception 'unsubscribe link not found' using errcode = 'PT404';
  end if;
  select s.scope into v_scope from public.comms_suppressions s
   where s.shop_id = v_shop.id and s.channel = 'email' and s.address = v_tok.address;
  return jsonb_build_object(
    'shop_name', v_shop.name,
    'shop_logo_path', v_shop.logo_path,
    'unsubscribed', v_scope is not null,
    'scope', v_scope,
    'can_resubscribe', exists (select 1 from public.customers c
                                where c.shop_id = v_shop.id and lower(c.email::text) = v_tok.address
                                  and c.archived_at is null and c.erased_at is null));
end
$$;

comment on function public.public_unsubscribe_info(uuid) is
  'What the /u/<token> page shows (0090; 0126): {shop_name, shop_logo_path, unsubscribed (any scope), scope (''marketing'' | ''all'' | null), can_resubscribe (a current customer of the shop has the address)}. Never the address, customer or message. Unknown token: PT404.';

-- ---------------------------------------------------------------------------
-- 3. The client portal toggle
-- ---------------------------------------------------------------------------
create function public.portal_email_marketing() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_email text := public.portal_confirmed_email();
begin
  if auth.uid() is null or v_email is null then
    raise exception 'sign in with a confirmed email to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customer_id', c.id,
             'shop_slug', s.slug,
             'shop_name', s.name,
             'email', c.email::text,
             'email_opt_in', c.email_opt_in,
             'unsubscribed_scope', x.scope,
             'unsubscribed_at', x.opted_out_at)
           order by s.name, c.created_at, c.id)
      from public.customers c
      join public.shops s on s.id = c.shop_id
      left join public.comms_suppressions x
        on x.shop_id = c.shop_id and x.channel = 'email' and x.address = public.comms_address_key('email', c.email::text)
     where c.portal_user_id = auth.uid() and lower(c.email::text) = v_email
       and c.archived_at is null and c.erased_at is null), '[]'::jsonb);
end
$$;

comment on function public.portal_email_marketing() is
  'Client portal (0126): the signed-in client''s customer records (linked, current email = their confirmed email) with their marketing email consent: [{customer_id, shop_slug, shop_name, email, email_opt_in, unsubscribed_scope, unsubscribed_at}].';

create function public.portal_set_email_marketing(p_customer_id uuid, p_opt_in boolean) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_email text := public.portal_confirmed_email();
  v_cust  public.customers;
  v_addr  text;
  v_ip    inet := public.client_ip_scope(public.form_signer_ip());
begin
  if auth.uid() is null or v_email is null then
    raise exception 'sign in with a confirmed email to use the client portal' using errcode = '42501';
  end if;
  if p_opt_in is null then
    raise exception 'choose on or off' using errcode = '22023';
  end if;
  select * into v_cust from public.customers c
   where c.id = p_customer_id and lower(c.email::text) = v_email
     and c.archived_at is null and c.erased_at is null
  for update;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  v_addr := public.comms_address_key('email', v_cust.email::text);
  if p_opt_in then
    perform public.comms_unsuppress(v_cust.shop_id, 'email', v_addr);
    update public.customers c set email_opt_in = true where c.id = v_cust.id;
  else
    perform public.comms_suppress(v_cust.shop_id, 'email', v_addr, now(), 'marketing', 'portal');
  end if;
  insert into public.customer_consent_events (shop_id, customer_id, channel, address_key, action, source, client_ip)
  values (v_cust.shop_id, v_cust.id, 'email', v_addr, case when p_opt_in then 'opt_in' else 'opt_out' end, 'portal', v_ip);
  return p_opt_in;
end
$$;

comment on function public.portal_set_email_marketing(uuid, boolean) is
  'Client portal (0126): the signed-in client turns marketing email from a shop on or off for their customer record, whose email must equal their confirmed auth email (else P0002). On removes the address''s email suppression (any scope) and sets email_opt_in; off records a marketing-only opt-out (source portal). Logged in customer_consent_events. Returns the new setting.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.public_unsubscribe(uuid, text),
  public.public_unsubscribe_all(uuid),
  public.public_resubscribe(uuid)
from public;
grant execute on function
  public.public_unsubscribe(uuid, text),
  public.public_unsubscribe_all(uuid),
  public.public_resubscribe(uuid)
to anon, authenticated, service_role;

revoke execute on function
  public.portal_email_marketing(),
  public.portal_set_email_marketing(uuid, boolean)
from public, anon;
grant execute on function
  public.portal_email_marketing(),
  public.portal_set_email_marketing(uuid, boolean)
to authenticated, service_role;
