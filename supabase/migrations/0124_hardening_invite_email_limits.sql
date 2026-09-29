-- ============================================================================
-- 0124 — Round 10: staff invite emails are limited in the database, per
-- shop AND per person, and a lapsed shop sends none.
--
-- Every invite email leaves from the platform's own sending domain with the
-- shop's name as the sender name (the `invites` edge function, outside the
-- messaging queue). Round 9 capped a shop at 20 new invites a day, but only
-- inside the function's send_invite:
--   * invite_member (0002) is granted to authenticated: an owner/admin could
--     create any number of invites straight through PostgREST (the iPhone
--     app's fallback does), then have the function email each one with
--     resend_invite, whose fresh-invite branch never counted anything;
--   * the cap was per shop, create_shop has no per-person limit (0120), and
--     a lapsed shop could still invite (shop_invites had only the seat
--     trigger; a shop without a plan has no seat limit).
--
-- Now:
-- 1. shop_invites_01_billing_guard (BEFORE INSERT, 0102's
--    billing_guard_new_record): a lapsed shop's staff cannot create invites
--    (PT402, the neutral inactive-subscription sentence). Accepting an
--    invite that was already sent still works (it inserts no invite).
-- 2. shop_invites_05_rate_limit (BEFORE INSERT, API requests only, so
--    invite_member through PostgREST is covered): at most 20 new invites per
--    shop and 20 per inviting person (invited_by = auth.uid(), across all
--    their shops) in any 24 hours; every row counts (revoked, accepted and
--    expired ones too). Past that: PT429 (HTTP 429), HINT 'invite_limit',
--    DETAIL the whole seconds until one of the counted invites leaves the
--    window. Serialised per shop and per person (advisory locks).
-- 3. shop_invite_emails (new, internal: service role only) records each
--    invite email the `invites` function sends, keyed by the function's
--    Resend idempotency key (one per invite per 5 minutes), with the shop
--    and the person who asked. No foreign keys: a row outlives its shop and
--    account, so deleting and re-creating a shop resets nothing. Rows older
--    than 2 days are pruned as new ones are written.
-- 4. invite_email_permit(shop, user, key) (internal, service role): may one
--    more invite email go out? Refuses {allowed: false, reason:
--    'subscription_inactive'} for a lapsed shop, {allowed: false, reason:
--    'invite_limit', scope 'shop' | 'user', limit, retry_after_seconds}
--    past 30 invite emails per shop or 30 per person in any 24 hours; else
--    records the email (when a key is given; a key already recorded is
--    allowed again without counting: Resend sends it once) and answers
--    {allowed: true, custom_wording}. custom_wording is false while the shop
--    is on a free trial: then the email uses the platform's default
--    invitation wording, never the shop's own subject and body (a throwaway
--    trial shop cannot send its own text from the platform's address).
--    Billing off: never lapsed, custom wording allowed; the per-shop and
--    per-person limits still apply.
-- service_role and operator SQL are not limited by (1) and (2).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lapsed shops create no invites
-- ---------------------------------------------------------------------------
create trigger shop_invites_01_billing_guard before insert on public.shop_invites
  for each row execute function public.billing_guard_new_record();

-- ---------------------------------------------------------------------------
-- 2. New invites per shop and per person
-- ---------------------------------------------------------------------------
-- Whole seconds (at least 60) until the oldest of the newest p_limit
-- timestamps leaves the 24-hour window, i.e. until one more fits.
create function public.invite_limit_retry_seconds(p_times timestamptz[], p_limit integer)
returns integer
language sql stable
set search_path = ''
as $$
  select greatest(60, ceil(extract(epoch from (
           (select min(t) from (select t from unnest(p_times) t order by t desc limit p_limit) newest)
           + interval '24 hours' - now())))::integer)
$$;

comment on function public.invite_limit_retry_seconds(timestamptz[], integer) is
  'Internal (0124): seconds (>= 60) until one of the newest p_limit times leaves the 24-hour window.';

create function public.shop_invites_rate_limit() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  c_limit constant integer := 20;
  v_since timestamptz := now() - interval '24 hours';
  v_user  uuid := auth.uid();
  v_times timestamptz[];
begin
  if not public.is_api_request() then
    return new;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.shop_invites_rate_limit:shop:' || new.shop_id::text, 0));
  select array_agg(i.created_at) into v_times
    from public.shop_invites i
   where i.shop_id = new.shop_id and i.created_at > v_since;
  if coalesce(array_length(v_times, 1), 0) >= c_limit then
    raise exception 'This shop has sent % invitations in the last 24 hours. Try again later.', c_limit
      using errcode = 'PT429', hint = 'invite_limit',
            detail = public.invite_limit_retry_seconds(v_times, c_limit)::text;
  end if;
  if v_user is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('public.shop_invites_rate_limit:user:' || v_user::text, 0));
    select array_agg(i.created_at) into v_times
      from public.shop_invites i
     where i.invited_by = v_user and i.created_at > v_since;
    if coalesce(array_length(v_times, 1), 0) >= c_limit then
      raise exception 'You have sent % invitations in the last 24 hours. Try again later.', c_limit
        using errcode = 'PT429', hint = 'invite_limit',
              detail = public.invite_limit_retry_seconds(v_times, c_limit)::text;
    end if;
  end if;
  return new;
