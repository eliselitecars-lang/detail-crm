-- ============================================================================
-- 0123 — Round 10: coupon lookups have no shop-wide lockout; the trial key
-- folds Gmail aliases; a job's own coupon can be re-applied.
--
-- 1. Coupon code lookups: no shop-wide lockout (0122)
--    coupon_code_lookup_allowed (0122) refused every new lookup once the
--    shop had seen 200 different unknown codes from all callers in an
--    hour. About 20 connections (20 IPv4 addresses, or 20 IPv6 /64s — any
--    single /56 or /60 home delegation) sending made-up codes filled that,
--    and from then on every visitor, anonymous or signed in, got 'too many
--    coupon codes were tried' for the shop's published codes and referral
--    links, and could not book with them (create_online_booking takes a
--    code only after the connection looked it up: coupon_not_checked) —
--    renewable every hour. Callers who proved nothing could switch off a
--    shop's promotions for everyone.
--    Now a limit only ever stops the connection that spent it, or its own
--    network — never a stranger:
--      * per connection (client_ip_scope: an IPv4 address or an IPv6 /64):
--        10 different unknown codes in the shop an hour (unchanged);
--      * per IPv6 network (/56, the usual single home or site delegation,
--        counted over every /64 in it): 30 an hour — so many /64s of one
--        household do not add up to a large dictionary. IPv4 addresses
--        are not grouped (neighbours behind one ISP block are strangers);
--      * while the shop is busy (200 or more different unknown codes from
--        all callers in the last hour) a connection's allowance shrinks
--        from 10 to 3 unknown codes an hour. A connection that has tried
--        fewer than 3 still looks codes up — a customer typing the
--        published code, even after a typo or two, is always answered —
--        while a spread-out dictionary gets through a third as fast;
--      * a code the connection already looked up in the last 24 hours is
--        always answered (unchanged);
--      * callers with no known connection (server-side, no client
--        address) keep 0122's rule: the shop-wide 200 an hour.
--    public_validate_coupon and create_online_booking are unchanged (they
--    call coupon_code_lookup_allowed / coupon_code_checked_by); their
--    comments are updated.
--
-- 2. The once-per-person trial key folds Gmail's same-inbox aliases (0120)
--    billing_trial_email_key dropped only a "+tag". Gmail also ignores
--    dots in the local part and treats googlemail.com as gmail.com, and
--    GoTrue normalizes neither, so shine.owner@gmail.com,
--    sh.ineowner@gmail.com and shineowner@googlemail.com (one inbox) each
--    got a new full trial. Now, for gmail.com and googlemail.com, the key
--    also drops the dots of the local part and uses gmail.com (other
--    domains: lower-cased, trimmed, "+tag" dropped, as before).
--      * billing_trial_already_given matches the new key OR the 0120 key
--        of the user's address, so a grant recorded under 0120 for an
--        account since deleted still stops the same address signing up
--        again (the grant keeps only the hash, it cannot be re-keyed);
--      * grants whose account still exists are re-keyed now.
--
-- 3. A job's own coupon can be re-applied (0121's remedy)
--    0121 part 3 skips re-stamping jobs whose deposit page is open and
--    says staff can re-apply the coupon on that job later. Two rules
--    refused exactly those jobs:
--      * new_customers_only (coupon_customer_reason, 0121 body) counted
--        every received payment of the customer as "returning" — including
--        the deposit paid on the very job being edited (the completed-job
--        and referral checks already left that job out). Now payments of
--        p_job_id are left out too, so removing and re-applying WELCOME or
--        a referral code on a booking whose deposit was paid works;
--      * online_only coupons (the usual booking-page codes) could never be
--        set by staff: coupon_redeem_for_job refused them outright. Now
--        jobs_apply_coupon (0109 body) calls coupon_redeem_for_job(shop,
--        coupon, online_booking), and an online-only coupon may be set on
--        a job that IS an online booking (source 'online_booking') — what
--        the rule means. Other jobs still get 'can only be used for online
--        bookings'.
--    A coupon that has since expired, been deactivated or used up is
--    still refused as for any new use.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. coupon_code_lookup_allowed — no shop-wide lockout
-- ---------------------------------------------------------------------------
create or replace function public.coupon_code_lookup_allowed(p_shop_id uuid, p_scope inet, p_hash text) returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c_conn_hourly_misses constant integer := 10;
  c_conn_busy_misses   constant integer := 3;
  c_net_hourly_misses  constant integer := 30;    -- per IPv6 /56
  c_shop_busy_misses   constant integer := 200;
  v_conn integer;
  v_net  integer;
  v_busy boolean;
