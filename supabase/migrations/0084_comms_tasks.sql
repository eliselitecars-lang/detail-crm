-- ============================================================================
-- 0084 — Staff tasks / internal reminders (P-32).
--
-- Table, RLS and realtime publication: 0081. Who may do what:
--   owner / admin / manager  every task of the shop: create, assign to anyone,
--                            link any customer / job, edit, complete, delete
--   technician               tasks assigned to them or created by them:
--                            create for themselves (or nobody), linked at
--                            most to a job they work (never a customer);
--                            edit only title / notes / due time / done;
--                            delete only what they created
-- Server-set: created_by (the creator), done_at / done_by (stamped when a
-- task is marked done, cleared when reopened), due_notified_at (reset when
-- the due time changes, so the new time is reminded).
-- Notifications: 'task_assigned' to the assignee (not when they assigned it
-- to themselves), 'task_due' once when the due time arrives (to the active
-- assignee, else the active creator — also when the assignee has been
-- deactivated) from enqueue_task_reminders, which runs with
-- the automations (enqueue_due_automations, 0086).
-- ============================================================================

create function public.tasks_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_mgr boolean;
begin
  -- the assignee must be an active member (another shop's member is left
  -- to the composite foreign key: 23503)
  if new.assignee_member_id is not null
     and (tg_op = 'INSERT' or new.assignee_member_id is distinct from old.assignee_member_id)
     and exists (select 1 from public.shop_members m
                  where m.id = new.assignee_member_id and m.shop_id = new.shop_id and not m.active) then
    raise exception 'tasks can only be assigned to active team members' using errcode = '22023';
  end if;
  new.title := btrim(new.title);
  new.notes := nullif(btrim(coalesce(new.notes, ''), E' \t\r\n'), '');

  if not public.is_client_context() then
    if tg_op = 'UPDATE' and new.due_at is distinct from old.due_at
       and new.due_notified_at is not distinct from old.due_notified_at then
      new.due_notified_at := null;
    end if;
    return new;
  end if;

  v_mgr := public.is_shop_manager(new.shop_id);
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.due_notified_at := null;
    if new.done_at is not null then
      new.done_at := now();
      new.done_by := auth.uid();
    else
      new.done_by := null;
    end if;
    return new;
  end if;

  new.created_by := old.created_by;
  if not v_mgr
     and (new.assignee_member_id is distinct from old.assignee_member_id
          or new.customer_id is distinct from old.customer_id
          or new.job_id is distinct from old.job_id) then
    raise exception 'only owners, admins and managers can reassign a task or change its customer or job'
      using errcode = '42501';
  end if;
  if old.done_at is null and new.done_at is not null then
    new.done_at := now();
    new.done_by := auth.uid();
  elsif new.done_at is null then
    new.done_by := null;
  else
    new.done_at := old.done_at;
    new.done_by := old.done_by;
  end if;
  if new.due_at is distinct from old.due_at then
    new.due_notified_at := null;
  else
    new.due_notified_at := old.due_notified_at;
  end if;
  return new;
end
$$;

create trigger tasks_80_guard before insert or update on public.tasks
  for each row execute function public.tasks_guard();

-- ---------------------------------------------------------------------------
-- Assigned: the assignee is notified (not when they assigned it to
-- themselves, not for a task that is already done). Never blocks the write.
-- ---------------------------------------------------------------------------
create function public.tasks_comms_notify() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_tz   text;
begin
  if new.assignee_member_id is null or new.done_at is not null
     or (tg_op = 'UPDATE' and new.assignee_member_id is not distinct from old.assignee_member_id) then
    return null;
  end if;
  begin
    select m.user_id into v_user from public.shop_members m
     where m.id = new.assignee_member_id and m.shop_id = new.shop_id and m.active;
    if v_user is null or v_user = auth.uid() then
      return null;
    end if;
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    perform public.notify_member(new.shop_id, new.assignee_member_id, 'task_assigned',
                                 'Task: ' || new.title,
                                 'Due ' || public.comms_local_when(new.due_at, v_tz),
                                 new.job_id, new.customer_id);
  exception when others then
    raise warning 'task assigned notification failed for task %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

create trigger tasks_zz_comms_notify after insert or update of assignee_member_id on public.tasks
  for each row execute function public.tasks_comms_notify();

-- ---------------------------------------------------------------------------
-- enqueue_task_reminders (service_role; called by enqueue_due_automations):
-- open tasks whose due time arrived within the last 24 hours and were not
-- reminded yet get one 'task_due' notification — to the assignee while an
-- active member, else (no assignee, or a deactivated one) the creator while
-- an active member — and due_notified_at = p_now. A task with neither is
-- stamped without a notification (nobody left to tell). Tasks due longer
-- ago (a scheduler outage) are not reminded. Returns the number of
-- notifications created.
-- ---------------------------------------------------------------------------
create function public.enqueue_task_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := coalesce(p_now, now());
  v_task   public.tasks;
  v_member uuid;
  v_tz     text;
  v_count  integer := 0;
begin
  for v_task in
    select t.* from public.tasks t
     where t.done_at is null and t.due_notified_at is null and t.due_at is not null
       and t.due_at <= v_now and t.due_at > v_now - interval '24 hours'
     order by t.due_at, t.id
     for update skip locked
  loop
    v_member := null;
    if v_task.assignee_member_id is not null then
      select m.id into v_member from public.shop_members m
       where m.id = v_task.assignee_member_id and m.shop_id = v_task.shop_id and m.active;
    end if;
    -- no assignee, or one who has since been deactivated (left the shop;
    -- the row stays, so the ON DELETE SET NULL never fires): the creator
    if v_member is null and v_task.created_by is not null then
      select m.id into v_member from public.shop_members m
       where m.shop_id = v_task.shop_id and m.user_id = v_task.created_by and m.active;
    end if;
    if v_member is not null then
      select s.timezone into v_tz from public.shops s where s.id = v_task.shop_id;
      if public.notify_member(v_task.shop_id, v_member, 'task_due', 'Task due: ' || v_task.title,
                              'Due ' || public.comms_local_when(v_task.due_at, v_tz),
                              v_task.job_id, v_task.customer_id) is not null then
        v_count := v_count + 1;
      end if;
    end if;
    update public.tasks t set due_notified_at = v_now where t.id = v_task.id;
  end loop;
  return v_count;
end
$$;

revoke execute on function
  public.tasks_guard(),
  public.tasks_comms_notify()
from public, anon, authenticated;

revoke execute on function public.enqueue_task_reminders(timestamptz) from public, anon, authenticated;
grant execute on function public.enqueue_task_reminders(timestamptz) to service_role;
