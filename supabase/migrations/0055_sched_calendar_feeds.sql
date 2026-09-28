-- ============================================================================
-- 0055 — Per-member iCal (.ics) calendar feed (P-19).
--
-- A member subscribes their phone / desktop calendar to
-- /functions/v1/calendar-feed?token=<token>. The token (calendar_feed_tokens,
-- 0050) is the member's own credential: one live token per member; creating
-- a new one revokes the previous (rotation); revoking it stops the feed.
-- The calendar-feed edge function (service_role) calls calendar_feed_events
-- and renders the ICS.
--
-- What a feed shows (window: 7 days back .. 90 days ahead of now):
--   * technicians (and managers without include_all): the jobs they are
--     assigned to, their own calendar events (time off, meetings ...) and the
--     shop-wide events that name no customer (closures, meetings ...; an
--     event whose customer was deleted still counts as naming one:
--     blocked_times.names_customer, 0050);
--   * include_all (owner/admin/manager only, checked when the token is made
--     AND when it is read): every job of the shop, every shop-wide event, and
--     their own events.
-- Cancelled / no-show and unscheduled jobs are left out (a subscribed
-- calendar drops them on its next refresh). Never: phone numbers, email
-- addresses, prices, totals, internal notes or job notes. Job summary:
-- 'Job #1234 - <services> - <first name> <last initial>.'; location: the
-- service address (mobile jobs) or the shop's address; description: the
-- vehicle, the services and the staff app link (when app_base_url is set).
-- A token of an inactive member (or of a shop the member left) reads as
-- null, and deactivation revokes the member's live token
-- (shop_members_55_revoke_calendar_feed, every path that sets
-- shop_members.active = false: an admin's removal, leave_shop, ...), so
-- re-adding the same person (accept_invite or an admin reactivates the
-- SAME membership row) never revives a URL handed out before the removal;
-- they subscribe again with a new token.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- create_calendar_feed(shop, include_all) — any active member for
-- themselves; include_all needs owner/admin/manager (42501). Revokes the
-- member's previous live token. Returns {token, path}.
-- ---------------------------------------------------------------------------
create function public.create_calendar_feed(p_shop_id uuid, p_include_all boolean default false)
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_member  public.shop_members;
  v_token   uuid;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if not found then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if coalesce(p_include_all, false) and v_member.role not in ('owner', 'admin', 'manager') then
    raise exception 'only owners, admins and managers can subscribe to every job of the shop' using errcode = '42501';
  end if;
  -- one live token per member, also under concurrent calls
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('calendar_feed:' || v_member.id::text, 0));
  -- re-checked under the lock: no new token after a removal that committed
  -- while this call waited (shop_members_55_revoke_calendar_feed takes the
  -- same lock, so a later removal revokes the token made here)
  if not exists (select 1 from public.shop_members m where m.id = v_member.id and m.active) then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  update public.calendar_feed_tokens t
     set revoked_at = now()
   where t.member_id = v_member.id and t.shop_id = p_shop_id and t.revoked_at is null;
  insert into public.calendar_feed_tokens (shop_id, member_id, include_all)
  values (p_shop_id, v_member.id, coalesce(p_include_all, false))
  returning token into v_token;
  return jsonb_build_object('token', v_token, 'path', '/functions/v1/calendar-feed?token=' || v_token::text);
end
$$;

-- ---------------------------------------------------------------------------
-- revoke_calendar_feed(shop) — revokes the caller's live token; true when
-- there was one. Non-members: 42501.
-- ---------------------------------------------------------------------------
create function public.revoke_calendar_feed(p_shop_id uuid) returns boolean
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_member  uuid;
  v_n       integer;
begin
  select m.id into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if v_member is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  update public.calendar_feed_tokens t
     set revoked_at = now()
   where t.member_id = v_member and t.shop_id = p_shop_id and t.revoked_at is null;
  get diagnostics v_n = row_count;
  return v_n > 0;
end
$$;

