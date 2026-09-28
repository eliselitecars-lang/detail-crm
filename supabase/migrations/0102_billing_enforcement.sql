-- ============================================================================
-- 0102 — Shop subscription billing: enforcement (read 0100 / 0101 headers).
--
-- Billing OFF changes nothing: every rule below first asks billing_enabled()
-- (shop_can_write is always true while it is off).
--
-- A LAPSED shop (0101 billing_state; can_write false) keeps reading,
-- exporting, collecting money on existing invoices and deposits, finishing
-- existing jobs and managing its billing. What stops:
--
--   * New business records created by the shop's own staff (PT402, which
--     PostgREST answers with HTTP 402): a BEFORE INSERT guard on customers,
--     jobs, quotes, invoices, campaigns, job_series and staff-written
--     outbound messages (direction 'outbound' with sent_by set: free-form
--     texts, templates sent by hand, document sends, campaign launches,
--     job report / gift card deliveries a person asked for). It applies
--     only when the request is an end user's (the PostgREST role
--     `authenticated`, also inside SECURITY DEFINER RPCs they call) and that
--     user is an active member of the row's shop: service_role, pg_cron and
--     the webhooks are never blocked by it, and customer-facing flows
--     (portal clients, anonymous visitors) are handled explicitly below.
--     Messages a system event queues (sent_by null: booking confirmations,
--     job status texts, receipts) still go out — they belong to work the
--     shop may finish. enqueue_customer_template refuses a staff send
--     (p_sent_by set) the same way when the service role queues it for a
--     person (the `messaging` function's customer-level templates).
--     Message: 'This shop''s subscription is inactive, so new records can''t
--     be created right now.' (neutral: shown verbatim on iPhone).
--   * Online booking: create_online_booking, public_booking_slots (and so
--     get_available_slots), public_booking_catalog and public_booking_link
--     answer the existing 55000 'online booking is not enabled for this
--     shop'; public_shop_profile reports booking.enabled false (and no
--     tracking ids); quote self-scheduling reads as unavailable
--     (quote_self_schedule_reason). create_online_booking keeps 0054's body
--     unchanged as create_online_booking_core (internal) behind a wrapper
--     with the same signature, grants and error codes.
--   * Batches skip lapsed shops (a filter — never an error inside the batch,
--     so other shops are unaffected; nothing is logged for the skipped shop,
--     so what falls due within 24 h of a renewal still goes out):
--     enqueue_due_automations (reminders, review requests, follow-ups),
--     enqueue_service_followups, enqueue_document_followups, and
--     claim_queued_messages for campaign messages (they stay queued; the
--     claim's 24 h staleness rule withdraws them after a longer lapse).
--     Task reminders (staff-only) keep running.
--
-- Seat limits (every shop with a limit in force, 0101 billing_max_members):
-- inviting a member (shop_invites) and adding or re-activating a member
-- (shop_members) through an API request must keep active members + pending
-- unexpired invites <= max_members, else PT402 'This shop''s plan allows N
-- team members.' (N = 1: '1 team member'). Accepting an invite never fails
-- for seats: its pending invite already holds the seat. Serialised per shop
-- (advisory lock) so concurrent invites cannot both take the last seat.
-- service_role / the operator are not limited.
--
-- Every replaced function keeps its signature exactly; each is 0102's copy
-- of its latest definition (named in its comment) with only the billing
-- condition added.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- The request is a signed-in end user's (PostgREST role authenticated; the
-- `role` setting survives SECURITY DEFINER, the JWT claim is a second
-- signal). service_role, pg_cron and direct database sessions are not.
create function public.billing_is_end_user() returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(current_setting('role', true), '') = 'authenticated'
      or coalesce(auth.role(), '') = 'authenticated'
$$;

create function public.billing_inactive_message() returns text
language sql immutable
set search_path = ''
as $$ select 'This shop''s subscription is inactive, so new records can''t be created right now.'::text $$;

create function public.billing_seats_message(p_max integer) returns text
language sql immutable
set search_path = ''
as $$
  select 'This shop''s plan allows ' || p_max::text || case when p_max = 1 then ' team member.' else ' team members.' end
$$;

