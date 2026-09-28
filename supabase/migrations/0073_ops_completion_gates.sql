-- ============================================================================
-- 0073 — Required checklists and photo minimums block completion, with a
-- manager override (P-11).
--
-- Gates (trigger jobs_70_completion_gates, BEFORE UPDATE OF status, every
-- context; it runs after jobs_30_status_machine has accepted the move):
--   * -> completed    every required checklist item is ticked, and the job
--                     has at least max(min_after_photos) "after" photos of
--                     its services (services inside package lines count);
--   * -> in_progress  (a forward move) at least max(min_before_photos)
--                     "before" photos.
-- Photos are job_photos rows of that kind with media_type 'image' (videos
-- do not count). A failed gate raises 23514 with a message naming what is
-- missing. Backward moves (completed -> in_progress, ...) and inserts are
-- never gated. job_status_transitions / jobs_status_machine are unchanged.
--
-- Override: set_job_status(job, status, p_force => true, p_reason) —
-- managers+ only — records the waived blockers in job_gate_overrides and
-- sets detailcrm.force_job_gates = <job id> (transaction-local) for its own
-- update only. set_job_status is also the normal status RPC for every role:
-- it applies the same transition rules as a direct update (managers any
-- edge, technicians the technician_allowed forward edges of jobs they are
-- assigned to).
--
-- Required items: checklist_templates.required is copied to the items it
-- attaches (checklist_attach_template, so apply_checklist_template and the
-- automatic attach inherit it); managers may flag ad-hoc items; technicians
-- can never change the flag.
--
-- Removed services: when a service line is deleted (or its service_id
-- changes), the still-open items attached from templates of that service
-- (or of a service inside that package) are removed from the job unless the
-- service is still on it through another line or package
-- (job_line_items_detach_checklists). Like the photo minimums, which follow
-- the job's current services, a required item never blocks completion for
-- work that is no longer part of the job. Ticked items stay as the record of
-- work done; ad-hoc items and items of templates without a service are never
-- touched. A line rewrite (delete + insert, e.g. a series reprice) re-attaches
-- the template's items through job_line_items_attach_checklists.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- checklist_attach_template (0021) — copies the template's required flag.
-- ---------------------------------------------------------------------------
create or replace function public.checklist_attach_template(p_shop_id uuid, p_job_id uuid, p_template_id uuid)
returns setof public.job_checklist_items
language plpgsql security definer
set search_path = ''
as $$
declare
  v_base integer;
begin
  select coalesce(max(ci.sort), 0) into v_base
    from public.job_checklist_items ci
   where ci.job_id = p_job_id and ci.shop_id = p_shop_id;

  return query
    with ins as (
      insert into public.job_checklist_items as ci (shop_id, job_id, label, sort, template_id, template_item_id, required)
      select p_shop_id, p_job_id, x.item ->> 'label', v_base + x.ord::integer, t.id, x.item ->> 'id', t.required
      from public.checklist_templates t
      cross join lateral jsonb_array_elements(t.items) with ordinality as x(item, ord)
      where t.id = p_template_id and t.shop_id = p_shop_id
      order by x.ord
      on conflict (job_id, template_id, template_item_id) where template_id is not null do nothing
      returning ci.*)
    select * from ins order by ins.sort;
end
$$;