end
$$;

comment on function public.shop_invites_rate_limit() is
  'Trigger (0124): an API request creates at most 20 invites per shop and 20 per inviting person (all their shops) in any 24 hours; else PT429 HINT invite_limit, DETAIL retry seconds.';

create trigger shop_invites_05_rate_limit before insert on public.shop_invites
  for each row execute function public.shop_invites_rate_limit();

create index shop_invites_shop_created_idx on public.shop_invites (shop_id, created_at);
create index shop_invites_invited_by_created_idx on public.shop_invites (invited_by, created_at)
  where invited_by is not null;

-- ---------------------------------------------------------------------------
-- 3. shop_invite_emails
-- ---------------------------------------------------------------------------
create table public.shop_invite_emails (
  email_key   text primary key check (char_length(email_key) between 1 and 200),
  shop_id     uuid not null,
  sent_by     uuid,
  created_at  timestamptz not null default now()
);
create index shop_invite_emails_shop_created_idx on public.shop_invite_emails (shop_id, created_at);
create index shop_invite_emails_sent_by_created_idx on public.shop_invite_emails (sent_by, created_at)
  where sent_by is not null;

comment on table public.shop_invite_emails is
  'Internal (0124): one row per staff invite email the invites function sent (its Resend idempotency key), with the shop and the person who asked; no foreign keys, so rows outlive shops and accounts. Counted by invite_email_permit; pruned after 2 days. Service role only.';

alter table public.shop_invite_emails enable row level security;
revoke all on table public.shop_invite_emails from public, anon, authenticated;
grant select, delete on table public.shop_invite_emails to service_role;

-- ---------------------------------------------------------------------------
-- 4. invite_email_permit
-- ---------------------------------------------------------------------------
create function public.invite_email_permit(p_shop_id uuid, p_user_id uuid, p_email_key text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_limit constant integer := 30;
  v_since timestamptz := now() - interval '24 hours';
  v_state text;
  v_custom boolean;
  v_times timestamptz[];
begin
  if p_shop_id is null or not exists (select 1 from public.shops s where s.id = p_shop_id) then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  if p_email_key is not null and char_length(p_email_key) not between 1 and 200 then
    raise exception 'invalid email key' using errcode = '22023';
  end if;
  select s.state into v_state from public.shop_billing_standing(p_shop_id) s;
  if public.billing_enabled() and v_state = 'lapsed' then
    return jsonb_build_object('allowed', false, 'reason', 'subscription_inactive',
                              'message', public.billing_inactive_message());
  end if;
  v_custom := v_state is distinct from 'trialing';

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('public.invite_email_permit:shop:' || p_shop_id::text, 0));
  if p_user_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('public.invite_email_permit:user:' || p_user_id::text, 0));
  end if;

  -- the same email again (double submit, retry): Resend sends it once
  if p_email_key is not null
     and exists (select 1 from public.shop_invite_emails e where e.email_key = p_email_key) then
    return jsonb_build_object('allowed', true, 'custom_wording', v_custom);
  end if;

  delete from public.shop_invite_emails e
   where e.created_at < now() - interval '2 days'
     and (e.shop_id = p_shop_id or e.sent_by = p_user_id);

  select array_agg(e.created_at) into v_times
    from public.shop_invite_emails e
   where e.shop_id = p_shop_id and e.created_at > v_since;
  if coalesce(array_length(v_times, 1), 0) >= c_limit then
    return jsonb_build_object('allowed', false, 'reason', 'invite_limit', 'scope', 'shop', 'limit', c_limit,
                              'retry_after_seconds', public.invite_limit_retry_seconds(v_times, c_limit));
  end if;
  if p_user_id is not null then
    select array_agg(e.created_at) into v_times
      from public.shop_invite_emails e
     where e.sent_by = p_user_id and e.created_at > v_since;
    if coalesce(array_length(v_times, 1), 0) >= c_limit then
      return jsonb_build_object('allowed', false, 'reason', 'invite_limit', 'scope', 'user', 'limit', c_limit,
                                'retry_after_seconds', public.invite_limit_retry_seconds(v_times, c_limit));
    end if;
  end if;

  if p_email_key is not null then
    insert into public.shop_invite_emails (shop_id, sent_by, email_key)
    values (p_shop_id, p_user_id, p_email_key);
  end if;
  return jsonb_build_object('allowed', true, 'custom_wording', v_custom);
end
$$;

comment on function public.invite_email_permit(uuid, uuid, text) is
  'Internal (0124, invites function): may one more staff invite email go out for the shop and person? {allowed:false, reason:subscription_inactive, message} for a lapsed shop; {allowed:false, reason:invite_limit, scope:shop|user, limit, retry_after_seconds} past 30 per shop or 30 per person in any 24 hours; else records p_email_key (a key already recorded is not counted again; null only checks) and answers {allowed:true, custom_wording} (false during a free trial: default wording only).';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.invite_limit_retry_seconds(timestamptz[], integer),
  public.shop_invites_rate_limit(),
  public.invite_email_permit(uuid, uuid, text)
from public, anon, authenticated;
grant execute on function
  public.invite_limit_retry_seconds(timestamptz[], integer),
  public.invite_email_permit(uuid, uuid, text)
to service_role;