-- ---------------------------------------------------------------------------
-- PT402 guard on new business records (see the header).
-- ---------------------------------------------------------------------------
create function public.billing_guard_new_record() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if public.billing_enabled()
     and public.billing_is_end_user()
     and public.is_shop_member(new.shop_id)
     and not public.shop_can_write(new.shop_id) then
    raise exception '%', public.billing_inactive_message() using errcode = 'PT402';
  end if;
  return new;
end
$$;

create trigger customers_01_billing_guard before insert on public.customers
  for each row execute function public.billing_guard_new_record();
create trigger jobs_01_billing_guard before insert on public.jobs
  for each row execute function public.billing_guard_new_record();
create trigger quotes_01_billing_guard before insert on public.quotes
  for each row execute function public.billing_guard_new_record();
create trigger invoices_01_billing_guard before insert on public.invoices
  for each row execute function public.billing_guard_new_record();
create trigger campaigns_01_billing_guard before insert on public.campaigns
  for each row execute function public.billing_guard_new_record();
create trigger job_series_01_billing_guard before insert on public.job_series
  for each row execute function public.billing_guard_new_record();
create trigger messages_01_billing_guard before insert on public.messages
  for each row when (new.direction = 'outbound' and new.sent_by is not null)
  execute function public.billing_guard_new_record();

-- ---------------------------------------------------------------------------
-- Seat limits (see the header). After the membership client guard (10), so
-- a caller without the right to change members still gets 42501.
-- ---------------------------------------------------------------------------
create function public.billing_invite_seat_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_max integer;
begin
  if not public.billing_enabled() or not public.is_api_request()
     or new.accepted_at is not null or new.revoked_at is not null or new.expires_at <= now() then
    return new;
  end if;
  v_max := public.billing_max_members(new.shop_id);
  if v_max is null then
    return new;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.billing_seats:' || new.shop_id::text, 0));
  -- an address that already is an active member takes no new seat
  if exists (select 1 from public.shop_members m join auth.users u on u.id = m.user_id
              where m.shop_id = new.shop_id and m.active and lower(u.email) = lower(new.email::text)) then
    return new;
  end if;
  if public.billing_seats_used(new.shop_id, null, new.email::text) + 1 > v_max then
    raise exception '%', public.billing_seats_message(v_max) using errcode = 'PT402';
  end if;
  return new;
end
$$;

create function public.billing_member_seat_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_max   integer;
  v_email text;
begin
  if not public.billing_enabled() or not public.is_api_request() or not new.active then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if old.active then
      return new;                            -- already holds a seat
    end if;
  end if;
  v_max := public.billing_max_members(new.shop_id);
  if v_max is null then
    return new;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.billing_seats:' || new.shop_id::text, 0));
  select u.email into v_email from auth.users u where u.id = new.user_id;
  -- accepting an invite: the pending invite already holds this seat
  if v_email is not null and exists (
       select 1 from public.shop_invites i
        where i.shop_id = new.shop_id and lower(i.email::text) = lower(v_email)
          and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()) then
    return new;
  end if;
  if public.billing_seats_used(new.shop_id, new.user_id, v_email) + 1 > v_max then
    raise exception '%', public.billing_seats_message(v_max) using errcode = 'PT402';
  end if;
  return new;
end
$$;

create trigger shop_invites_15_billing_seats before insert on public.shop_invites
  for each row execute function public.billing_invite_seat_guard();
create trigger shop_members_15_billing_seats before insert or update of active on public.shop_members
  for each row execute function public.billing_member_seat_guard();

