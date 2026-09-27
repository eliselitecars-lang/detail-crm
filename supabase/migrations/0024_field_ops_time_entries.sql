-- ============================================================================
-- 0024 — Field operations: time_entries, clock_in / clock_out (SPEC §4.6,
-- §3 "Time clock").
--
-- Rules
--   * kind 'shift' = on the clock; kind 'job' = working a specific job
--     (job time may run inside a shift). Per member and kind: at most one
--     open entry (clock_out null) and no overlapping entries (btree_gist
--     exclusion; an open entry extends to infinity). Zero-length entries
--     (immediate clock-out) are allowed and never overlap anything.
--   * Every active member clocks themselves in/out with the RPCs. A job
--     clock requires the job to be in the shop and not cancelled / no-show;
--     technicians must be assigned to it. Clocking out of a shift also
--     closes an open job entry.
--   * p_now (a specific clock time) is honoured only for managers+ — they
--     can edit entries anyway — so technicians cannot back-date punches.
--   * Managers+ read, insert (source 'manual'), edit and delete every entry
--     of their shop. Technicians read their own entries and may only edit the
--     notes of their own OPEN entry; closed entries are read-only to them.
--   * member_id uses the default NO ACTION FK: members with time history
--     are deactivated, not deleted (deleting the whole shop still works).
--   * Deactivating a member (an admin's change, leave_shop, or any other
--     path that sets shop_members.active = false) clocks them out of every
--     open entry at that moment: a former member can no longer call
--     clock_out, and an open punch would otherwise keep adding worked time
--     and labor cost to reports without end (and block their clock_in if
--     they are re-invited later).
-- ============================================================================

create table public.time_entries (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  member_id   uuid not null,
  job_id      uuid,
  kind        public.time_entry_kind not null default 'shift',
  clock_in    timestamptz not null,
  clock_out   timestamptz,
  source      public.time_entry_source not null default 'app',
  notes       text check (notes is null or char_length(notes) <= 2000),
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint time_entries_shop_id_id_key unique (shop_id, id),
  constraint time_entries_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id),
  constraint time_entries_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id),
  constraint time_entries_order check (clock_out is null or clock_out >= clock_in),
  constraint time_entries_shift_has_no_job check (kind = 'job' or job_id is null),
  constraint time_entries_no_overlap exclude using gist (
    member_id with =,
    kind with =,
    tstzrange(clock_in, clock_out, '[)') with &&)
);
-- at most one open entry per member per kind
create unique index time_entries_one_open_key on public.time_entries (member_id, kind) where clock_out is null;
create index time_entries_shop_member_idx on public.time_entries (shop_id, member_id, clock_in);
create index time_entries_shop_job_idx on public.time_entries (shop_id, job_id);
create index time_entries_shop_clock_in_idx on public.time_entries (shop_id, clock_in);
create index time_entries_created_by_idx on public.time_entries (created_by);

comment on column public.time_entries.job_id is 'Required for kind job when the entry is created; set null if the job is later deleted.';

create function public.time_entries_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed constant text[] := array['notes', 'updated_at'];
begin
  if tg_op = 'INSERT' then
    if new.kind = 'job' and new.job_id is null then
      raise exception 'job time entries need a job' using errcode = '23514';
    end if;
    if public.is_client_context() then
      new.source := 'manual';
    end if;
    return new;
  end if;

  if not public.is_client_context() then
    return new;
  end if;
  if new.kind = 'job' and new.job_id is null and old.job_id is not null then
    raise exception 'job time entries need a job' using errcode = '23514';
  end if;
  new.source := old.source;
  if not public.is_shop_manager(old.shop_id)
     and (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'use clock in / clock out; only managers can edit time entries' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger time_entries_05_prevent_shop_change before update on public.time_entries
  for each row execute function public.prevent_shop_change();
create trigger time_entries_10_client_guard before insert or update on public.time_entries
  for each row execute function public.time_entries_client_guard();
create trigger time_entries_20_set_created_by before insert or update on public.time_entries
  for each row execute function public.set_created_by();
create trigger time_entries_90_set_updated_at before update on public.time_entries
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- p_kind defaults to 'shift' without a job and 'job' with one.
create function public.clock_in(
  p_shop_id  uuid,
  p_job_id   uuid default null,
  p_kind     public.time_entry_kind default null,
  p_source   public.time_entry_source default 'app',
  p_now      timestamptz default null,
  p_notes    text default null
) returns public.time_entries
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member  public.shop_members;
  v_kind    public.time_entry_kind := coalesce(p_kind, case when p_job_id is null then 'shift' else 'job' end::public.time_entry_kind);
  v_now     timestamptz := coalesce(p_now, now());
  v_status  public.job_status;
  v_entry   public.time_entries;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if not found then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_now is not null and v_member.role not in ('owner', 'admin', 'manager') then
    raise exception 'only managers can clock in at a specific time' using errcode = '42501';
  end if;
  if coalesce(p_source, 'app') = 'manual' then
    raise exception 'manual entries are added by managers on the timesheet' using errcode = '22023';
  end if;
  if v_kind = 'shift' and p_job_id is not null then
    raise exception 'a shift clock does not take a job' using errcode = '22023';
  end if;
  if v_kind = 'job' then
    if p_job_id is null then
      raise exception 'choose the job to clock in to' using errcode = '22023';
    end if;
    select j.status into v_status from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id;
    if not found then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if not public.can_work_job(p_shop_id, p_job_id) then
      raise exception 'you are not assigned to this job' using errcode = '42501';
    end if;
    if v_status in ('cancelled', 'no_show') then
      raise exception 'cannot clock in to a % job', v_status using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.time_entries te
             where te.member_id = v_member.id and te.kind = v_kind and te.clock_out is null) then
    raise exception 'already clocked in (%); clock out first', v_kind using errcode = '23505';
  end if;

  begin
    insert into public.time_entries (shop_id, member_id, job_id, kind, clock_in, source, notes)
    values (p_shop_id, v_member.id, p_job_id, v_kind, v_now, coalesce(p_source, 'app'),
            nullif(btrim(p_notes), ''))
    returning * into v_entry;
  exception
    when unique_violation then
      raise exception 'already clocked in (%); clock out first', v_kind using errcode = '23505';
    when exclusion_violation then
      raise exception 'this clock-in overlaps an existing % entry', v_kind using errcode = '23P01';
  end;
  return v_entry;