begin
  -- the shop is busy: 200+ different unknown codes from everyone in an hour
  select count(*) >= c_shop_busy_misses into v_busy
    from (select distinct a.code_hash from public.coupon_code_attempts a
           where a.shop_id = p_shop_id and not a.found and a.created_at > now() - interval '1 hour'
           limit c_shop_busy_misses) x;

  -- no known connection (server-side callers): the shop-wide rule of 0122
  if p_scope is null then
    return not v_busy;
  end if;

  -- a code this connection already looked up: nothing new to learn
  if exists (select 1 from public.coupon_code_attempts a
              where a.shop_id = p_shop_id and a.client_scope = p_scope and a.code_hash = p_hash
                and a.created_at > now() - interval '24 hours') then
    return true;
  end if;

  select count(distinct a.code_hash) into v_conn from public.coupon_code_attempts a
   where a.shop_id = p_shop_id and a.client_scope = p_scope and not a.found
     and a.created_at > now() - interval '1 hour';
  if v_conn >= (case when v_busy then c_conn_busy_misses else c_conn_hourly_misses end) then
    return false;
  end if;

  -- an IPv6 connection: its /56 (one household / site) shares an allowance
  if pg_catalog.family(p_scope) = 6 then
    select count(distinct a.code_hash) into v_net from public.coupon_code_attempts a
     where a.shop_id = p_shop_id and a.client_scope is not null
       and a.client_scope <<= pg_catalog.network(pg_catalog.set_masklen(p_scope, 56))
       and not a.found and a.created_at > now() - interval '1 hour';
    if v_net >= c_net_hourly_misses then
      return false;
    end if;
  end if;
  return true;
end
$$;

comment on function public.coupon_code_lookup_allowed(uuid, inet, text) is
  'Internal (0122; 0123): may a public caller look this coupon code up now? Yes for a code the connection looked up in the last 24 h; else the connection (client_ip_scope) must have tried fewer than 10 different unknown codes in the shop in the last hour (3 while the shop is busy: 200+ from everyone), and an IPv6 connection''s /56 fewer than 30. No shop-wide lockout: a connection that tried fewer than 3 is answered. Callers with no known connection: only while the shop is not busy.';

comment on table public.coupon_code_attempts is
  'Internal (0122; 0123): one row per coupon code a public caller had looked up (public_validate_coupon) — shop, connection (client_ip_scope: an IPv4 address or an IPv6 /64; null when unknown), sha256 of the shop and the lower-cased code, whether the shop has that code, when. Limits (coupon_code_lookup_allowed): 10 different unknown codes per connection per shop an hour (3 while the shop has seen 200+ from everyone), 30 per IPv6 /56; create_online_booking takes a code only after the connection looked it up. Rows older than 2 days are pruned. No client access.';

comment on function public.public_validate_coupon(text, text, uuid[], uuid, timestamptz, uuid, public.location_type, uuid, text) is
  'Booking wizard coupon preview (anon): restrictions (services, minimum, customer rules for the signed-in linked client), optional private booking link, the auto-applied fees of the booking''s location type, a signed-in member''s included services (saved vehicle, booking start). Invalid codes answer valid=false. 0122 / 0123: a code is looked up only within the attempt limits (coupon_code_lookup_allowed: 10 different unknown codes per connection per shop an hour, 3 while the shop is busy with 200+ from everyone, 30 per IPv6 /56; never a shop-wide lockout), else valid=false ''too many coupon codes were tried; please try again later''.';

comment on function public.create_online_booking(text, jsonb, timestamptz) is
  'Public online booking (0042 rules; 0054: link_token, answers -> jobs.custom_data, slot engine v2 with location type and multi-day wrap; 0102: a lapsed shop answers 55000; 0104/0105: PT429 past 10 bookings per connection — an IPv6 /64 — per shop, 10 per signed-in account per shop, 100 anonymous and 100 signed-in bookings per shop, in any rolling 24 hours; 0122: a coupon code is taken only after the connection checked it with public_validate_coupon in the last 24 hours, else 22023 HINT coupon_not_checked — 0123: that check has no shop-wide lockout).';

-- ---------------------------------------------------------------------------
-- 2. billing_trial_email_key — Gmail dots and googlemail.com
-- ---------------------------------------------------------------------------
-- The 0120 key (lower-cased, trimmed, "+tag" dropped): matched as well, for
-- grants recorded before 0123 whose account is gone.
create function public.billing_trial_email_key_0120(p_email text) returns text
language sql immutable
set search_path = ''
as $$
  select case when v is null or v = '' then null
              else encode(sha256(convert_to(regexp_replace(v, '^([^@+]*)\+[^@]*@', '\1@'), 'UTF8')), 'hex') end
    from (select lower(btrim(p_email)) as v) x
$$;