-- ---------------------------------------------------------------------------
-- enqueue_customer_template (0083's body; same signature): a staff send
-- (p_sent_by set) of a lapsed shop is refused with PT402 in every context —
-- the service role queues customer-level templates on a person's behalf.
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
  if p_sent_by is not null and not public.shop_can_write(p_shop_id) then
    raise exception '%', public.billing_inactive_message() using errcode = 'PT402';
  end if;
  select * into v_tpl from public.message_templates t
   where t.shop_id = p_shop_id and t.key = p_key and t.channel = p_channel and t.enabled;
  return public.enqueue_message_core(p_shop_id, p_customer_id, p_key, p_channel, v_tpl.subject, v_tpl.body,
                                     p_job_id, p_extra_vars, p_send_after, p_sent_by, p_request_nonce);
end
$$;

-- ---------------------------------------------------------------------------
-- Online booking of a lapsed shop is unavailable (55000, as when the shop
-- turned it off).
-- ---------------------------------------------------------------------------
-- create_online_booking: 0054's function, unchanged, becomes internal.
alter function public.create_online_booking(text, jsonb, timestamptz) rename to create_online_booking_core;
comment on function public.create_online_booking_core(text, jsonb, timestamptz) is
  'Internal (0102): the online booking of 0054 (0042 rules). Called only by create_online_booking, which refuses lapsed shops first.';
revoke execute on function public.create_online_booking_core(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.create_online_booking_core(text, jsonb, timestamptz) to service_role;

create function public.create_online_booking(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  return public.create_online_booking_core(p_slug, p_payload, p_now);
end
$$;

comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap; 0102: a lapsed shop answers 55000).';
revoke execute on function public.create_online_booking(text, jsonb, timestamptz) from public;
grant execute on function public.create_online_booking(text, jsonb, timestamptz) to anon, authenticated, service_role;

-- public_booking_slots (0053) — + lapsed shops (get_available_slots wraps it).
create or replace function public.public_booking_slots(
  p_slug                 text,
  p_service_ids          uuid[],
  p_from                 date,
  p_to                   date,
  p_vehicle_category_id  uuid default null,
  p_location_type        public.location_type default null,
  p_link_token           uuid default null,
  p_now                  timestamptz default now()
) returns table (starts_at timestamptz, ends_at timestamptz)
language plpgsql stable security definer
set search_path = ''
set jit = off
as $$
#variable_conflict use_column
declare
  c_max_range_days constant integer := 62;
  v_shop      public.shops;
  v_bs        public.booking_settings;
  v_ids       uuid[];
  v_link_ids  uuid[];
  v_found     integer;
  v_duration  integer;
  v_cats      uuid[];
  v_loc       public.location_type;
begin
  if p_slug is null or p_from is null or p_to is null then
    raise exception 'shop slug and date range are required' using errcode = '22023';
  end if;
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  if not found or not v_bs.enabled or not public.shop_can_write(v_shop.id) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if p_to < p_from then
    raise exception 'p_to must be on or after p_from' using errcode = '22023';
  end if;
  if p_to - p_from + 1 > c_max_range_days then
    raise exception 'date range cannot exceed % days', c_max_range_days using errcode = '22023';
  end if;

  v_ids := array(select distinct x from unnest(p_service_ids) as x where x is not null);
  if coalesce(cardinality(v_ids), 0) = 0 then
    raise exception 'choose at least one service' using errcode = '22023';
  end if;
  if cardinality(v_ids) > 50 then
    raise exception 'too many services' using errcode = '22023';
  end if;
  if p_vehicle_category_id is not null and not exists (
       select 1 from public.vehicle_categories vc
       where vc.id = p_vehicle_category_id and vc.shop_id = v_shop.id) then
    raise exception 'unknown vehicle category' using errcode = '22023';
  end if;
  if p_link_token is not null then
    v_link_ids := public.booking_link_service_ids(v_shop.id, p_link_token);
    if v_link_ids is null then
      raise exception 'booking link not found' using errcode = 'PT404';
    end if;
  end if;
  if p_location_type = 'mobile' and v_shop.business_type = 'fixed' then
    raise exception 'this shop does not offer mobile service' using errcode = '22023';
  end if;
  if p_location_type = 'shop' and v_shop.business_type = 'mobile' then
    raise exception 'this shop only offers mobile service' using errcode = '22023';
  end if;
  -- the location a booking without one gets (create_online_booking, 0054)
  v_loc := coalesce(p_location_type,
                    case when v_shop.business_type = 'mobile' then 'mobile'::public.location_type
                         else 'shop'::public.location_type end);

  select count(*), sum(sp.duration_minutes)
    into v_found, v_duration
    from public.services s
    cross join lateral public.service_price_for(s.id, p_vehicle_category_id) sp
   where s.id = any (v_ids)
     and s.shop_id = v_shop.id
     and s.active
     and s.archived_at is null
     and case when v_link_ids is null then s.online_bookable else s.id = any (v_link_ids) end;
  if v_found <> cardinality(v_ids) then
    raise exception 'one or more services are not available for online booking' using errcode = '22023';
  end if;
  if coalesce(v_duration, 0) <= 0 then
    raise exception 'the selected services have no duration' using errcode = '22023';
  end if;
  v_cats := array(select distinct s.category_id from public.services s
                   where s.id = any (v_ids) and s.shop_id = v_shop.id and s.category_id is not null);

  return query
    select c.starts_at, c.ends_at
      from public.booking_slots_core(v_shop.id, v_duration, p_from, p_to, public.effective_now(p_now),
                                     v_loc, v_cats) c;
end
$$;

-- public_booking_catalog (0053 v2) — + lapsed shops.
create or replace function public.public_booking_catalog(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop    public.shops;
  v_enabled boolean;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) or not public.shop_can_write(v_shop.id) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  return public.booking_catalog_json(v_shop.id, null);
end
$$;

-- public_booking_link (0053) — + lapsed shops.
create or replace function public.public_booking_link(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_link    public.booking_links;
  v_shop    public.shops;
  v_enabled boolean;
begin
  select * into v_link from public.booking_links l where l.token = p_token;
  if not found or not v_link.active or (v_link.expires_at is not null and v_link.expires_at <= now()) then
    raise exception 'booking link not found' using errcode = 'PT404';
  end if;
  select * into v_shop from public.shops s where s.id = v_link.shop_id;
  select b.enabled into v_enabled from public.booking_settings b where b.shop_id = v_shop.id;
  if not coalesce(v_enabled, false) or not public.shop_can_write(v_shop.id) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  return jsonb_build_object(
    'slug', v_shop.slug,
    'name', v_link.name,
    'note', v_link.note,
    'expires_at', v_link.expires_at,
    'catalog', public.booking_catalog_json(v_shop.id, public.booking_link_service_ids(v_shop.id, p_token)));
end
$$;

-- public_shop_profile (0088) — booking.enabled / tracking read false / null
-- for a lapsed shop.
create or replace function public.public_shop_profile(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_bs   public.booking_settings;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  return jsonb_build_object(
    'name', v_shop.name,
    'slug', v_shop.slug,
    'logo_path', v_shop.logo_path,
    'brand_color', v_shop.brand_color,
    'phone', v_shop.phone,
    'website', v_shop.website,
    'city', v_shop.city,
    'region', v_shop.region,
    'country', v_shop.country,
    'timezone', v_shop.timezone,
    'currency', v_shop.currency,
    'business_type', v_shop.business_type,
    'tax_rate_bps', v_shop.tax_rate_bps,
    'booking', jsonb_build_object(
      'enabled', (coalesce(v_bs.enabled, false) and public.shop_can_write(v_shop.id)),
      'auto_confirm', coalesce(v_bs.auto_confirm, false),
      'lead_time_minutes', v_bs.lead_time_minutes,
      'max_days_ahead', v_bs.max_days_ahead,
      'slot_interval_minutes', v_bs.slot_interval_minutes,
      'require_deposit', coalesce(v_bs.require_deposit, false),
      'deposit_type', case when v_bs.require_deposit then v_bs.deposit_type end,
      'deposit_value', case when v_bs.require_deposit then v_bs.deposit_value end,
      'service_area_limited', coalesce(cardinality(v_bs.service_area_postal_codes), 0) > 0,
      'booking_message', v_bs.booking_message,
      'cancellation_policy', v_bs.cancellation_policy,
      'allow_client_cancel_hours', v_bs.allow_client_cancel_hours),
    'tracking', jsonb_build_object(
      'meta_pixel_id', case when (coalesce(v_bs.enabled, false) and public.shop_can_write(v_shop.id)) then v_bs.meta_pixel_id end,
      'ga4_measurement_id', case when (coalesce(v_bs.enabled, false) and public.shop_can_write(v_shop.id)) then v_bs.ga4_measurement_id end));
end
$$;

-- quote_self_schedule_reason (0067) — a lapsed shop's quotes cannot be
-- scheduled online (a new job).
create or replace function public.quote_self_schedule_reason(p_quote public.quotes) returns text
language sql stable
set search_path = ''
as $$
  select case
    when p_quote.status = 'converted' then 'this quote has already been scheduled'
    when p_quote.status <> 'approved' then 'approve the quote before scheduling it'
    when not p_quote.self_schedule then 'this quote cannot be scheduled online; please contact the shop'
    when not coalesce((select b.enabled and b.quote_self_schedule and public.shop_can_write(b.shop_id) from public.booking_settings b
                        where b.shop_id = p_quote.shop_id), false)
      then 'online scheduling is not available; please contact the shop'
  end
$$;

-- ---------------------------------------------------------------------------
-- Batches skip lapsed shops (a filter; see the header).
-- ---------------------------------------------------------------------------
-- enqueue_due_automations (0086)
create or replace function public.enqueue_due_automations(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := coalesce(p_now, now());
  v_stale    timestamptz := coalesce(p_now, now()) - interval '24 hours';
  v_due      record;
  v_log_id   uuid;
  v_ch       public.message_channel;
  v_msg      uuid;
  v_ids      uuid[];
  v_send_after timestamptz;
  v_total    integer := 0;
begin
  -- Customer links (booking, quote, invoice, booking page, unsubscribe) need
  -- the web app origin. Refuse to run rather than log due automations as
  -- 'skipped' for good: once configured, the next run catches up on
  -- everything still inside the 24 hour window.
  if public.app_url('/') is null then
    raise exception 'app_base_url is not configured; automations cannot build customer links'
      using errcode = '55000', hint = 'Run supabase/setup/cron.sql (public.set_app_base_url).';
  end if;

  for v_due in
    with tpl as (
      select t.shop_id, t.key, max(t.offset_minutes) as offset_minutes,
             max(t.reminder_offsets_minutes) as offsets    -- shared by every channel of the key
        from public.message_templates t
       where t.enabled and t.key in ('appointment_reminder', 'review_request', 'follow_up')
         and public.shop_can_write(t.shop_id)       -- lapsed shops are skipped (0102)
       group by t.shop_id, t.key
    ), reminder_offsets as (
      -- ascending: prev_offset = the reminder before this one, next_offset = the one after it
      select o.shop_id, x.off, o.offsets is not null as multi,
             lag(x.off) over (partition by o.shop_id order by x.off) as prev_offset,
             lead(x.off) over (partition by o.shop_id order by x.off) as next_offset
        from tpl o
        cross join lateral unnest(coalesce(o.offsets, array[o.offset_minutes])) as x(off)
       where o.key = 'appointment_reminder'
    ), reminders as (
      select j.shop_id, j.id as job_id, j.customer_id, 'appointment_reminder'::public.message_template_key as key,
             j.scheduled_start as scheduled_for, j.scheduled_start + make_interval(mins => r.off) as due_at,
             r.off as reminder_offset, r.prev_offset, r.next_offset, r.multi
        from reminder_offsets r
        join public.jobs j on j.shop_id = r.shop_id
       where j.status in ('scheduled', 'confirmed')
         and not exists (select 1 from public.job_automation_log l
                          where l.job_id = j.id and l.key = 'appointment_reminder'
                            and l.scheduled_for = j.scheduled_start and l.customer_id = j.customer_id
                            and public.comms_reminder_log_covers(l.reminder_offset_minutes, l.processed_at, r.off,
                                                                 j.scheduled_start + make_interval(mins => r.off), r.multi))
         and j.scheduled_start + make_interval(mins => r.off) <= v_now
         -- stale only 24 h after it could first have been sent
         and greatest(j.scheduled_start + make_interval(mins => r.off), j.appointment_set_at) > v_stale
         and v_now < j.scheduled_start + case when r.off = 0 then interval '15 minutes'
                                              else interval '0 minutes' end
    )
    select r.shop_id, r.job_id, r.customer_id, r.key, r.scheduled_for, r.due_at, r.reminder_offset,
           r.prev_offset, r.next_offset, r.multi,
           -- several offsets due at once: only the one nearest the appointment is sent
           row_number() over (partition by r.job_id order by r.reminder_offset desc) = 1 as latest
      from reminders r
    union all
    -- review requests and follow-ups
    select j.shop_id, j.id, j.customer_id, o.key, null::timestamptz,
           j.completed_at + make_interval(mins => o.offset_minutes), null::integer, null::integer, null::integer,
           false, true
      from tpl o
      join public.shops s on s.id = o.shop_id
      join public.jobs j on j.shop_id = o.shop_id
     where o.key in ('review_request', 'follow_up')
       and (o.key <> 'review_request' or (s.review_url is not null and btrim(s.review_url) <> ''))
       and j.status = 'completed'
       and (o.key <> 'review_request' or j.review_requested_at is null)
       and j.completed_at is not null
       and j.completed_at <= v_now - make_interval(mins => o.offset_minutes)
       and j.completed_at > v_stale - make_interval(mins => o.offset_minutes)
    order by 6, 2, 4, 7
  loop
    insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes,
                                           due_at, processed_at, outcome)
    values (v_due.shop_id, v_due.job_id, v_due.customer_id, v_due.key, v_due.scheduled_for,
            case when v_due.multi then v_due.reminder_offset end,   -- a single reminder is logged as before P-4
            v_due.due_at, v_now, 'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- already processed (this or another run)
    if not v_due.latest then                 -- superseded by a reminder nearer the appointment
      v_log_id := null;
      continue;
    end if;

    v_ids := '{}';
    -- promotional (follow_up): only between 08:00 and 21:00 shop-local, else
    -- held until the next 10:00 there; transactional keys go out now
    v_send_after := v_now;
    if public.comms_is_marketing_key(v_due.key) then
      select public.comms_marketing_send_after(v_now, s.timezone) into v_send_after
        from public.shops s where s.id = v_due.shop_id;
      v_send_after := coalesce(v_send_after, v_now);
    end if;
    foreach v_ch in array enum_range(null::public.message_channel) loop
      -- a job moved to another customer: an address that already got this
      -- appointment time's reminder (at this offset, as a former customer's
      -- copy) is not reminded twice
      continue when v_due.key = 'appointment_reminder' and exists (
        select 1
          from public.job_automation_log l
          join public.messages m on m.id = any (l.message_ids) and m.shop_id = l.shop_id
          join public.customers c on c.id = v_due.customer_id and c.shop_id = v_due.shop_id
         where l.job_id = v_due.job_id and l.key = 'appointment_reminder'
           and l.scheduled_for = v_due.scheduled_for and l.customer_id <> v_due.customer_id
           and public.comms_reminder_log_covers(l.reminder_offset_minutes, l.processed_at, v_due.reminder_offset,
                                                v_due.due_at, v_due.multi)
           and m.channel = v_ch and m.status in ('queued', 'sending', 'sent', 'delivered')
           and public.comms_address_key(m.channel, m.to_address)
               = public.comms_address_key(v_ch, case v_ch when 'sms' then c.phone else c.email::text end));
      -- staff already sent this job's message on the channel by hand
      -- (enqueue_template_message; not failed / withdrawn): not sent twice.
      -- A reminder counts only when it announces the job's current
      -- appointment for this customer: still queued (re-rendered on every
      -- reschedule) to go out BEFORE the appointment starts, or created
      -- since the job got its current time — and, with several reminder
      -- offsets, only for the offset whose window it went out in (a
      -- reminder a week ahead does not stand in for the one a day before). A queued one scheduled for the start or
      -- later would be withdrawn at the claim and remind nobody, so it does
      -- not stand in for this reminder. Reminders the automation queued are
      -- tracked by their log rows instead.
      continue when exists (
        select 1
          from public.messages m
          join public.jobs j on j.id = m.job_id and j.shop_id = m.shop_id
         where m.shop_id = v_due.shop_id and m.job_id = v_due.job_id and m.direction = 'outbound'
           and m.template_key = v_due.key and m.channel = v_ch and m.status not in ('failed', 'cancelled')
           and (v_due.key <> 'appointment_reminder'
                or (m.customer_id = v_due.customer_id
                    and ((m.status = 'queued' and m.send_after < j.scheduled_start)
                         or (m.status <> 'queued' and m.created_at >= j.appointment_set_at))
                    -- several offsets: only a reminder that went out in this offset's
                    -- window [its due time, the next offset's due time) stands in for it
                    and (v_due.prev_offset is null
                         or greatest(m.created_at, m.send_after)
                              >= j.scheduled_start + make_interval(mins => v_due.reminder_offset))
                    and (v_due.next_offset is null
                         or greatest(m.created_at, m.send_after)
                              < j.scheduled_start + make_interval(mins => v_due.next_offset))
                    and not exists (select 1 from public.job_automation_log l
                                     where l.shop_id = v_due.shop_id and l.job_id = v_due.job_id
                                       and l.key = 'appointment_reminder' and m.id = any (l.message_ids)))));
      v_msg := public.enqueue_customer_template(v_due.shop_id, v_due.customer_id, v_due.key, v_ch,
                                                v_due.job_id, null, v_send_after, null);
      if v_msg is not null then
        v_ids := v_ids || v_msg;
      end if;
    end loop;

    if cardinality(v_ids) > 0 then
      update public.job_automation_log l set outcome = 'queued', message_ids = v_ids where l.id = v_log_id;
      if v_due.key = 'appointment_reminder' then
        update public.jobs j set reminder_sent_at = v_now where j.id = v_due.job_id and j.shop_id = v_due.shop_id;
      elsif v_due.key = 'review_request' then
        update public.jobs j set review_requested_at = v_now where j.id = v_due.job_id and j.shop_id = v_due.shop_id;
      end if;
      v_total := v_total + cardinality(v_ids);
    end if;
    v_log_id := null;
  end loop;

  v_total := v_total + public.enqueue_document_followups(v_now);
  v_total := v_total + public.enqueue_service_followups(v_now);
  v_total := v_total + public.enqueue_task_reminders(v_now);
  return v_total;
end
$$;

-- enqueue_service_followups (0086)
create or replace function public.enqueue_service_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := coalesce(p_now, now());
  v_due    record;
  v_log_id uuid;
  v_msg    uuid;
  v_total  integer := 0;
begin
  for v_due in
    with job_services as (
      select distinct li.shop_id, li.job_id, li.service_id
        from public.job_line_items li
       where li.service_id is not null
      union
      select li.shop_id, li.job_id, pi.service_id
        from public.job_line_items li
        join public.package_items pi on pi.package_id = li.service_id and pi.shop_id = li.shop_id
    )
    select j.shop_id, j.id as job_id, j.customer_id, f.id as followup_id, f.service_id, f.channel,
           f.subject, f.body, d.due_at, s.timezone,
           case when b.enabled then public.app_url('/book/' || s.slug || '?services=' || f.service_id::text
                                                   || coalesce('&category=' || v.category_id::text, '')) end
             as rebook_link
      from public.service_followups f
      join public.message_templates t on t.shop_id = f.shop_id and t.key = 'service_followup'
                                     and t.channel = f.channel and t.enabled
      join public.shops s on s.id = f.shop_id
      left join public.booking_settings b on b.shop_id = f.shop_id
      join job_services js on js.shop_id = f.shop_id and js.service_id = f.service_id
      join public.jobs j on j.id = js.job_id and j.shop_id = js.shop_id
      left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
      -- 10:00 shop-local on the local date of completed_at + offset_days
      cross join lateral (
        select public.comms_followup_due_at(j.completed_at, make_interval(days => f.offset_days), interval '0',
                                            true, s.timezone, 1) as due_at) d
     where f.enabled
       and public.shop_can_write(f.shop_id)          -- lapsed shops are skipped (0102)
       and j.status = 'completed' and j.completed_at is not null
       and d.due_at <= v_now
       and d.due_at > v_now - interval '24 hours'
       and not exists (select 1 from public.job_automation_log l
                        where l.job_id = j.id and l.key = 'service_followup' and l.service_followup_id = f.id)
       -- the customer already has the service again: any open job (requested,
       -- scheduled or under way, whatever its dates — a request logged while
       -- this job was being worked is still a request), or a job completed
       -- after this one
       and not exists (
         select 1
           from public.jobs j2
           join public.job_line_items l2 on l2.job_id = j2.id and l2.shop_id = j2.shop_id
          where j2.shop_id = j.shop_id and j2.customer_id = j.customer_id and j2.id <> j.id
            and (j2.status in ('requested', 'scheduled', 'confirmed', 'en_route', 'in_progress')
                 or (j2.status = 'completed'
                     and coalesce(j2.completed_at, j2.scheduled_start, j2.created_at) > j.completed_at))
            and (l2.service_id = f.service_id
                 or exists (select 1 from public.package_items pi
                             where pi.shop_id = l2.shop_id and pi.package_id = l2.service_id
                               and pi.service_id = f.service_id)))
     order by d.due_at, j.id, f.sort, f.id
  loop
    insert into public.job_automation_log (shop_id, job_id, customer_id, key, service_followup_id, due_at,
                                           processed_at, outcome)
    values (v_due.shop_id, v_due.job_id, v_due.customer_id, 'service_followup', v_due.followup_id, v_due.due_at,
            v_now, 'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;

    v_msg := public.enqueue_message_core(v_due.shop_id, v_due.customer_id, 'service_followup', v_due.channel,
                                         v_due.subject, v_due.body, v_due.job_id,
                                         jsonb_build_object('rebook_link', v_due.rebook_link),
                                         public.comms_marketing_send_after(v_now, v_due.timezone));
    if v_msg is not null then
      update public.job_automation_log l set outcome = 'queued', message_ids = array[v_msg] where l.id = v_log_id;
      v_total := v_total + 1;
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;

-- enqueue_document_followups (0085)
create or replace function public.enqueue_document_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := coalesce(p_now, now());
  v_due    record;
  v_tpl    public.message_templates;
  v_log_id uuid;
  v_vars   jsonb;
  v_msg    uuid;
  v_ids    uuid[];
  v_total  integer := 0;
begin
  for v_due in
    with due as (
      select c.*, n.attempt,
             public.comms_followup_due_at(c.base_at, c.first_after, c.repeat_every, c.in_days, c.timezone, n.attempt)
               as due_at
        from public.comms_followup_candidates(v_now) c
        -- (max_attempts <= 10; a constant series keeps the row estimate small)
        cross join lateral (select g from generate_series(1, 10) as g where g <= c.max_attempts) as n(attempt)
       where not exists (select 1 from public.document_followup_log l
                          where l.doc_kind = c.doc_kind and l.doc_id = c.doc_id and l.attempt = n.attempt)
    )
    select d.*,
           row_number() over (partition by d.doc_kind, d.doc_id order by d.attempt desc) = 1 as latest
      from due d
     where d.due_at <= v_now
       and public.shop_can_write(d.shop_id)          -- lapsed shops are skipped (0102)
       -- only inside waking hours (08:00-21:00 shop time): a late run at
       -- night leaves the attempt for the morning run (still within 24 h)
       and (v_now at time zone d.timezone)::time >= time '08:00'
       and (v_now at time zone d.timezone)::time < time '21:00'
     order by d.due_at, d.doc_kind, d.doc_id, d.attempt
  loop
    insert into public.document_followup_log (shop_id, doc_kind, doc_id, attempt, due_at, processed_at, outcome)
    values (v_due.shop_id, v_due.doc_kind, v_due.doc_id, v_due.attempt, v_due.due_at, v_now, 'skipped')
    on conflict (doc_kind, doc_id, attempt) do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- processed by a concurrent run
    -- superseded by a later attempt, or stale: logged as skipped
    if not v_due.latest or v_due.due_at <= v_now - interval '24 hours' then
      v_log_id := null;
      continue;
    end if;

    v_vars := case v_due.doc_kind
      when 'quote' then public.comms_quote_vars(v_due.quote_id)
      when 'deposit' then jsonb_build_object(
        'deposit_link', (select public.app_url('/booking/' || j.public_token::text) from public.jobs j where j.id = v_due.job_id),
        'deposit_due', (select public.format_money(public.comms_deposit_due_cents(v_due.job_id), s.currency)
                          from public.shops s where s.id = v_due.shop_id))
      else public.comms_invoice_vars(v_due.invoice_id, v_now) end;

    v_ids := '{}';
    for v_tpl in
      select t.* from public.message_templates t
       where t.shop_id = v_due.shop_id and t.key = v_due.key and t.enabled
       order by t.channel
    loop
      v_msg := public.enqueue_message_core(v_due.shop_id, v_due.customer_id, v_due.key, v_tpl.channel,
                                           v_tpl.subject, v_tpl.body, v_due.job_id, v_vars, v_now, null, null,
                                           v_due.quote_id, v_due.invoice_id);
      if v_msg is not null then
        v_ids := v_ids || v_msg;
      end if;
    end loop;
    if cardinality(v_ids) > 0 then
      update public.document_followup_log l set outcome = 'queued', message_ids = v_ids where l.id = v_log_id;
      v_total := v_total + cardinality(v_ids);
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;

-- claim_queued_messages (0089): a lapsed shop's campaign messages stay queued.
create or replace function public.claim_queued_messages(p_limit integer default 50, p_now timestamptz default now())
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
       -- a lapsed shop's campaign messages wait (0102)
       and (m.campaign_id is null or public.shop_can_write(m.shop_id))
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.billing_guard_new_record(),
  public.billing_invite_seat_guard(),
  public.billing_member_seat_guard()
from public, anon, authenticated;

revoke execute on function
  public.billing_is_end_user(),
  public.billing_inactive_message(),
  public.billing_seats_message(integer)
from public, anon, authenticated;
grant execute on function
  public.billing_is_end_user(),
  public.billing_inactive_message(),
  public.billing_seats_message(integer)
to service_role;