end
$$;

create function public.clock_out(
  p_shop_id  uuid,
  p_kind     public.time_entry_kind default 'shift',
  p_now      timestamptz default null,
  p_notes    text default null
) returns public.time_entries
language plpgsql security definer
set search_path = ''
as $$
declare
  v_member  public.shop_members;
  v_kind    public.time_entry_kind := coalesce(p_kind, 'shift');
  v_now     timestamptz := coalesce(p_now, now());
  v_entry   public.time_entries;
begin
  select * into v_member from public.shop_members m
   where m.shop_id = p_shop_id and m.user_id = auth.uid() and m.active;
  if not found then
    raise exception 'not a member of this shop' using errcode = '42501';
  end if;
  if p_now is not null and v_member.role not in ('owner', 'admin', 'manager') then
    raise exception 'only managers can clock out at a specific time' using errcode = '42501';
  end if;

  select * into v_entry from public.time_entries te
   where te.member_id = v_member.id and te.shop_id = p_shop_id and te.kind = v_kind and te.clock_out is null
   for update;
  if not found then
    raise exception 'not clocked in (%)', v_kind using errcode = 'P0002';
  end if;
  if v_now < v_entry.clock_in then
    raise exception 'clock-out cannot be before clock-in (%)', v_entry.clock_in using errcode = '22023';
  end if;

  -- leaving the shift ends any job clock too
  if v_kind = 'shift' then
    update public.time_entries te
       set clock_out = greatest(v_now, te.clock_in)
     where te.member_id = v_member.id and te.shop_id = p_shop_id and te.kind = 'job' and te.clock_out is null;
  end if;

  update public.time_entries te
     set clock_out = v_now,
         notes = coalesce(nullif(btrim(p_notes), ''), te.notes)
   where te.id = v_entry.id
  returning * into v_entry;
  return v_entry;
end
$$;

-- ---------------------------------------------------------------------------
-- Deactivation closes open entries (see the header). AFTER UPDATE OF active
-- on shop_members, every context. An entry whose clock-in lies ahead of the
-- deactivation (a manager set a later time) closes as a zero-length entry.
-- ---------------------------------------------------------------------------
create function public.shop_members_close_time_entries() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.active and not new.active then
    update public.time_entries te
       set clock_out = greatest(now(), te.clock_in)
     where te.shop_id = new.shop_id and te.member_id = new.id and te.clock_out is null;
  end if;
  return null;
end
$$;

create trigger shop_members_50_close_time_entries
  after update of active on public.shop_members
  for each row execute function public.shop_members_close_time_entries();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.time_entries enable row level security;

create policy time_entries_select on public.time_entries for select to authenticated
  using (public.is_shop_manager(shop_id) or (public.is_own_member(member_id) and public.is_shop_member(shop_id)));
create policy time_entries_insert on public.time_entries for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy time_entries_update_manager on public.time_entries for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy time_entries_update_own_open on public.time_entries for update to authenticated
  using (clock_out is null and public.is_own_member(member_id) and public.is_shop_member(shop_id))
  with check (clock_out is null and public.is_own_member(member_id) and public.is_shop_member(shop_id));
create policy time_entries_delete on public.time_entries for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.time_entries from anon;
revoke truncate, trigger, references on public.time_entries from authenticated;

revoke execute on function
  public.time_entries_client_guard(),
  public.shop_members_close_time_entries()
from public, anon, authenticated;

revoke execute on function
  public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text),
  public.clock_out(uuid, public.time_entry_kind, timestamptz, text)
from public, anon;
grant execute on function
  public.clock_in(uuid, uuid, public.time_entry_kind, public.time_entry_source, timestamptz, text),
  public.clock_out(uuid, public.time_entry_kind, timestamptz, text)
to authenticated, service_role;