comment on function public.billing_trial_email_key_0120(text) is
  'Internal (0123): the 0120 form of billing_trial_email_key (lower-cased, trimmed, "+tag" dropped; no Gmail folding) — billing_trial_already_given also matches it, for grants recorded before 0123.';

create or replace function public.billing_trial_email_key(p_email text) returns text
language sql immutable
set search_path = ''
as $$
  select case when v is null or v = '' then null
              when v !~ '^[^@]*@[^@]+$' then encode(sha256(convert_to(v, 'UTF8')), 'hex')
              else encode(sha256(convert_to(
                     case when dom in ('gmail.com', 'googlemail.com')
                          then replace(loc, '.', '') || '@gmail.com'
                          else loc || '@' || dom end, 'UTF8')), 'hex') end
    from (select v,
                 split_part(split_part(v, '@', 1), '+', 1) as loc,
                 split_part(v, '@', 2) as dom
            from (select lower(btrim(p_email)) as v) y) x
$$;

comment on function public.billing_trial_email_key(text) is
  'Internal (0120; 0123): sha256 hex of an email lower-cased and trimmed with any "+tag" removed from the local part, and for gmail.com / googlemail.com the local part''s dots removed and the domain gmail.com (one Gmail inbox = one key); null for no email.';

create or replace function public.billing_trial_already_given(p_user_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_user_id is not null
     and exists (select 1 from public.billing_trial_grants g
                  where g.user_id = p_user_id
                     or g.email_key in (select k
                                          from auth.users u,
                                               lateral (values (public.billing_trial_email_key(u.email::text)),
                                                               (public.billing_trial_email_key_0120(u.email::text))) t(k)
                                         where u.id = p_user_id and k is not null))
$$;

comment on function public.billing_trial_already_given(uuid) is
  'Internal (0120; 0123): true when an in-app trial was already given to this user (by user id, or by their email key — the 0123 key or the 0120 one).';

revoke execute on function public.billing_trial_email_key_0120(text) from public, anon, authenticated;
grant execute on function public.billing_trial_email_key_0120(text) to service_role;

-- re-key the grants whose account still exists
update public.billing_trial_grants g
   set email_key = public.billing_trial_email_key(u.email::text)
  from auth.users u
 where u.id = g.user_id
   and g.email_key is distinct from public.billing_trial_email_key(u.email::text);

-- ---------------------------------------------------------------------------
-- 3a. coupon_customer_reason — 0121 body; this job's own payments do not
--     make the customer a returning one
-- ---------------------------------------------------------------------------
create or replace function public.coupon_customer_reason(p_coupon public.coupons, p_customer_id uuid, p_job_id uuid default null)
returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when p_coupon.customer_id is not null and p_coupon.customer_id is distinct from p_customer_id
      then 'this coupon is not valid for this customer'
    when p_customer_id is null then null
    -- 0121: a cancelled / no-show job's redemption is not a use
    when p_coupon.once_per_customer
         and exists (select 1 from public.coupon_redemptions r
                       join public.jobs j on j.id = r.job_id and j.shop_id = r.shop_id
                      where r.shop_id = p_coupon.shop_id and r.coupon_id = p_coupon.id
                        and r.customer_id = p_customer_id and r.job_id is distinct from p_job_id
                        and j.status not in ('cancelled', 'no_show'))
      then 'this coupon can only be used once per customer'
    when p_coupon.new_customers_only
         and (exists (select 1 from public.jobs j
                       where j.shop_id = p_coupon.shop_id and j.customer_id = p_customer_id
                         and j.status = 'completed' and j.id is distinct from p_job_id)
              -- 0123: money paid on this job (its deposit) is not a past visit
              or exists (select 1 from public.payments p
                          where p.shop_id = p_coupon.shop_id and p.customer_id = p_customer_id
                            and p.status in ('succeeded', 'partially_refunded', 'refunded')
                            and (p_job_id is null or p.job_id is null or p.job_id <> p_job_id))
              -- a referee whose referred job was completed (0069) stays a
              -- returning customer even after that job is deleted
              or exists (select 1 from public.referral_credits rc
                          where rc.shop_id = p_coupon.shop_id and rc.referee_customer_id = p_customer_id
                            and (rc.job_id is null or p_job_id is null or rc.job_id <> p_job_id)))
      then 'this coupon is for new customers'
  end
$$;

-- ---------------------------------------------------------------------------
-- 3b. coupon_redeem_for_job(shop, coupon, online_booking) — an online-only
--     coupon may be set on a job that is an online booking
-- ---------------------------------------------------------------------------
create function public.coupon_redeem_for_job(p_shop_id uuid, p_coupon_id uuid, p_online_booking boolean)
returns public.coupons
language plpgsql security definer
set search_path = ''
as $$
declare
  v_c public.coupons;
begin
  if pg_catalog.pg_trigger_depth() = 0 or not public.is_shop_manager(p_shop_id) then
    raise exception 'coupons are applied by setting the job''s coupon' using errcode = '42501';
  end if;
  select * into v_c from public.coupons c where c.id = p_coupon_id and c.shop_id = p_shop_id for update;
  if not found then
    return null;   -- another shop's coupon: the composite FK rejects the write
  end if;
  if not v_c.active then
    raise exception 'coupon % is no longer active', v_c.code using errcode = '23514';
  end if;
  if v_c.starts_at is not null and now() < v_c.starts_at then
    raise exception 'coupon % is not active yet', v_c.code using errcode = '23514';
  end if;
  if v_c.ends_at is not null and now() >= v_c.ends_at then
    raise exception 'coupon % has expired', v_c.code using errcode = '23514';
  end if;
  -- 0123: "online only" = for online bookings, which this job may be
  if v_c.online_only and not coalesce(p_online_booking, false) then
    raise exception 'coupon % can only be used for online bookings', v_c.code using errcode = '23514';
  end if;
  if v_c.max_redemptions is not null and v_c.redemptions >= v_c.max_redemptions then
    raise exception 'coupon % has been fully redeemed', v_c.code using errcode = '23514';
  end if;
  update public.coupons c set redemptions = c.redemptions + 1 where c.id = v_c.id returning * into v_c;
  return v_c;
end
$$;

comment on function public.coupon_redeem_for_job(uuid, uuid, boolean) is
  'Internal (0012; 0123): validates and redeems a coupon a manager+ sets on a job (called from jobs_apply_coupon only; refuses to run outside a trigger). An online-only coupon is accepted only when p_online_booking (the job''s source is online_booking).';

-- the 0012 form: a job that is not an online booking
create or replace function public.coupon_redeem_for_job(p_shop_id uuid, p_coupon_id uuid) returns public.coupons
language sql security definer
set search_path = ''
as $$
  select public.coupon_redeem_for_job(p_shop_id, p_coupon_id, false)
$$;

-- Called from the SECURITY INVOKER jobs_apply_coupon trigger (as 0012)
revoke execute on function public.coupon_redeem_for_job(uuid, uuid, boolean) from public, anon;
grant execute on function public.coupon_redeem_for_job(uuid, uuid, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3c. jobs_apply_coupon — 0109 body; passes whether the job is an online
--     booking
-- ---------------------------------------------------------------------------
create or replace function public.jobs_apply_coupon() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_c       public.coupons;
  v_invoice bigint;
begin
  if not public.is_client_context() then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.coupon_id is not distinct from old.coupon_id then
    if new.coupon_id is not null
       and (new.discount_kind, new.discount_value) is distinct from (old.discount_kind, old.discount_value) then
      raise exception 'this job''s discount comes from its coupon; remove the coupon to set a manual discount'
        using errcode = '23514';
    end if;
    return new;
  end if;
  if tg_op = 'UPDATE' then
    select i.number into v_invoice
      from public.invoices i
     where i.shop_id = old.shop_id and i.status <> 'void'
       and (i.job_id = old.id
            or exists (select 1 from public.invoice_jobs ij
                        where ij.shop_id = old.shop_id and ij.invoice_id = i.id and ij.job_id = old.id
                          and not ij.voided))
     order by i.created_at desc
     limit 1;
    if found then
      raise exception 'this job is billed on invoice #%; its coupon cannot change until that invoice is void', v_invoice
        using errcode = '23514';
    end if;
  end if;
  if tg_op = 'UPDATE' and old.coupon_id is not null then
    -- 0109: a cancelled / no-show job already gave its redemption back
    if old.status not in ('cancelled', 'no_show') then
      perform public.coupon_release_for_job(old.shop_id, old.coupon_id);
    end if;
    if (new.discount_kind, new.discount_value) is not distinct from (old.discount_kind, old.discount_value) then
      new.discount_kind := 'none';
      new.discount_value := 0;
    end if;
  end if;
  if new.coupon_id is not null then
    -- 0123: an online-only coupon fits a job that is an online booking
    v_c := public.coupon_redeem_for_job(new.shop_id, new.coupon_id, new.source = 'online_booking');
    -- 0109: validated, but a cancelled / no-show job holds no redemption
    if v_c.id is not null and new.status in ('cancelled', 'no_show') then
      perform public.coupon_release_for_job(new.shop_id, new.coupon_id);
    end if;
    if v_c.id is not null then
      new.discount_kind := v_c.kind::text::public.discount_kind;
      new.discount_value := v_c.value;
    end if;
  end if;
  return new;
end
$$;
