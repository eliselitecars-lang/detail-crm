-- ============================================================================
-- 0104 — Public online booking: the lead-form abuse fixes (0088) for
-- create_online_booking. (Numbered after 0102 because it replaces 0102's
-- create_online_booking wrapper; nothing here is about billing.)
--
-- The booking page is anonymous (slug only) and proves neither the email
-- nor the phone typed into it. Before this migration it was bounded only by
-- 5 bookings per email / phone / customer per day (0042), so a script
-- rotating contacts could, from one connection:
--   * make the shop text and email any number / address it chose with its
--     own text in the greeting ('Hi {{customer_first_name}}, ...',
--     'Vehicle: {{vehicle}}'): an SMS-pumping and phishing relay on the
--     shop's own sender, and
--   * fill every bookable slot out to max_days_ahead with requested jobs.
--
-- Abuse limits (PT429, PostgREST answers HTTP 429; wall clock, rolling 24 h,
-- checked under create_online_booking's per-shop advisory lock, so
-- concurrent bookings cannot both take the last allowance), on top of the
-- 5 per contact:
--   * 10 online bookings per client IP (form_signer_ip) per shop;
--   * 100 online bookings per shop (every caller), so a caller rotating
--     addresses still cannot fill the calendar in one go.
-- Accepted bookings are counted in online_booking_log (internal: no client
-- access; rows older than 2 days are dropped as new ones arrive). A booking
-- that fails (slot taken, validation, ...) rolls back and is not counted.
--
-- The booking's own messages (integration_online_booking_created:
-- booking_request_received, or booking_confirmed for auto-confirm shops)
-- can no longer be a relay:
--   * an online booking whose caller is not the signed-in client linked to
--     the booked customer (every anonymous booking) renders them without
--     anything the visitor typed: customer_first_name is "there",
--     customer_name and vehicle are empty (the "Vehicle:" line is left out);
--   * they are texted only to a phone the shop verified — never to a
--     customer's phone_unverified phone (a booking that did not prove the
--     email created the record with it, 0042) — and emailed as before
--     (transactional: the booker's own confirmation and /booking link).
-- Later messages are unchanged: staff confirming a request (the status
-- trigger), reminders and receipts belong to a booking the shop has seen.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- online_booking_log — one row per accepted online booking (for the limits).
-- ---------------------------------------------------------------------------
create table public.online_booking_log (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  client_ip   inet,
  created_at  timestamptz not null default now(),
  constraint online_booking_log_shop_id_id_key unique (shop_id, id)
);
create index online_booking_log_shop_created_idx on public.online_booking_log (shop_id, created_at);
create index online_booking_log_shop_ip_idx on public.online_booking_log (shop_id, client_ip, created_at)
  where client_ip is not null;

comment on table public.online_booking_log is
  'Internal (0104): one row per accepted online booking — its shop, the client IP (form_signer_ip; null when unknown) and when. Only create_online_booking reads and writes it (abuse limits: 10 per IP per shop, 100 per shop, rolling 24 h). No client access.';
comment on column public.online_booking_log.client_ip is
  'Client IP of the booking request (form_signer_ip), or null when the request carried none (service role).';

alter table public.online_booking_log enable row level security;
revoke all on table public.online_booking_log from public, anon, authenticated;
grant select, insert, delete on table public.online_booking_log to service_role;

-- ---------------------------------------------------------------------------
-- create_online_booking (0102's wrapper) + the IP and shop limits. The
-- booking itself is unchanged (create_online_booking_core, 0054 / 0102).
-- ---------------------------------------------------------------------------
create or replace function public.create_online_booking(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  c_ip_daily_limit   constant integer := 10;
  c_shop_daily_limit constant integer := 100;
  v_shop    uuid;
  v_ip      inet := public.form_signer_ip();
  v_recent  integer;
  v_result  jsonb;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'online booking is not enabled for this shop' using errcode = '55000';
  end if;
  if v_shop is null then
    return public.create_online_booking_core(p_slug, p_payload, p_now);   -- answers PT404
  end if;

  -- the same lock create_online_booking_core takes (re-entrant): the counts
  -- below and this booking's row are serialised with every other booking
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.create_online_booking:' || v_shop::text, 0));

  -- abuse limits (wall clock, independent of p_now)
  if v_ip is not null then
    select count(*) into v_recent from public.online_booking_log l
     where l.shop_id = v_shop and l.client_ip = v_ip and l.created_at > now() - interval '24 hours';
    if v_recent >= c_ip_daily_limit then
      raise exception 'too many online bookings from this connection today; please call the shop'
        using errcode = 'PT429';
    end if;
  end if;
  select count(*) into v_recent from public.online_booking_log l
   where l.shop_id = v_shop and l.created_at > now() - interval '24 hours';
  if v_recent >= c_shop_daily_limit then
    raise exception 'this shop is receiving too many online bookings right now; please try again later or call the shop'
      using errcode = 'PT429';
  end if;

  v_result := public.create_online_booking_core(p_slug, p_payload, p_now);

  delete from public.online_booking_log l
   where l.shop_id = v_shop and l.created_at < now() - interval '2 days';
  insert into public.online_booking_log (shop_id, client_ip) values (v_shop, v_ip);
  return v_result;
end
$$;

comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap; 0102: a lapsed shop answers 55000; 0104: at most 10 bookings per client IP and 100 per shop in any rolling 24 hours, PT429).';
revoke execute on function public.create_online_booking(text, jsonb, timestamptz) from public;
grant execute on function public.create_online_booking(text, jsonb, timestamptz) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- integration_online_booking_created (0041) — same signature and events;
-- the customer messages carry nothing an unproven booker typed and are
-- texted only to a verified phone (see the header).
-- ---------------------------------------------------------------------------
create or replace function public.integration_online_booking_created(p_job_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job     public.jobs;
  v_cust    public.customers;
  v_vars    jsonb;
  v_extra   jsonb;
  v_key     public.message_template_key;
  v_ch      public.message_channel;
  v_uid     uuid := auth.uid();
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    return;
  end if;
  begin
    if not public.integration_claim_event(v_job.shop_id, 'booking_created', p_job_id => v_job.id) then
      return;
    end if;
    select * into v_cust from public.customers c where c.id = v_job.customer_id and c.shop_id = v_job.shop_id;
    v_vars := public.comms_job_vars(v_job.id);
    perform public.notify_shop_staff(
      v_job.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'new_booking',
      case when v_job.status = 'requested' then 'New booking request from ' else 'New booking from ' end
        || public.integration_customer_label(v_job.shop_id, v_job.customer_id),
      concat_ws(' · ', v_vars ->> 'services',
                nullif(concat_ws(' at ', v_vars ->> 'job_date', v_vars ->> 'job_time'), '')),
      v_job.id, null, p_customer_id => v_job.customer_id);

    if v_job.status = 'requested' then
      v_key := 'booking_request_received';
    elsif public.integration_claim_event(v_job.shop_id, 'booking_confirmed', p_job_id => v_job.id) then
      v_key := 'booking_confirmed';
    else
      return;
    end if;
    -- an online booking not made by the signed-in client linked to the
    -- customer: nothing the visitor typed goes into the messages
    if v_job.source = 'online_booking'
       and not coalesce(v_uid is not null and v_cust.portal_user_id = v_uid, false) then
      v_extra := jsonb_build_object('customer_first_name', 'there', 'customer_name', null, 'vehicle', null);
    end if;
    foreach v_ch in array enum_range(null::public.message_channel) loop
      -- texted only to a phone the shop verified
      continue when v_ch = 'sms' and coalesce(v_cust.phone_unverified, true);
      continue when exists (
        select 1 from public.messages m
         where m.shop_id = v_job.shop_id and m.job_id = v_job.id and m.direction = 'outbound'
           and m.template_key = v_key and m.channel = v_ch and m.status not in ('failed', 'cancelled'));
      perform public.enqueue_customer_template(v_job.shop_id, v_job.customer_id, v_key, v_ch, v_job.id, v_extra,
                                               null, null);
    end loop;
  exception when others then
    raise warning 'online booking side effects failed for job %: % (%)', v_job.id, sqlerrm, sqlstate;
  end;
end
$$;

comment on function public.integration_online_booking_created(uuid) is
  'Internal (0041; 0104): a new online booking / self-scheduled quote -> staff notification + booking_request_received (requested) or booking_confirmed to the customer. An online booking not made by the signed-in client linked to the customer renders them without customer_first_name / customer_name / vehicle; never texted to a phone_unverified phone.';
revoke execute on function public.integration_online_booking_created(uuid) from public, anon, authenticated;
grant execute on function public.integration_online_booking_created(uuid) to service_role;
