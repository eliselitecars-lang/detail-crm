-- ============================================================================
-- 0113 — Assigned members are told when their job is cancelled or marked a
-- no-show (comms P-2, 0082).
--
-- 0082 notifies an assigned member when they are assigned (job_assigned) or
-- when the start time moves (job_rescheduled), but nothing told them when
-- the job was called off: public_cancel_booking (0106) notifies owners,
-- admins and managers only ('booking_cancelled', a kind technicians cannot
-- read), and a staff cancellation from web / iPhone notified nobody (the
-- reschedule trigger only fires while the job stays scheduled / confirmed,
-- jobs_integration_status_events (0041) ignores cancelled / no_show). A
-- mobile technician assigned to tomorrow's job found out only by reopening
-- the calendar.
--
-- jobs_zz_comms_notify_cancelled (new, every context): a job that moves from
-- an open status (requested, scheduled, confirmed, en_route, in_progress) to
-- cancelled or no_show, and has not ended yet (unscheduled, or its end /
-- start is still ahead), notifies its assigned active members except the
-- person who did it: "Job #N cancelled" / "Job #N marked no-show", with the
-- slot it had and its services (staff-only content, as 0082: no money,
-- phone numbers or notes). Kind 'general', which every member may read and
-- is pushed (0082), deep-linking to the job.
--   * cancelled by a staff member of the shop: every assigned member but
--     them;
--   * cancelled by anyone else (the customer on /booking, the client portal,
--     service_role): assigned technicians — owners, admins and managers
--     already get public_cancel_booking's 'booking_cancelled' notification.
-- ============================================================================

create function public.jobs_comms_notify_cancelled() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_staff  boolean;
  v_tz     text;
  v_title  text;
  v_body   text;
  v_member record;
begin
  begin
    v_staff := v_uid is not null and exists (
      select 1 from public.shop_members m where m.shop_id = new.shop_id and m.user_id = v_uid and m.active);
    select s.timezone into v_tz from public.shops s where s.id = new.shop_id;
    v_title := 'Job #' || new.number::text || case when new.status = 'no_show' then ' marked no-show' else ' cancelled' end;
    v_body := concat_ws(' - ',
                        coalesce('Was ' || public.comms_local_when(old.scheduled_start, v_tz), 'Was not scheduled'),
                        public.comms_job_services(new.id));
    for v_member in
      select ja.member_id from public.job_assignments ja
        join public.shop_members m on m.id = ja.member_id and m.shop_id = ja.shop_id
       where ja.shop_id = new.shop_id and ja.job_id = new.id and m.active
         and m.user_id is distinct from v_uid
         and (v_staff or m.role = 'technician')
       order by ja.created_at, ja.id
    loop
      perform public.notify_member(new.shop_id, v_member.member_id, 'general', v_title, v_body, new.id);
    end loop;
  exception when others then
    raise warning 'job cancelled notification failed for job %: % (%)', new.id, sqlerrm, sqlstate;
  end;
  return null;
end
$$;

comment on function public.jobs_comms_notify_cancelled() is
  'Internal (0113): a job that is cancelled / marked no-show before it ended notifies its assigned active members (general kind, deep link to the job) except the person who did it; a cancellation by someone who is not staff of the shop notifies the assigned technicians only.';
revoke execute on function public.jobs_comms_notify_cancelled() from public, anon, authenticated;

create trigger jobs_zz_comms_notify_cancelled after update of status on public.jobs
  for each row
  when (old.status in ('requested', 'scheduled', 'confirmed', 'en_route', 'in_progress')
        and new.status in ('cancelled', 'no_show')
        and (old.scheduled_start is null or coalesce(old.scheduled_end, old.scheduled_start) > now()))
  execute function public.jobs_comms_notify_cancelled();
