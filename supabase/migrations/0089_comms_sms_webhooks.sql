-- ============================================================================
-- 0089 — Self-serve SMS numbers (P-14, ships dark behind the functions'
-- SMS_PROVISIONING_ENABLED) and outbound webhooks (P-27).
--
-- SMS numbers (the `sms-provisioning` edge function; service_role):
--   record_sms_number        binds the number the platform bought for a shop
--                            (shop_sms_numbers + twilio ids) and makes it the
--                            shop's sending number
--   set_sms_verification     toll-free / 10DLC verification progress; owners
--                            and admins are notified ('sms_number_status') on
--                            every status change
--   release_sms_number       removes the provisioned binding (the foreign key
--                            clears shops.sms_from_number; 0093 logs the
--                            release)
--   sms_provisioning_status  what the settings page shows (owner/admin)
--   claim_queued_messages    (re-created, same arguments) now also returns
--                            messaging_service_sid: the Twilio Messaging
--                            Service of the shop's sending number, if any
--
-- Webhooks: every integration_events row (0041 — booking created /
-- confirmed, on the way, job completed, payment succeeded, form signed,
-- membership activated) becomes one pending delivery per active endpoint of
-- the shop subscribed to it, with a curated JSON payload fixed at that
-- moment (webhook_payload: no internal notes, no tokens, no Stripe ids).
-- The `webhooks` edge function claims due deliveries, signs them with the
-- endpoint secret and reports the outcome:
--   2xx                  succeeded (the endpoint's failure streak resets)
--   anything else        retried after 1 min, 5 min, 30 min, 2 h, 6 h, 12 h,
--                        24 h; 'dead' after the 8th attempt
--   stuck 'delivering'   (a crashed worker) re-queued after 10 minutes
-- 25 failed deliveries in a row disable the endpoint (disabled_at) and
-- notify owners / admins ('webhook_failing'); saving it active again
-- re-enables it. Endpoint management is owner/admin only; the secret is
-- shown once (create / rotate) and is never readable by API clients.
-- Endpoints must be https URLs with a host name (no IP literals in any form
-- a URL parser reads as one — dotted, octal, hex such as 127.0.0.0x1, or a
-- numeric last label — no localhost / .local / .internal names). A name
-- can still resolve to a private address, so the delivery worker must also
-- check every resolved address (loopback, private, link-local / metadata,
-- CGNAT, unique-local) before connecting.
-- ============================================================================

-- ===========================================================================
-- SMS numbers
-- ===========================================================================

-- (re-recording the same number updates its ids; a null messaging service
-- keeps the one on file)
create function public.record_sms_number(
  p_shop_id                uuid,
  p_phone_e164             text,
  p_number_sid             text,
  p_messaging_service_sid  text,
  p_kind                   text
) returns public.shop_sms_numbers
language plpgsql security definer
set search_path = ''
as $$
declare
  v_phone text := btrim(coalesce(p_phone_e164, ''));
  v_row   public.shop_sms_numbers;
begin
  if not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  if not public.is_valid_e164(v_phone) then
    raise exception 'the number must be in E.164 format' using errcode = '22023';
  end if;
  if p_number_sid is null or p_number_sid !~ '^PN[0-9a-fA-F]{32}$' then
    raise exception 'a Twilio phone number sid (PN…) is required' using errcode = '22023';
  end if;
  if p_messaging_service_sid is not null and p_messaging_service_sid !~ '^MG[0-9a-fA-F]{32}$' then
    raise exception 'the messaging service sid must look like MG…' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('tollfree', 'local') then
    raise exception 'kind must be tollfree or local' using errcode = '22023';
  end if;
  if exists (select 1 from public.shop_sms_numbers n where n.phone_number = v_phone and n.shop_id <> p_shop_id) then
    raise exception 'the number % is bound to another shop', v_phone using errcode = '23505';
  end if;
  if exists (select 1 from public.shop_sms_numbers n
              where n.shop_id = p_shop_id and n.twilio_number_sid is not null and n.phone_number <> v_phone) then
    raise exception 'this shop already has a provisioned number; release it first' using errcode = '23505';
  end if;

  insert into public.shop_sms_numbers as n (phone_number, shop_id, twilio_number_sid, messaging_service_sid, kind)
  values (v_phone, p_shop_id, p_number_sid, p_messaging_service_sid, p_kind)
  on conflict (phone_number) do update
    set twilio_number_sid = excluded.twilio_number_sid,
        messaging_service_sid = coalesce(excluded.messaging_service_sid, n.messaging_service_sid),
        kind = excluded.kind
  returning * into v_row;

  update public.shops s set sms_from_number = v_phone
   where s.id = p_shop_id and s.sms_from_number is distinct from v_phone;
  return v_row;
end
$$;

create function public.set_sms_verification(
  p_shop_id           uuid,
  p_status            text,
  p_verification_sid  text default null,
  p_rejection_reason  text default null,
  p_business_info     jsonb default null
) returns public.shop_sms_numbers
language plpgsql security definer
set search_path = ''
as $$
declare
  v_old public.shop_sms_numbers;
  v_row public.shop_sms_numbers;
begin
  if p_status is null or p_status not in ('not_started', 'pending', 'in_review', 'approved', 'rejected') then
    raise exception 'status must be not_started, pending, in_review, approved or rejected' using errcode = '22023';
  end if;
  if p_verification_sid is not null and char_length(p_verification_sid) > 64 then
    raise exception 'verification sid is too long' using errcode = '22023';
  end if;
  if p_business_info is not null and jsonb_typeof(p_business_info) <> 'object' then
    raise exception 'business info must be an object' using errcode = '22023';
  end if;
  select * into v_old from public.shop_sms_numbers n
   where n.shop_id = p_shop_id and n.twilio_number_sid is not null
   for update;
  if not found then
    raise exception 'this shop has no provisioned number' using errcode = 'P0002';
  end if;
  update public.shop_sms_numbers n
     set verification_status = p_status,
         verification_sid = coalesce(nullif(btrim(coalesce(p_verification_sid, '')), ''), n.verification_sid),
         rejection_reason = case when p_status = 'rejected'
                                 then left(nullif(btrim(coalesce(p_rejection_reason, '')), ''), 1000) end,
         business_info = coalesce(p_business_info, n.business_info),
         last_checked_at = now()
   where n.phone_number = v_old.phone_number
  returning * into v_row;

  if v_row.verification_status is distinct from v_old.verification_status and p_status <> 'not_started' then
    perform public.notify_shop_staff(
      p_shop_id, array['owner', 'admin']::public.shop_role[], 'sms_number_status',
      case p_status
        when 'approved' then 'Text messaging number approved'
        when 'rejected' then 'Text messaging number verification was rejected'
        when 'in_review' then 'Text messaging number verification is in review'
        else 'Text messaging number verification submitted' end,
      case when p_status = 'approved' then public.format_phone(v_row.phone_number) || ' can now send text messages.'
           when p_status = 'rejected' then v_row.rejection_reason end);
  end if;
  return v_row;
end
$$;

create function public.release_sms_number(p_shop_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.shop_sms_numbers n where n.shop_id = p_shop_id and n.twilio_number_sid is not null;
end
$$;

-- {number, kind, verification_status, rejection_reason, provisioned}: the
-- shop's provisioned number, else the number it sends from, else any number
-- bound to it; all null (provisioned false) when it has none. Owner/admin
-- (and service_role).
create function public.sms_provisioning_status(p_shop_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_row public.shop_sms_numbers;
begin
  if auth.uid() is not null and not public.is_shop_admin(p_shop_id) then
    raise exception 'only owners and admins can manage text messaging' using errcode = '42501';
  end if;
  select n.* into v_row
    from public.shop_sms_numbers n
    left join public.shops s on s.id = n.shop_id
   where n.shop_id = p_shop_id
   order by (n.twilio_number_sid is not null) desc, (n.phone_number = s.sms_from_number) desc nulls last,
            n.created_at desc, n.phone_number
   limit 1;
  return jsonb_build_object(
    'number', v_row.phone_number,
    'kind', v_row.kind,
    'verification_status', v_row.verification_status,
    'rejection_reason', v_row.rejection_reason,
    'provisioned', v_row.twilio_number_sid is not null);
end
$$;

-- ---------------------------------------------------------------------------
-- claim_queued_messages (re-created with the same arguments: the sender
-- also needs the Messaging Service of the shop's sending number). Unchanged
-- otherwise (see 0033).
-- ---------------------------------------------------------------------------
drop function public.claim_queued_messages(integer, timestamptz);

create function public.claim_queued_messages(p_limit integer default 50, p_now timestamptz default now())
returns table (
  id                     uuid,
  shop_id                uuid,
  channel                public.message_channel,
  to_address             text,
  from_address           text,
  subject                text,
  body                   text,
  attempts               integer,
  shop_name              text,
  reply_to               text,
  customer_id            uuid,
  job_id                 uuid,
  campaign_id            uuid,
  template_key           public.message_template_key,
  unsubscribe_token      uuid,
  messaging_service_sid  text
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
           s.sms_from_number, s.name as shop_name, s.email::text as shop_email,
           case when q.channel = 'sms' then n.messaging_service_sid end as messaging_service_sid
      from cand c
      join public.messages q on q.id = c.id
      join public.shops s on s.id = q.shop_id
      left join public.shop_sms_numbers n on n.shop_id = s.id and n.phone_number = s.sms_from_number
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
              m.campaign_id, m.template_key, m.unsubscribe_token, i.messaging_service_sid
  )
  select u.id, u.shop_id, u.channel, u.to_address, u.from_address, u.subject, u.body, u.attempts,
         u.shop_name, u.shop_email, u.customer_id, u.job_id, u.campaign_id, u.template_key, u.unsubscribe_token,
         u.messaging_service_sid
    from upd u
   where u.status = 'sending'
   order by u.send_after, u.created_at, u.id;
end
$$;

revoke execute on function public.claim_queued_messages(integer, timestamptz) from public, anon, authenticated;
grant execute on function public.claim_queued_messages(integer, timestamptz) to service_role;
comment on function public.claim_queued_messages(integer, timestamptz) is
  '@nullable: from_address, subject, reply_to, customer_id, job_id, campaign_id, template_key, unsubscribe_token, messaging_service_sid';

-- ===========================================================================
-- Webhooks
-- ===========================================================================

-- A webhook URL (22023 otherwise): https, at most 2000 characters, a host
-- NAME (no IP literal, no user:password@, not localhost / *.local /
-- *.internal / *.localhost). Returns the trimmed URL.
create function public.comms_webhook_url(p_url text) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_url  text := btrim(coalesce(p_url, ''));
  v_auth text;
  v_host text;
  v_last text;
begin
  if v_url !~ '^https://[^[:space:]]+$' or char_length(v_url) > 2000 then
    raise exception 'the webhook URL must start with https:// (max 2000 characters)' using errcode = '22023';
  end if;
  v_auth := substring(v_url from '^https://([^/?#]*)');
  if v_auth is null or v_auth = '' or strpos(v_auth, '@') > 0 then
    raise exception 'the webhook URL needs a host name (and no credentials)' using errcode = '22023';
  end if;
  v_host := lower(regexp_replace(v_auth, ':[0-9]*$', ''));
  -- IP literals in every form a URL parser accepts. WHATWG URL (Deno's
  -- fetch / new URL) parses a host as IPv4 whenever its last label (after
  -- a trailing dot) is a number: decimal, octal (leading 0) or hex (0x…,
  -- including a bare 0x), and any other label may be such a number too — so
  -- 127.0.0.0x1 is 127.0.0.1 and 169.254.169.0xfe the metadata address.
  -- Refused: IPv6 brackets, all-digit hosts, a numeric last label, and any
  -- label that is a hex number (never needed by a real host name).
  v_last := substring(rtrim(v_host, '.') from '([^.]*)$');
  if v_host ~ '^\[' or v_host ~ '^[0-9.]+$' or v_host ~ '^0x'
     or v_last ~ '^[0-9]+$' or v_last ~ '^0x[0-9a-f]*$'
     or v_host ~ '(^|\.)0x[0-9a-f]*(\.|$)' then
    raise exception 'the webhook URL must use a host name, not an IP address' using errcode = '22023';
  end if;
  if v_host !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.?$'
     or v_host in ('localhost', 'localhost.') or v_host ~ '\.(local|internal|localhost|localdomain|home|lan)\.?$' then
    raise exception 'the webhook URL must point to a public host name' using errcode = '22023';
  end if;
  return v_url;
end
$$;

-- Subscribed events (22023 otherwise): 1..8 distinct integration events.
create function public.comms_webhook_events(p_events text[]) returns text[]
language plpgsql immutable
set search_path = ''
as $$
declare
  v_out text[];
begin
  select coalesce(array_agg(distinct lower(btrim(e)) order by lower(btrim(e))), '{}') into v_out
    from unnest(coalesce(p_events, '{}')) as e where e is not null and btrim(e) <> '';
  if cardinality(v_out) not between 1 and 8
     or not v_out <@ array['booking_created', 'booking_confirmed', 'on_the_way', 'job_completed',
                           'payment_succeeded', 'form_signed', 'membership_activated'] then
    raise exception 'choose 1-8 events from booking_created, booking_confirmed, on_the_way, job_completed, payment_succeeded, form_signed, membership_activated'
      using errcode = '22023';
  end if;
  return v_out;
end
$$;

create function public.comms_webhook_secret() returns text
language sql volatile
set search_path = ''
as $$ select 'whsec_' || encode(extensions.gen_random_bytes(32), 'hex') $$;

-- An endpoint as API clients see it (never the secret).
create function public.comms_webhook_json(p_w public.webhook_endpoints) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object('id', p_w.id, 'shop_id', p_w.shop_id, 'url', p_w.url, 'description', p_w.description,
                            'events', to_jsonb(p_w.events), 'active', p_w.active,
                            'consecutive_failures', p_w.consecutive_failures, 'disabled_at', p_w.disabled_at,
                            'created_at', p_w.created_at, 'updated_at', p_w.updated_at)
$$;

-- The endpoint (locked) if the caller may manage it: another shop's /
-- unknown: P0002; members below admin: 42501.
create function public.comms_webhook_endpoint_for_admin(p_endpoint_id uuid) returns public.webhook_endpoints
language plpgsql security definer
set search_path = ''
as $$
declare
  v_w public.webhook_endpoints;
begin
  select * into v_w from public.webhook_endpoints w where w.id = p_endpoint_id for update;
  if v_w.id is null or (auth.uid() is not null and not public.is_shop_member(v_w.shop_id)) then
    raise exception 'webhook endpoint not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null and not public.is_shop_admin(v_w.shop_id) then
    raise exception 'only owners and admins can manage webhooks' using errcode = '42501';
  end if;
  return v_w;
end
$$;

-- ---------------------------------------------------------------------------
-- webhook_payload — INTERNAL: the curated body of an integration event.
-- {id, event, created_at, shop: {id, name}, data: {...}} with, per event:
--   booking_created / booking_confirmed / on_the_way / job_completed
--                        job, customer
--   payment_succeeded    payment, customer, job (when the payment has one)
--   form_signed          form, customer, job (when set)
--   membership_activated membership, customer
-- job {id, number, status, scheduled_start, scheduled_end, location_type,
-- total_cents, currency}; customer {id, first_name, last_name, email,
-- phone}; payment {id, amount_cents, tip_cents, method, kind}; membership
-- {id, plan_name, status}; form {id, title, signed_at}. Null for an unknown
-- event.
-- ---------------------------------------------------------------------------
create function public.webhook_payload(p_integration_event_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_e        public.integration_events;
  v_shop     public.shops;
  v_job_id   uuid;
  v_cust_id  uuid;
  v_data     jsonb := '{}';
begin
  select * into v_e from public.integration_events e where e.id = p_integration_event_id;
  if not found then
    return null;
  end if;
  select * into v_shop from public.shops s where s.id = v_e.shop_id;
  v_job_id := v_e.job_id;

  if v_e.payment_id is not null then
    select p.job_id, p.customer_id,
           jsonb_build_object('id', p.id, 'amount_cents', p.amount_cents, 'tip_cents', p.tip_cents,
                              'method', p.method, 'kind', p.kind)
      into v_job_id, v_cust_id, v_data
      from public.payments p where p.id = v_e.payment_id and p.shop_id = v_e.shop_id;
    v_data := jsonb_build_object('payment', v_data);
  elsif v_e.form_submission_id is not null then
    select f.job_id, f.customer_id, jsonb_build_object('id', f.id, 'title', f.title, 'signed_at', f.signed_at)
      into v_job_id, v_cust_id, v_data
      from public.form_submissions f where f.id = v_e.form_submission_id and f.shop_id = v_e.shop_id;
    v_data := jsonb_build_object('form', v_data);
  elsif v_e.membership_id is not null then
    select m.customer_id, jsonb_build_object('id', m.id, 'plan_name', mp.name, 'status', m.status)
      into v_cust_id, v_data
      from public.memberships m
      left join public.membership_plans mp on mp.id = m.plan_id and mp.shop_id = m.shop_id
     where m.id = v_e.membership_id and m.shop_id = v_e.shop_id;
    v_data := jsonb_build_object('membership', v_data);
  end if;

  if v_job_id is not null then
    select coalesce(v_cust_id, j.customer_id),
           v_data || jsonb_build_object('job', jsonb_build_object(
             'id', j.id, 'number', j.number, 'status', j.status, 'scheduled_start', j.scheduled_start,
             'scheduled_end', j.scheduled_end, 'location_type', j.location_type, 'total_cents', j.total_cents,
             'currency', v_shop.currency))
      into v_cust_id, v_data
      from public.jobs j where j.id = v_job_id and j.shop_id = v_e.shop_id;
  end if;
  if v_cust_id is not null then
    select v_data || jsonb_build_object('customer', jsonb_build_object(
             'id', c.id, 'first_name', c.first_name, 'last_name', c.last_name, 'email', c.email::text,
             'phone', c.phone))
      into v_data
      from public.customers c where c.id = v_cust_id and c.shop_id = v_e.shop_id;
  end if;

  return jsonb_build_object(
    'id', v_e.id,
    'event', v_e.event,
    'created_at', v_e.created_at,
    'shop', jsonb_build_object('id', v_shop.id, 'name', v_shop.name),
    'data', coalesce(v_data, '{}'::jsonb));
end
$$;

-- AFTER INSERT ON integration_events: one pending delivery per active,
-- subscribed endpoint of the shop. Never blocks the business write.
create function public.integration_events_comms_webhooks() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  begin
    if not exists (select 1 from public.webhook_endpoints w
                    where w.shop_id = new.shop_id and w.active and w.disabled_at is null
                      and new.event = any (w.events)) then
      return null;
    end if;
    v_payload := public.webhook_payload(new.id);
    insert into public.webhook_deliveries (shop_id, endpoint_id, integration_event_id, event, payload)
    select new.shop_id, w.id, new.id, new.event, v_payload
      from public.webhook_endpoints w
     where w.shop_id = new.shop_id and w.active and w.disabled_at is null and new.event = any (w.events)
    on conflict (endpoint_id, integration_event_id) do nothing;
  exception when others then
    raise warning 'webhook deliveries failed for integration event %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger integration_events_zz_comms_webhooks after insert on public.integration_events
  for each row execute function public.integration_events_comms_webhooks();

-- ---------------------------------------------------------------------------
-- Endpoint management (owner/admin)
-- ---------------------------------------------------------------------------
create function public.create_webhook_endpoint(
  p_shop_id      uuid,
  p_url          text,
  p_events       text[],
  p_description  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_url    text;
  v_events text[];
  v_desc   text := nullif(btrim(coalesce(p_description, '')), '');
  v_secret text := public.comms_webhook_secret();
  v_id     uuid;
begin
  if not public.is_shop_admin(p_shop_id) and auth.uid() is not null then
    raise exception 'only owners and admins can manage webhooks' using errcode = '42501';
  end if;
  if not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  v_url := public.comms_webhook_url(p_url);
  v_events := public.comms_webhook_events(p_events);
  if char_length(v_desc) > 200 then
    raise exception 'the description is too long (max 200 characters)' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.webhook_endpoints:' || p_shop_id::text, 0));
  if (select count(*) from public.webhook_endpoints w where w.shop_id = p_shop_id) >= 20 then
    raise exception 'a shop can have at most 20 webhook endpoints' using errcode = '23514';
  end if;
  insert into public.webhook_endpoints (shop_id, url, description, events, secret, created_by)
  values (p_shop_id, v_url, v_desc, v_events, v_secret, auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'secret', v_secret);
end
$$;

-- Saves an endpoint. Saving it active re-enables one the system disabled
-- (clears disabled_at and the failure streak).
create function public.update_webhook_endpoint(
  p_endpoint_id  uuid,
  p_url          text,
  p_events       text[],
  p_active       boolean,
  p_description  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_w    public.webhook_endpoints := public.comms_webhook_endpoint_for_admin(p_endpoint_id);
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
begin
  if p_active is null then
    raise exception 'active must be true or false' using errcode = '22023';
  end if;
  if char_length(v_desc) > 200 then
    raise exception 'the description is too long (max 200 characters)' using errcode = '22023';
  end if;
  update public.webhook_endpoints w
     set url = public.comms_webhook_url(p_url),
         events = public.comms_webhook_events(p_events),
         description = v_desc,
         active = p_active,
         disabled_at = case when p_active then null else w.disabled_at end,
         consecutive_failures = case when p_active and (not w.active or w.disabled_at is not null) then 0
                                     else w.consecutive_failures end
   where w.id = v_w.id
  returning * into v_w;
  return public.comms_webhook_json(v_w);
end
$$;

create function public.rotate_webhook_secret(p_endpoint_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_w      public.webhook_endpoints := public.comms_webhook_endpoint_for_admin(p_endpoint_id);
  v_secret text := public.comms_webhook_secret();
begin
  update public.webhook_endpoints w set secret = v_secret where w.id = v_w.id;
  return jsonb_build_object('secret', v_secret);
end
$$;

create function public.delete_webhook_endpoint(p_endpoint_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_w public.webhook_endpoints := public.comms_webhook_endpoint_for_admin(p_endpoint_id);
begin
  delete from public.webhook_endpoints w where w.id = v_w.id;
end
$$;

-- Queues a 'test' delivery (payload {id, event: 'test', created_at, shop,
-- data: {}}). The endpoint must be active (55000).
create function public.send_test_webhook(p_endpoint_id uuid) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_w    public.webhook_endpoints := public.comms_webhook_endpoint_for_admin(p_endpoint_id);
  v_shop text;
  v_id   uuid;
begin
  if not v_w.active or v_w.disabled_at is not null then
    raise exception 'enable the endpoint before sending a test' using errcode = '55000';
  end if;
  select s.name into v_shop from public.shops s where s.id = v_w.shop_id;
  insert into public.webhook_deliveries (shop_id, endpoint_id, event, payload)
  values (v_w.shop_id, v_w.id, 'test',
          jsonb_build_object('id', gen_random_uuid(), 'event', 'test', 'created_at', now(),
                             'shop', jsonb_build_object('id', v_w.shop_id, 'name', v_shop), 'data', '{}'::jsonb))
  returning id into v_id;
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- Delivery queue (service_role; the `webhooks` edge function)
-- ---------------------------------------------------------------------------

-- Re-queues deliveries stuck 'delivering' for 10 minutes (dead when their 8
-- attempts are used up), then locks up to p_limit due pending deliveries of
-- active endpoints (FOR UPDATE SKIP LOCKED), marks them 'delivering' and
-- counts the attempt. attempts = this attempt's number (1-based).
create function public.claim_webhook_deliveries(p_limit integer default 50, p_now timestamptz default now())
returns table (
  id           uuid,
  endpoint_id  uuid,
  url          text,
  secret       text,
  event        text,
  payload      jsonb,
  attempts     smallint
)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_now   timestamptz := coalesce(p_now, now());
begin
  update public.webhook_deliveries d
     set status = case when d.attempts >= 8 then 'dead' else 'pending' end,
         next_attempt_at = v_now,
         last_error = 'the delivery attempt timed out'
   where d.id in (select s.id from public.webhook_deliveries s
                   where s.status = 'delivering' and s.next_attempt_at < v_now - interval '10 minutes'
                   for update skip locked);

  return query
  with cand as (
    select d.id
      from public.webhook_deliveries d
      join public.webhook_endpoints w on w.id = d.endpoint_id and w.shop_id = d.shop_id
     where d.status = 'pending' and d.next_attempt_at <= v_now and w.active and w.disabled_at is null
     order by d.next_attempt_at, d.created_at, d.id
     limit v_limit
     for update of d skip locked
  ), upd as (
    update public.webhook_deliveries d
       set status = 'delivering', attempts = least(d.attempts + 1, 100), next_attempt_at = v_now
      from cand c
     where d.id = c.id
    returning d.id, d.endpoint_id, d.event, d.payload, d.attempts, d.created_at
  )
  select u.id, u.endpoint_id, w.url, w.secret, u.event, u.payload, u.attempts
    from upd u
    join public.webhook_endpoints w on w.id = u.endpoint_id
   order by u.created_at, u.id;
end
$$;

-- Outcome of a claimed delivery (see the header). A result for a delivery
-- that is no longer 'delivering' (a replay) changes nothing.
create function public.mark_webhook_delivery(
  p_id           uuid,
  p_status_code  integer,
  p_error        text default null,
  p_now          timestamptz default now()
) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  c_backoff constant interval[] := array['1 minute', '5 minutes', '30 minutes', '2 hours', '6 hours', '12 hours',
                                         '24 hours']::interval[];
  v_now  timestamptz := coalesce(p_now, now());
  v_d    public.webhook_deliveries;
  v_w    public.webhook_endpoints;
  v_host text;
begin
  if p_status_code is not null and p_status_code not between 0 and 999 then
    raise exception 'status code must be between 0 and 999' using errcode = '22023';
  end if;
  select * into v_d from public.webhook_deliveries d where d.id = p_id for update;
  if not found then
    raise exception 'delivery not found' using errcode = 'P0002';
  end if;
  if v_d.status <> 'delivering' then
    return;
  end if;

  if p_status_code between 200 and 299 then
    update public.webhook_deliveries d
       set status = 'succeeded', delivered_at = v_now, last_status_code = p_status_code, last_error = null
     where d.id = v_d.id;
    update public.webhook_endpoints w set consecutive_failures = 0
     where w.id = v_d.endpoint_id and w.consecutive_failures <> 0;
    return;
  end if;

  update public.webhook_deliveries d
     set status = case when d.attempts >= 8 then 'dead' else 'pending' end,
         next_attempt_at = case when d.attempts >= 8 then d.next_attempt_at
                                else v_now + c_backoff[least(greatest(d.attempts, 1), 7)] end,
         last_status_code = p_status_code,
         last_error = left(coalesce(nullif(btrim(coalesce(p_error, '')), ''),
                                    case when p_status_code is null then 'no response'
                                         else 'HTTP ' || p_status_code::text end), 1000)
   where d.id = v_d.id;
  update public.webhook_endpoints w
     set consecutive_failures = w.consecutive_failures + 1,
         disabled_at = case when w.disabled_at is null and w.consecutive_failures + 1 >= 25 then v_now
                            else w.disabled_at end
   where w.id = v_d.endpoint_id
  returning * into v_w;
  if v_w.disabled_at = v_now and v_w.consecutive_failures = 25 then
    v_host := substring(v_w.url from '^https://([^/?#]+)');
    perform public.notify_shop_staff(
      v_w.shop_id, array['owner', 'admin']::public.shop_role[], 'webhook_failing',
      'Webhook endpoint disabled',
      'Deliveries to ' || coalesce(v_host, 'an endpoint') || ' failed 25 times in a row. Fix the endpoint and turn it back on.');
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.integration_events_comms_webhooks() from public, anon, authenticated;

revoke execute on function
  public.record_sms_number(uuid, text, text, text, text),
  public.set_sms_verification(uuid, text, text, text, jsonb),
  public.release_sms_number(uuid),
  public.comms_webhook_secret(),
  public.comms_webhook_json(public.webhook_endpoints),
  public.comms_webhook_endpoint_for_admin(uuid),
  public.webhook_payload(uuid),
  public.claim_webhook_deliveries(integer, timestamptz),
  public.mark_webhook_delivery(uuid, integer, text, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.record_sms_number(uuid, text, text, text, text),
  public.set_sms_verification(uuid, text, text, text, jsonb),
  public.release_sms_number(uuid),
  public.comms_webhook_secret(),
  public.comms_webhook_json(public.webhook_endpoints),
  public.comms_webhook_endpoint_for_admin(uuid),
  public.webhook_payload(uuid),
  public.claim_webhook_deliveries(integer, timestamptz),
  public.mark_webhook_delivery(uuid, integer, text, timestamptz)
to service_role;

revoke execute on function
  public.comms_webhook_url(text),
  public.comms_webhook_events(text[])
from public, anon;
grant execute on function
  public.comms_webhook_url(text),
  public.comms_webhook_events(text[])
to authenticated, service_role;

revoke execute on function
  public.sms_provisioning_status(uuid),
  public.create_webhook_endpoint(uuid, text, text[], text),
  public.update_webhook_endpoint(uuid, text, text[], boolean, text),
  public.rotate_webhook_secret(uuid),
  public.delete_webhook_endpoint(uuid),
  public.send_test_webhook(uuid)
from public, anon;
grant execute on function
  public.sms_provisioning_status(uuid),
  public.create_webhook_endpoint(uuid, text, text[], text),
  public.update_webhook_endpoint(uuid, text, text[], boolean, text),
  public.rotate_webhook_secret(uuid),
  public.delete_webhook_endpoint(uuid),
  public.send_test_webhook(uuid)
to authenticated, service_role;
