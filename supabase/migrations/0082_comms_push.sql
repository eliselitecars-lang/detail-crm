-- ============================================================================
-- 0082 — Push notifications for the staff iPhone app (P-2).
--
--   register_push_token / unregister_push_token   the app registers its APNs
--                                                 token for the signed-in user
--   set_notification_prefs                        which kinds a member wants
--                                                 pushed, mute until
--   notification_kind_for_managers (replaced)     job_assigned,
--                                                 job_rescheduled,
--                                                 task_assigned, task_due are
--                                                 readable by every member
--   user_can_read_notification                    can_read_notification for
--                                                 an arbitrary user (push)
--   notify_member                                 one notification for one
--                                                 member (internal)
--   job_assignments_zz_comms_notify               "New job #N" to the
--                                                 assigned member
--   jobs_zz_comms_notify_rescheduled              "Job #N rescheduled" to the
--                                                 assigned members
--   claim_push_batch / release_push /             the `push` edge function's
--   mark_push_token_invalid                       queue (service_role)
--
-- A notification is pushed at most once (pushed_at), to every enabled
-- device of its recipient, while the recipient may still read its kind, has
-- not muted pushes or switched the kind off, and within an hour of its
-- creation (a push worker outage never delivers a burst of stale alerts).
-- Staff-only content: job notifications carry the job number, the local
-- date / time and the service names — never money, phone numbers or notes.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Kinds every member may read (and so be sent): the general notices and the
-- member's own work (jobs assigned / rescheduled, tasks). Every other kind —
-- bookings, money, messages, leads, stock, SMS numbers, webhooks — carries
-- customer or business data SPEC §3 reserves for owners, admins and managers.
-- ---------------------------------------------------------------------------
create or replace function public.notification_kind_for_managers(p_kind public.notification_kind) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_kind is null
      or p_kind not in ('general', 'job_assigned', 'job_rescheduled', 'task_assigned', 'task_due')
$$;

-- can_read_notification for an arbitrary user (service_role: the push
-- worker checks the recipient, not the caller): an ACTIVE member of the shop
-- whose current role may read the kind.
create function public.user_can_read_notification(
  p_user_id  uuid,
  p_shop_id  uuid,
  p_kind     public.notification_kind
) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.shop_members m
     where m.shop_id = p_shop_id and m.user_id = p_user_id and m.active
       and (not public.notification_kind_for_managers(p_kind) or m.role in ('owner', 'admin', 'manager')))
$$;

