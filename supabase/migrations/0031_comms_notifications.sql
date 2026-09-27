-- ============================================================================
-- 0031 — In-app staff notifications (SPEC §4.7).
--
-- A notification belongs to one recipient (a member of the shop). Recipients
-- read their own notifications, mark them read (read_at) and dismiss
-- (delete) them. Nobody inserts directly: notifications come from
-- notify_shop_staff(), which is callable only by service_role and by other
-- SECURITY DEFINER code / triggers (the integration layer wires events such
-- as "new online booking" or "payment received" to it; comms itself creates
-- 'inbound_message' notifications in record_inbound_sms).
-- ============================================================================

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  user_id     uuid not null,
  kind        public.notification_kind not null,
  title       text not null check (char_length(btrim(title)) between 1 and 200),
  body        text check (body is null or char_length(body) <= 2000),
  job_id      uuid,
  read_at     timestamptz,
  created_at  timestamptz not null default now(),
  constraint notifications_shop_id_id_key unique (shop_id, id),
  -- the recipient is (or was) a member of this very shop
  constraint notifications_member_fk foreign key (shop_id, user_id)
    references public.shop_members (shop_id, user_id) on delete cascade,
  constraint notifications_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id)
);
create index notifications_recipient_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id, shop_id) where read_at is null;
create index notifications_shop_user_idx on public.notifications (shop_id, user_id);
create index notifications_shop_job_idx on public.notifications (shop_id, job_id);

create trigger notifications_05_prevent_shop_change before update on public.notifications
  for each row execute function public.prevent_shop_change();

alter table public.notifications enable row level security;

-- Which roles may read a notification kind. Every event kind (bookings,
-- cancellations, quotes, payments, inbound texts, signed forms) carries
-- customer names, money or message text that SPEC §3 reserves for owners,
-- admins and managers; only 'general' notices are for every member, so they
-- must never carry such data: anything about money — payments, refunds,
-- card disputes (stripe-webhook) — is sent as 'payment_received'. Checked
-- against the recipient's CURRENT role, so a manager demoted to technician
-- immediately stops seeing (and receiving over Realtime) the manager-only
-- notifications they were sent earlier, and notify_shop_staff never sends a
-- manager-only kind to a technician.
create function public.notification_kind_for_managers(p_kind public.notification_kind) returns boolean
language sql immutable
set search_path = ''
as $$ select p_kind is distinct from 'general'::public.notification_kind $$;

-- True when the caller is an active member of p_shop_id whose current role
-- may read notifications of p_kind.
create function public.can_read_notification(p_shop_id uuid, p_kind public.notification_kind) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case when public.notification_kind_for_managers(p_kind) then public.is_shop_manager(p_shop_id)
              else public.is_shop_member(p_shop_id) end
$$;

-- Recipient only, only while an active member of the shop, and only while
-- their current role may read the kind.
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = auth.uid() and public.can_read_notification(shop_id, kind));
create policy notifications_update on public.notifications for update to authenticated
  using (user_id = auth.uid() and public.can_read_notification(shop_id, kind))
  with check (user_id = auth.uid() and public.can_read_notification(shop_id, kind));
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = auth.uid() and public.can_read_notification(shop_id, kind));

revoke all on public.notifications from anon;
revoke insert, update, truncate, references, trigger on public.notifications from authenticated;
-- the only client-writable column
grant update (read_at) on public.notifications to authenticated;

-- ---------------------------------------------------------------------------
-- notify_shop_staff — one notification per ACTIVE member of p_shop_id whose
-- role is in p_roles (null/empty = every role) and may read the kind
-- (manager-only kinds never go to technicians), optionally skipping the user
-- who caused the event. Returns the number of notifications created.
-- ---------------------------------------------------------------------------
create function public.notify_shop_staff(
  p_shop_id       uuid,
  p_roles         public.shop_role[],
  p_kind          public.notification_kind,
  p_title         text,
  p_body          text default null,
  p_job_id        uuid default null,
  p_exclude_user  uuid default null
) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_title text := left(btrim(coalesce(p_title, '')), 200);
  v_body  text := left(nullif(btrim(coalesce(p_body, '')), ''), 2000);
  v_count integer;
begin
  if p_shop_id is null or p_kind is null then
    raise exception 'shop and kind are required' using errcode = '22023';
  end if;
  if v_title = '' then
    raise exception 'a notification needs a title' using errcode = '22023';
  end if;
  if p_job_id is not null
     and not exists (select 1 from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id) then
    raise exception 'job not found in this shop' using errcode = 'P0002';
  end if;

  insert into public.notifications (shop_id, user_id, kind, title, body, job_id)
  select m.shop_id, m.user_id, p_kind, v_title, v_body, p_job_id
  from public.shop_members m
  where m.shop_id = p_shop_id
    and m.active
    and (p_roles is null or cardinality(p_roles) = 0 or m.role = any (p_roles))
    and (not public.notification_kind_for_managers(p_kind) or m.role in ('owner', 'admin', 'manager'))
    and (p_exclude_user is null or m.user_id <> p_exclude_user);
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

comment on function public.notify_shop_staff(uuid, public.shop_role[], public.notification_kind, text, text, uuid, uuid) is
  'Internal: notify active staff of a shop (by role). Not callable by API clients; used by service_role and definer code/triggers.';

-- Convenience for the bell menu: mark all of the caller's notifications in a
-- shop that they may read as read. Returns how many changed.
create function public.mark_all_notifications_read(p_shop_id uuid) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if not public.is_shop_member(p_shop_id) then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  update public.notifications n
     set read_at = now()
   where n.shop_id = p_shop_id and n.user_id = auth.uid() and n.read_at is null
     and public.can_read_notification(n.shop_id, n.kind);
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

revoke execute on function
  public.notify_shop_staff(uuid, public.shop_role[], public.notification_kind, text, text, uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.notify_shop_staff(uuid, public.shop_role[], public.notification_kind, text, text, uuid, uuid)
to service_role;

revoke execute on function
  public.notification_kind_for_managers(public.notification_kind),
  public.can_read_notification(uuid, public.notification_kind)
from public, anon;
grant execute on function
  public.notification_kind_for_managers(public.notification_kind),
  public.can_read_notification(uuid, public.notification_kind)
to authenticated, service_role;

revoke execute on function public.mark_all_notifications_read(uuid) from public, anon;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated, service_role;