-- ---------------------------------------------------------------------------
-- job_checklist_items_client_guard (0021) — technicians still only tick and
-- untick; the required flag is named explicitly (managers set it).
-- ---------------------------------------------------------------------------
create or replace function public.job_checklist_items_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed constant text[] := array['done_at', 'done_by', 'updated_at'];
begin
  if not public.is_client_context() then
    if new.done_at is null then
      new.done_by := null;
    end if;
    return new;
  end if;

  new.label := btrim(new.label);
  if tg_op = 'INSERT' then
    -- template linkage is maintained by the server only
    new.template_id := null;
    new.template_item_id := null;
    if new.done_at is not null then
      new.done_at := now();
      new.done_by := auth.uid();
    else
      new.done_by := null;
    end if;
    return new;
  end if;

  if new.job_id <> old.job_id then
    raise exception 'checklist items cannot move to another job' using errcode = '42501';
  end if;
  if new.template_id is distinct from old.template_id
     or new.template_item_id is distinct from old.template_item_id then
    raise exception 'checklist template links are maintained by the server' using errcode = '42501';
  end if;
  if new.required is distinct from old.required and not public.is_shop_manager(old.shop_id) then
    raise exception 'only managers can change whether a checklist item is required' using errcode = '42501';
  end if;

  -- done_at is a toggle: the server records when and by whom.
  if new.done_at is null then
    new.done_by := null;
  elsif old.done_at is null then
    new.done_at := now();
    new.done_by := auth.uid();
  else
    new.done_at := old.done_at;
    new.done_by := old.done_by;
  end if;

  if not public.is_shop_manager(old.shop_id)
     and (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'technicians can only tick checklist items on their assigned jobs' using errcode = '42501';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- job_line_items_detach_checklists — AFTER DELETE / UPDATE OF service_id on
-- job_line_items: the counterpart of job_line_items_attach_checklists (0021).
-- Deletes the job's open (unticked) items that came from a template whose
-- service was the old line's service or a service inside that package, when
-- that service is no longer on the job through any line (directly or inside
-- a package line). SECURITY DEFINER: whoever removed the line (a manager, a
-- trusted RPC) may not be able to delete checklist items directly.
-- ---------------------------------------------------------------------------
create function public.job_line_items_detach_checklists() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.service_id is null
     or (tg_op = 'UPDATE' and new.service_id is not distinct from old.service_id) then
    return null;
  end if;
  delete from public.job_checklist_items ci
   using public.checklist_templates t
   where ci.shop_id = old.shop_id and ci.job_id = old.job_id
     and ci.done_at is null
     and t.shop_id = ci.shop_id and t.id = ci.template_id
     and t.service_id is not null
     and (t.service_id = old.service_id
          or t.service_id in (select pi.service_id from public.package_items pi
                              where pi.package_id = old.service_id and pi.shop_id = old.shop_id))
     and not exists (
           select 1
             from public.job_line_items li
            where li.job_id = old.job_id and li.shop_id = old.shop_id
              and (li.service_id = t.service_id
                   or exists (select 1 from public.package_items pi
                               where pi.package_id = li.service_id and pi.shop_id = li.shop_id
                                 and pi.service_id = t.service_id)));
  return null;
end
$$;

create trigger job_line_items_detach_checklists after delete or update of service_id on public.job_line_items
  for each row execute function public.job_line_items_detach_checklists();

-- ---------------------------------------------------------------------------
-- The gate state of a job (internal; no access check):
--   {open_required_items: [{id, label}],
--    before_photos: {required, have}, after_photos: {required, have}}
-- ---------------------------------------------------------------------------
create function public.job_gate_state(p_shop_id uuid, p_job_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  with svc as (
    select li.service_id
      from public.job_line_items li
     where li.job_id = p_job_id and li.shop_id = p_shop_id and li.service_id is not null
    union
    select pi.service_id
      from public.job_line_items li
      join public.package_items pi on pi.package_id = li.service_id and pi.shop_id = li.shop_id
     where li.job_id = p_job_id and li.shop_id = p_shop_id
  ), mins as (
    select coalesce(max(s.min_before_photos), 0)::integer as before_req,
           coalesce(max(s.min_after_photos), 0)::integer as after_req
      from public.services s
     where s.shop_id = p_shop_id and s.id in (select svc.service_id from svc)
  ), photos as (
    select count(*) filter (where p.kind = 'before')::integer as before_have,
           count(*) filter (where p.kind = 'after')::integer as after_have
      from public.job_photos p
     where p.job_id = p_job_id and p.shop_id = p_shop_id and p.media_type = 'image'
  )
  select jsonb_build_object(
    'open_required_items', coalesce((
      select jsonb_agg(jsonb_build_object('id', ci.id, 'label', ci.label) order by ci.sort, ci.created_at, ci.id)
        from public.job_checklist_items ci
       where ci.job_id = p_job_id and ci.shop_id = p_shop_id and ci.required and ci.done_at is null), '[]'::jsonb),
    'before_photos', jsonb_build_object('required', m.before_req, 'have', ph.before_have),
    'after_photos', jsonb_build_object('required', m.after_req, 'have', ph.after_have))
  from mins m cross join photos ph
$$;

-- Which of the gate state blocks a move to p_status (from p_old)? Returns
-- the blocking part of the state (null when nothing blocks).
create function public.job_gate_blockers_for(p_state jsonb, p_old public.job_status, p_status public.job_status)
returns jsonb
language sql immutable
set search_path = ''
as $$
  select case
    when p_status = 'completed' and p_old <> 'completed'
         and (jsonb_array_length(p_state -> 'open_required_items') > 0
              or (p_state #>> '{after_photos,have}')::integer < (p_state #>> '{after_photos,required}')::integer)
      then jsonb_strip_nulls(jsonb_build_object(
             'open_required_items', case when jsonb_array_length(p_state -> 'open_required_items') > 0
                                         then p_state -> 'open_required_items' end,
             'after_photos', case when (p_state #>> '{after_photos,have}')::integer
                                       < (p_state #>> '{after_photos,required}')::integer
                                  then p_state -> 'after_photos' end))
    when p_status = 'in_progress' and public.job_status_rank(p_old) < 4
         and (p_state #>> '{before_photos,have}')::integer < (p_state #>> '{before_photos,required}')::integer
      then jsonb_build_object('before_photos', p_state -> 'before_photos')
  end
$$;

-- ---------------------------------------------------------------------------
-- 70: the gate. SECURITY DEFINER so items and photos are counted whatever
-- the caller may see.
-- ---------------------------------------------------------------------------
create function public.jobs_ops_completion_gates() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_state    jsonb;
  v_block    jsonb;
  v_labels   text;
  v_open     integer;
begin
  if new.status is not distinct from old.status
     or not ((new.status = 'completed') or (new.status = 'in_progress' and public.job_status_rank(old.status) < 4))
     or coalesce(current_setting('detailcrm.force_job_gates', true), '') = new.id::text then
    return new;
  end if;
  v_state := public.job_gate_state(new.shop_id, new.id);
  v_block := public.job_gate_blockers_for(v_state, old.status, new.status);
  if v_block is null then
    return new;
  end if;
  if v_block ? 'open_required_items' then
    v_open := jsonb_array_length(v_block -> 'open_required_items');
    select string_agg(x.item ->> 'label', ', ' order by x.ord) into v_labels
      from jsonb_array_elements(v_block -> 'open_required_items') with ordinality as x(item, ord)
     where x.ord <= 3;
    raise exception 'Finish the required checklist items first: %',
      v_labels || case when v_open > 3 then format(' (and %s more)', v_open - 3) else '' end
      using errcode = '23514';
  end if;
  if v_block ? 'after_photos' then
    raise exception 'Add at least % "after" photo(s) before completing this job (% so far)',
      v_block #>> '{after_photos,required}', v_block #>> '{after_photos,have}'
      using errcode = '23514';
  end if;
  raise exception 'Add at least % "before" photo(s) before starting this job (% so far)',
    v_block #>> '{before_photos,required}', v_block #>> '{before_photos,have}'
    using errcode = '23514';
end
$$;

create trigger jobs_70_completion_gates before update of status on public.jobs
  for each row execute function public.jobs_ops_completion_gates();

-- ---------------------------------------------------------------------------
-- job_completion_blockers — staff on the job (can_work_job).
-- ---------------------------------------------------------------------------
create function public.job_completion_blockers(p_job_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select j.shop_id into v_shop from public.jobs j where j.id = p_job_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.can_work_job(v_shop, p_job_id) then
    raise exception 'only managers and staff assigned to this job can see its checklist and photos'
      using errcode = '42501';
  end if;
  return public.job_gate_state(v_shop, p_job_id);
end
$$;

-- ---------------------------------------------------------------------------
-- set_job_status — the status RPC (every role, same rules as a direct
-- update), with the manager override of the completion gates.
--   p_force   managers+ only (42501 otherwise); when the gates would block,
--             the waived blockers are recorded in job_gate_overrides.
--   p_reason  the override reason (<= 500 characters); a move to cancelled
--             also stores it as the job's cancel_reason.
-- Returns the job (public_token null: the customer's credential).
-- ---------------------------------------------------------------------------
create function public.set_job_status(p_job_id uuid, p_status public.job_status, p_force boolean default false,
                                      p_reason text default null)
returns public.jobs
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job    public.jobs;
  v_role   public.shop_role;
  v_edge   public.job_status_transitions;
  v_reason text := nullif(btrim(p_reason), '');
  v_block  jsonb;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  v_role := public.shop_role_of(v_job.shop_id);
  if v_role = 'technician' and not public.is_assigned_to_job(v_job.id) then
    raise exception 'technicians can only update jobs they are assigned to' using errcode = '42501';
  end if;
  if p_status is null then
    raise exception 'status is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is limited to 500 characters' using errcode = '22023';
  end if;
  if coalesce(p_force, false) and v_role not in ('owner', 'admin', 'manager') then
    raise exception 'only owners, admins and managers can override the completion requirements' using errcode = '42501';
  end if;

  select * into v_job from public.jobs j where j.id = p_job_id for update;
  if v_job.status = p_status then
    v_job.public_token := null;
    return v_job;
  end if;
  select * into v_edge from public.job_status_transitions t
   where t.from_status = v_job.status and t.to_status = p_status;
  if not found then
    raise exception 'invalid job status transition: % -> %', v_job.status, p_status using errcode = '23514';
  end if;
  if v_role = 'technician' and not v_edge.technician_allowed then
    raise exception 'technicians cannot move a job from % to %', v_job.status, p_status using errcode = '42501';
  end if;

  if coalesce(p_force, false) then
    v_block := public.job_gate_blockers_for(public.job_gate_state(v_job.shop_id, v_job.id), v_job.status, p_status);
    if v_block is not null then
      insert into public.job_gate_overrides (shop_id, job_id, to_status, reason, blockers, overridden_by)
      values (v_job.shop_id, v_job.id, p_status, v_reason, v_block, auth.uid());
      perform set_config('detailcrm.force_job_gates', v_job.id::text, true);
    end if;
  end if;

  update public.jobs j
     set status = p_status,
         cancel_reason = case when p_status = 'cancelled' then v_reason else j.cancel_reason end
   where j.id = v_job.id
  returning * into v_job;
  perform set_config('detailcrm.force_job_gates', '', true);

  v_job.public_token := null;
  return v_job;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.jobs_ops_completion_gates(), public.job_line_items_detach_checklists()
  from public, anon, authenticated;

revoke execute on function
  public.job_gate_state(uuid, uuid),
  public.job_gate_blockers_for(jsonb, public.job_status, public.job_status)
from public, anon, authenticated;
grant execute on function
  public.job_gate_state(uuid, uuid),
  public.job_gate_blockers_for(jsonb, public.job_status, public.job_status)
to service_role;

revoke execute on function
  public.job_completion_blockers(uuid),
  public.set_job_status(uuid, public.job_status, boolean, text)
from public, anon;
grant execute on function
  public.job_completion_blockers(uuid),
  public.set_job_status(uuid, public.job_status, boolean, text)
to authenticated, service_role;