-- ---------------------------------------------------------------------------
-- notify_member — INTERNAL (service_role and definer code). One notification
-- for one member of p_shop_id, when that member is active and may read the
-- kind; returns its id, else null. p_job_id / p_customer_id are deep links
-- and must belong to the shop (P0002).
-- ---------------------------------------------------------------------------
create function public.notify_member(
  p_shop_id      uuid,
  p_member_id    uuid,
  p_kind         public.notification_kind,
  p_title        text,
  p_body         text default null,
  p_job_id       uuid default null,
  p_customer_id  uuid default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_title text := left(btrim(coalesce(p_title, '')), 200);
  v_body  text := left(nullif(btrim(coalesce(p_body, '')), ''), 2000);
  v_user  uuid;
  v_id    uuid;
begin
  if p_shop_id is null or p_member_id is null or p_kind is null then
    raise exception 'shop, member and kind are required' using errcode = '22023';
  end if;
  if v_title = '' then
    raise exception 'a notification needs a title' using errcode = '22023';
  end if;
  if p_job_id is not null
     and not exists (select 1 from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id) then
    raise exception 'job not found in this shop' using errcode = 'P0002';
  end if;
  if p_customer_id is not null
     and not exists (select 1 from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id) then
    raise exception 'customer not found in this shop' using errcode = 'P0002';
  end if;
  select m.user_id into v_user
    from public.shop_members m
   where m.id = p_member_id and m.shop_id = p_shop_id and m.active
     and (not public.notification_kind_for_managers(p_kind) or m.role in ('owner', 'admin', 'manager'));
  if v_user is null then
    return null;
  end if;
  insert into public.notifications (shop_id, user_id, kind, title, body, job_id, customer_id)
  values (p_shop_id, v_user, p_kind, v_title, v_body, p_job_id, p_customer_id)
  returning id into v_id;
  return v_id;
end
$$;

comment on function public.notify_member(uuid, uuid, public.notification_kind, text, text, uuid, uuid) is
  'Internal: notify one active member (if their role may read the kind). Returns the notification id or null.';

-- "Monday, Jun 2 at 10:00 AM" in the shop's time zone, or null.
create function public.comms_local_when(p_at timestamptz, p_timezone text) returns text
language sql stable
set search_path = ''
as $$
  select case when p_at is null then null
              else to_char(p_at at time zone coalesce(p_timezone, 'UTC'), 'FMDay, FMMon FMDD "at" FMHH12:MI AM') end
$$;

-- Service names of a job (line items), comma separated, capped.
create function public.comms_job_services(p_job_id uuid) returns text
language sql stable
set search_path = ''
as $$
  select left(string_agg(li.name, ', ' order by li.sort, li.created_at, li.id), 300)
    from public.job_line_items li where li.job_id = p_job_id
$$;

-- ---------------------------------------------------------------------------
-- Device tokens
-- ---------------------------------------------------------------------------

-- Registers (or refreshes) the caller's device token. A token that belonged
-- to another user moves to the caller (the device changed hands / accounts)
-- and is re-enabled. At most 25 enabled tokens per user: the least recently
-- seen ones beyond that are disabled.
create function public.register_push_token(
  p_token        text,
  p_apns_env     text,
  p_bundle_id    text,
  p_app_version  text default null
) returns public.device_push_tokens
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_token   text := lower(btrim(coalesce(p_token, '')));
  v_env     text := lower(btrim(coalesce(p_apns_env, '')));
  v_bundle  text := btrim(coalesce(p_bundle_id, ''));
  v_version text := nullif(btrim(coalesce(p_app_version, '')), '');
  v_row     public.device_push_tokens;
begin
  if v_uid is null then
    raise exception 'sign in to register a device' using errcode = '42501';
  end if;
  if v_token !~ '^[0-9a-f]{64,200}$' then
    raise exception 'the device token must be 64-200 hexadecimal characters' using errcode = '22023';
  end if;
  if v_env not in ('sandbox', 'production') then
    raise exception 'apns_env must be sandbox or production' using errcode = '22023';
  end if;
  if char_length(v_bundle) not between 1 and 200 then
    raise exception 'bundle_id is required (max 200 characters)' using errcode = '22023';
  end if;
  if char_length(v_version) > 40 then
    raise exception 'app_version is too long (max 40 characters)' using errcode = '22023';
  end if;

  insert into public.device_push_tokens as d (user_id, token, apns_env, bundle_id, app_version)
  values (v_uid, v_token, v_env, v_bundle, v_version)
  on conflict (token) do update
    set user_id = excluded.user_id,
        apns_env = excluded.apns_env,
        bundle_id = excluded.bundle_id,
        app_version = excluded.app_version,
        last_seen_at = now(),
        disabled_at = null,
        disabled_reason = null
  returning * into v_row;

  update public.device_push_tokens d
     set disabled_at = now(), disabled_reason = 'too many devices'
   where d.id in (select x.id from public.device_push_tokens x
                   where x.user_id = v_uid and x.disabled_at is null
                   order by x.last_seen_at desc, x.created_at desc, x.id
                   offset 25);
  return v_row;
end
$$;

-- Removes one of the caller's tokens (sign-out). True when it existed.
create function public.unregister_push_token(p_token text) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if auth.uid() is null then
    raise exception 'sign in to unregister a device' using errcode = '42501';
  end if;
  delete from public.device_push_tokens d
   where d.token = lower(btrim(coalesce(p_token, ''))) and d.user_id = auth.uid();
  get diagnostics v_n = row_count;
  return v_n > 0;
end
$$;

-- The caller's push preferences in one shop (own active membership only).
-- p_push_kinds null = every kind; duplicates are dropped.
create function public.set_notification_prefs(
  p_shop_id      uuid,
  p_push_kinds   public.notification_kind[],
  p_muted_until  timestamptz default null
) returns public.member_notification_prefs
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member uuid;
  v_kinds  public.notification_kind[];
  v_row    public.member_notification_prefs;
begin
  select m.id into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if v_member is null then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_push_kinds is not null and array_position(p_push_kinds, null) is not null then
    raise exception 'push kinds cannot contain empty values' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}') into v_kinds
    from unnest(coalesce(p_push_kinds, enum_range(null::public.notification_kind))) as k;

  insert into public.member_notification_prefs as p (member_id, shop_id, push_kinds, muted_until)
  values (v_member, p_shop_id, v_kinds, p_muted_until)
  on conflict (member_id) do update
    set push_kinds = excluded.push_kinds, muted_until = excluded.muted_until
  returning * into v_row;
  return v_row;
end
$$;