-- ---------------------------------------------------------------------------
-- calendar_feed_events(token, p_now) — service_role only (the calendar-feed
-- edge function). null for an unknown / revoked token or an inactive
-- member. Result:
--   {shop: {name, timezone}, member: {display_name},
--    events: [{uid, starts_at, ends_at, summary, location, description,
--              status ('CONFIRMED' | 'TENTATIVE' for requested jobs),
--              updated_at}]}  ordered by starts_at
-- uid is stable per job ('job-<id>') and per event occurrence
-- ('event-<block id>-<UTC start yyyymmddThhmmssZ>'); the edge function adds
-- its domain. Stamps last_accessed_at at most once per 10 minutes.
-- ---------------------------------------------------------------------------
create function public.calendar_feed_events(p_token uuid, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now     timestamptz := public.effective_now(p_now);
  v_tok     public.calendar_feed_tokens;
  v_member  public.shop_members;
  v_shop    public.shops;
  v_all     boolean;
  v_from    timestamptz;
  v_to      timestamptz;
  v_events  jsonb;
  v_shop_address text;
begin
  select * into v_tok from public.calendar_feed_tokens t where t.token = p_token and t.revoked_at is null;
  if not found then
    return null;
  end if;
  select * into v_member from public.shop_members m
   where m.id = v_tok.member_id and m.shop_id = v_tok.shop_id and m.active;
  if not found then
    return null;
  end if;
  select * into v_shop from public.shops s where s.id = v_tok.shop_id;
  v_all := v_tok.include_all and v_member.role in ('owner', 'admin', 'manager');
  v_from := v_now - interval '7 days';
  v_to := v_now + interval '90 days';
  v_shop_address := nullif(concat_ws(', ', v_shop.address_line1, v_shop.address_line2, v_shop.city,
                                     nullif(concat_ws(' ', v_shop.region, v_shop.postal_code), '')), '');

  with feed_jobs as (
    select j.*
    from public.jobs j
    where j.shop_id = v_shop.id
      and j.scheduled_start is not null
      and j.scheduled_start < v_to
      and j.scheduled_end > v_from
      and j.status not in ('cancelled', 'no_show')
      and (v_all or exists (select 1 from public.job_assignments ja
                             where ja.job_id = j.id and ja.shop_id = j.shop_id and ja.member_id = v_member.id))
  ),
  job_events as (
    select j.scheduled_start as s,
           jsonb_build_object(
             'uid', 'job-' || j.id::text,
             'starts_at', j.scheduled_start,
             'ends_at', j.scheduled_end,
             'summary', concat_ws(' - ',
                                  'Job #' || j.number::text,
                                  nullif(svc.names, ''),
                                  nullif(case when nullif(btrim(c.first_name), '') is not null
                                              then btrim(btrim(c.first_name) || ' '
                                                         || coalesce(upper(left(nullif(btrim(c.last_name), ''), 1)) || '.', ''))
                                              else nullif(btrim(c.company), '') end, '')),
             'location', case when j.location_type = 'mobile'
                              then nullif(concat_ws(', ', j.service_address_line1, j.service_address_line2, j.service_city,
                                                    nullif(concat_ws(' ', j.service_region, j.service_postal_code), '')), '')
                              else v_shop_address end,
             'description', nullif(concat_ws(E'\n',
                                             nullif(btrim(concat_ws(' ', v.year::text, v.make, v.model)), ''),
                                             nullif(svc.names, ''),
                                             public.app_url('/app/jobs/' || j.id::text)), ''),
             'status', case when j.status = 'requested' then 'TENTATIVE' else 'CONFIRMED' end,
             'updated_at', j.updated_at) as ev
    from feed_jobs j
    join public.customers c on c.id = j.customer_id and c.shop_id = j.shop_id
    left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
    cross join lateral (select string_agg(li.name, ', ' order by li.sort, li.created_at, li.id) as names
                          from public.job_line_items li
                         where li.job_id = j.id and li.shop_id = j.shop_id) svc
  ),
  block_events as (
    select o.starts_at as s,
           jsonb_build_object(
             'uid', 'event-' || o.block_id::text || '-'
                    || to_char(o.starts_at at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"'),
             'starts_at', o.starts_at,
             'ends_at', o.ends_at,
             'summary', coalesce(o.title, initcap(replace(o.kind::text, '_', ' '))),
             'location', null,
             'description', null,
             'status', 'CONFIRMED',
             'updated_at', b.updated_at) as ev
    from public.blocked_time_occurrences(v_shop.id, v_from, v_to) o
    join public.blocked_times b on b.id = o.block_id and b.shop_id = v_shop.id
    where o.member_id = v_member.id
       or (o.member_id is null and (v_all or not o.names_customer))
  )
  select coalesce(jsonb_agg(x.ev order by x.s, x.ev ->> 'uid'), '[]'::jsonb) into v_events
    from (select * from job_events union all select * from block_events) x;

  update public.calendar_feed_tokens t
     set last_accessed_at = v_now
   where t.id = v_tok.id
     and (t.last_accessed_at is null or t.last_accessed_at < v_now - interval '10 minutes');

  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'timezone', v_shop.timezone),
    'member', jsonb_build_object('display_name', v_member.display_name),
    'events', v_events);
end
$$;

-- ---------------------------------------------------------------------------
-- Deactivation revokes the member's live feed token (see the header).
-- AFTER UPDATE OF active on shop_members, every context (definer: the
-- tokens are RPC-only). Serialized with create_calendar_feed by the same
-- advisory lock, so a token made concurrently cannot outlive the removal.
-- ---------------------------------------------------------------------------
create function public.shop_members_revoke_calendar_feed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.active and not new.active then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('calendar_feed:' || new.id::text, 0));
    update public.calendar_feed_tokens t
       set revoked_at = now()
     where t.shop_id = new.shop_id and t.member_id = new.id and t.revoked_at is null;
  end if;
  return null;
end
$$;

create trigger shop_members_55_revoke_calendar_feed
  after update of active on public.shop_members
  for each row execute function public.shop_members_revoke_calendar_feed();

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.shop_members_revoke_calendar_feed() from public, anon, authenticated;

revoke execute on function
  public.create_calendar_feed(uuid, boolean),
  public.revoke_calendar_feed(uuid)
from public, anon;
grant execute on function
  public.create_calendar_feed(uuid, boolean),
  public.revoke_calendar_feed(uuid)
to authenticated, service_role;

revoke execute on function public.calendar_feed_events(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.calendar_feed_events(uuid, timestamptz) to service_role;