-- ---------------------------------------------------------------------------
-- Job assigned: the assigned member gets "New job #N" when a signed-in staff
-- member assigned them (not themselves; system writes by service_role /
-- cron announce nothing). Occurrences a recurring series generates in bulk
-- (series_seq > 1, created in the same transaction) are not announced one
-- by one: the first occurrence is; likewise a series edit updating its
-- occurrences in place announces only the first one it changes
-- (detailcrm.series_bulk_edit = the series id, set by update_job_series,
-- sched 0051). Finished / cancelled jobs are skipped. Never blocks the
-- assignment.
-- ---------------------------------------------------------------------------
create function public.job_assignments_comms_notify() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job  public.jobs;
  v_user uuid;
  v_tz   text;
  v_when text;
begin
  begin
    select m.user_id into v_user from public.shop_members m
     where m.id = new.member_id and m.shop_id = new.shop_id and m.active;
    -- only a person's assignment of someone else is announced (not system
    -- writes: service_role / cron, e.g. generated series occurrences)
    if v_user is null or auth.uid() is null or v_user = auth.uid() then
      return null;
    end if;
    select * into v_job from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
    if v_job.id is null or v_job.status in ('completed', 'cancelled', 'no_show')
       or (v_job.series_id is not null and v_job.series_seq > 1 and v_job.created_at = now())
       or (v_job.series_id is not null
           and coalesce(current_setting('detailcrm.series_bulk_edit', true), '') = v_job.series_id::text) then
      return null;
    end if;
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    v_when := coalesce(public.comms_local_when(v_job.scheduled_start, v_tz), 'Not scheduled yet');
    perform public.notify_member(new.shop_id, new.member_id, 'job_assigned',
                                 'New job #' || v_job.number::text,
                                 concat_ws(' - ', v_when, public.comms_job_services(v_job.id)),
                                 v_job.id);
  exception when others then
    raise warning 'job assigned notification failed for job %: % (%)', new.job_id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger job_assignments_zz_comms_notify after insert on public.job_assignments
  for each row execute function public.job_assignments_comms_notify();

-- ---------------------------------------------------------------------------
-- Job rescheduled: every assigned member except the staff member who moved
-- it (system writes by service_role / cron announce nothing; a series edit
-- moving its occurrences in place announces only the first one it changes,
-- see detailcrm.series_bulk_edit above).
-- ---------------------------------------------------------------------------
create function public.jobs_comms_notify_rescheduled() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tz     text;
  v_member record;
begin
  if auth.uid() is null then
    return null;                             -- system writes (service_role / cron) are not announced
  end if;
  if new.series_id is not null
     and coalesce(current_setting('detailcrm.series_bulk_edit', true), '') = new.series_id::text then
    return null;                             -- a series edit: its first changed occurrence is announced
  end if;
  begin
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    for v_member in
      select ja.member_id from public.job_assignments ja
        join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
       where ja.shop_id = new.shop_id and ja.job_id = new.id and m.active
         and m.user_id is distinct from auth.uid()
       order by ja.created_at, ja.id
    loop
      perform public.notify_member(new.shop_id, v_member.member_id, 'job_rescheduled',
                                   'Job #' || new.number::text || ' rescheduled',
                                   concat_ws(' - ',
                                             coalesce('Now ' || public.comms_local_when(new.scheduled_start, v_tz),
                                                      'No longer scheduled'),
                                             public.comms_job_services(new.id)),
                                   new.id);
    end loop;
  exception when others then
    raise warning 'job rescheduled notification failed for job %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger jobs_zz_comms_notify_rescheduled after update of scheduled_start on public.jobs
  for each row when (old.scheduled_start is distinct from new.scheduled_start
                     and old.scheduled_start is not null
                     and new.status in ('scheduled', 'confirmed'))
  execute function public.jobs_comms_notify_rescheduled();

-- ---------------------------------------------------------------------------
-- Push queue (service_role; the `push` edge function)
-- ---------------------------------------------------------------------------

-- Locks up to p_limit notifications not yet pushed (FOR UPDATE SKIP LOCKED:
-- concurrent workers never get the same row) and marks every one of them
-- pushed_at = p_now. Returned (and counted in push_attempts) are only those
-- to deliver now; the others are settled without a push:
--   * created more than an hour before p_now (stale);
--   * the recipient may no longer read the kind (left the shop, demoted);
--   * the recipient muted pushes (muted_until > p_now) or switched the kind
--     off (member_notification_prefs.push_kinds);
--   * the recipient has no enabled device token.
-- tokens = [{token, apns_env}] of the recipient's enabled devices; badge =
-- the recipient's unread notifications (every shop, kinds they may read).
create function public.claim_push_batch(p_limit integer default 100, p_now timestamptz default now())
returns table (
  notification_id  uuid,
  shop_id          uuid,
  user_id          uuid,
  kind             public.notification_kind,
  title            text,
  body             text,
  job_id           uuid,
  customer_id      uuid,
  badge            integer,
  tokens           jsonb,
  quote_id         uuid,
  invoice_id       uuid
)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_now   timestamptz := coalesce(p_now, now());
begin
  return query
  with cand as (
    select n.id
      from public.notifications n
     where n.pushed_at is null
     order by n.created_at, n.id
     limit v_limit
     for update skip locked
  ), info as (
    select n.id,
           (n.created_at >= v_now - interval '1 hour'
            and public.user_can_read_notification(n.user_id, n.shop_id, n.kind)
            and (p.member_id is null or ((p.muted_until is null or p.muted_until <= v_now)
                                         and n.kind = any (p.push_kinds)))
            and t.tokens is not null) as deliver,
           t.tokens
      from cand c
      join public.notifications n on n.id = c.id
      left join public.shop_members m on m.shop_id = n.shop_id and m.user_id = n.user_id
      left join public.member_notification_prefs p on p.member_id = m.id and p.shop_id = n.shop_id
      left join lateral (
        select jsonb_agg(jsonb_build_object('token', d.token, 'apns_env', d.apns_env)
                         order by d.last_seen_at desc, d.id) as tokens
          from public.device_push_tokens d
         where d.user_id = n.user_id and d.disabled_at is null) t on true
  ), upd as (
    update public.notifications n
       set pushed_at = v_now,
           push_attempts = case when i.deliver then least(n.push_attempts + 1, 10) else n.push_attempts end
      from info i
     where n.id = i.id
    returning n.id, n.shop_id, n.user_id, n.kind, n.title, n.body, n.job_id, n.customer_id, n.quote_id,
              n.invoice_id, n.created_at, i.deliver, i.tokens
  )
  select u.id, u.shop_id, u.user_id, u.kind, u.title, u.body, u.job_id, u.customer_id,
         (select count(*)::integer from public.notifications x
           where x.user_id = u.user_id and x.read_at is null
             and public.user_can_read_notification(x.user_id, x.shop_id, x.kind)),
         u.tokens, u.quote_id, u.invoice_id
    from upd u
   where u.deliver
   order by u.created_at, u.id;
end
$$;

-- A transient APNs failure: put the notification back in the queue unless it
-- was already claimed 3 times. True when re-queued.
create function public.release_push(p_notification_id uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.notifications n
     set pushed_at = null
   where n.id = p_notification_id and n.pushed_at is not null and n.push_attempts < 3;
  get diagnostics v_n = row_count;
  return v_n > 0;
end
$$;

-- APNs answered that the token is no longer valid (410 / BadDeviceToken):
-- the device is not pushed again until the app registers it anew.
create function public.mark_push_token_invalid(p_token text, p_reason text) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.device_push_tokens d
     set disabled_at = coalesce(d.disabled_at, now()),
         disabled_reason = coalesce(left(nullif(btrim(coalesce(p_reason, '')), ''), 200), 'invalid token')
   where d.token = lower(btrim(coalesce(p_token, '')));
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.job_assignments_comms_notify(),
  public.jobs_comms_notify_rescheduled()
from public, anon, authenticated;

revoke execute on function
  public.user_can_read_notification(uuid, uuid, public.notification_kind),
  public.notify_member(uuid, uuid, public.notification_kind, text, text, uuid, uuid),
  public.comms_local_when(timestamptz, text),
  public.comms_job_services(uuid),
  public.claim_push_batch(integer, timestamptz),
  public.release_push(uuid),
  public.mark_push_token_invalid(text, text)
from public, anon, authenticated;
grant execute on function
  public.user_can_read_notification(uuid, uuid, public.notification_kind),
  public.notify_member(uuid, uuid, public.notification_kind, text, text, uuid, uuid),
  public.comms_local_when(timestamptz, text),
  public.comms_job_services(uuid),
  public.claim_push_batch(integer, timestamptz),
  public.release_push(uuid),
  public.mark_push_token_invalid(text, text)
to service_role;

revoke execute on function
  public.register_push_token(text, text, text, text),
  public.unregister_push_token(text),
  public.set_notification_prefs(uuid, public.notification_kind[], timestamptz)
from public, anon;
grant execute on function
  public.register_push_token(text, text, text, text),
  public.unregister_push_token(text),
  public.set_notification_prefs(uuid, public.notification_kind[], timestamptz)
to authenticated, service_role;

-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.claim_push_batch(integer, timestamptz) is
  'Push worker queue (service_role). @nullable: body, job_id, customer_id, quote_id, invoice_id';
