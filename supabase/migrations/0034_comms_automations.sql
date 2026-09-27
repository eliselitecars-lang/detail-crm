-- ============================================================================
-- 0034 — Time-based automations (SPEC §4.7): appointment reminders, review
-- requests and follow-ups, queued by enqueue_due_automations() from cron.
--
-- Review requests and follow-ups go out exactly once per job; appointment
-- reminders exactly once per appointment TIME and RECIPIENT (a job
-- rescheduled after its reminder went out gets a reminder for the new time;
-- moving it back to a time that was already reminded does not repeat it; a
-- job moved to another customer reminds the customer it now belongs to,
-- except on a channel whose address — phone / email — already got that
-- time's reminder, e.g. a duplicate customer record). Enforced by durable
-- markers:
--   * job_automation_log — one row per (job, key) for review requests /
--     follow-ups and per (job, appointment start, customer) for reminders
--     (partial unique indexes); claimed with INSERT … ON CONFLICT DO
--     NOTHING before anything is queued, so re-runs and concurrent runs
--     never queue twice. When a job moves to another customer, reminder rows
--     of former customers whose reminder never reached the sender (all its
--     copies still queued / withdrawn, or nothing could be sent) are
--     dropped: they reminded nobody, and the appointment may come back;
--   * jobs.review_requested_at — stamped when the review request was
--     queued (a second marker: no repeat even if the log row is removed);
--     jobs.reminder_sent_at — when the latest reminder was queued.
-- A reminder still QUEUED when the appointment moves is re-rendered with the
-- new time (0033) and so becomes the reminder for the new time: its log row
-- follows (scheduled_for := the new start), or, when that time was already
-- reminded, the queued copy is withdrawn as a duplicate. One already with
-- the sender stays logged for the old time; if it comes back for a retry
-- it is withdrawn (messages_comms_retry_reminder_time).
-- Messages staff sent by hand (enqueue_template_message) count too: a
-- channel on which the job already has a live (not failed / cancelled)
-- message of the key — for reminders, one announcing the current
-- appointment to its current customer that went out, or is queued to go
-- out, before the appointment starts — is not sent again.
-- Nothing runs while app_base_url is unset (55000): the default reminder
-- and follow-up wording carries customer links, and a run would otherwise
-- log those automations as skipped for good.
-- An automation for a job is due at
--   appointment_reminder  scheduled_start + offset   (job scheduled/confirmed and not yet started;
--                                                     offset ≤ 0, sent before the appointment
--                                                     starts — a reminder set to the start time
--                                                     itself (offset 0) may go out until 15
--                                                     minutes after it, one scheduler tick of slack)
--   review_request        completed_at + offset      (job completed; shop has a review URL)
--   follow_up             completed_at + offset      (job completed; marketing: only to
--                                                     customers opted in on the channel, see 0033)
-- and is skipped (never logged) when it became sendable more than 24 hours
-- ago, so a scheduler outage never blasts stale messages. A review request /
-- follow-up becomes sendable at its due time; a reminder at the later of its
-- due time and jobs.appointment_set_at (when the job got its current start
-- time, customer or scheduled/confirmed status): an appointment booked,
-- confirmed, moved or re-assigned inside the reminder offset is reminded on
-- the next run instead of being treated as overdue. It delivers on
-- every ENABLED channel template of the key that the customer can receive;
-- if no template of the key is enabled, the job is not processed (enabling
-- the template later still catches jobs that are due within the window).
-- A due job whose customer cannot receive any enabled channel (no address,
-- opted out, no SMS number) is logged as 'skipped' and not retried.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- jobs.appointment_set_at — when the job last got its current appointment:
-- its start time, its customer, or a scheduled / confirmed status (from
-- requested, cancelled …). Server-maintained (server clock); trusted code
-- (service_role, migrations, tests) may set it explicitly, API clients
-- never. Reminder staleness is measured from greatest(due time, this).
-- ---------------------------------------------------------------------------
alter table public.jobs add column appointment_set_at timestamptz not null default now();

comment on column public.jobs.appointment_set_at is
  'When the job last got its current start time, customer or scheduled/confirmed status (server clock). Appointment reminders are stale 24 h after greatest(due time, this).';

create function public.jobs_comms_appointment_set_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.appointment_set_at is null or public.is_client_context() then
      new.appointment_set_at := now();
    end if;
    return new;
  end if;
  -- trusted code may set the stamp explicitly; otherwise it follows the job
  if public.is_client_context() or new.appointment_set_at is not distinct from old.appointment_set_at then
    if new.scheduled_start is distinct from old.scheduled_start
       or new.customer_id is distinct from old.customer_id
       or (new.status in ('scheduled', 'confirmed') and old.status not in ('scheduled', 'confirmed')) then
      new.appointment_set_at := now();
    else
      new.appointment_set_at := old.appointment_set_at;
    end if;
  end if;
  return new;
end
$$;

create trigger jobs_80_comms_appointment_set_at before insert or update on public.jobs
  for each row execute function public.jobs_comms_appointment_set_at();

create table public.job_automation_log (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  job_id       uuid not null,
  customer_id  uuid not null,
  key          public.message_template_key not null
                 check (key in ('appointment_reminder', 'review_request', 'follow_up')),
  scheduled_for timestamptz,
  due_at       timestamptz not null,
  processed_at timestamptz not null,
  outcome      text not null check (outcome in ('queued', 'skipped')),
  message_ids  uuid[] not null default '{}',
  created_at   timestamptz not null default now(),
  constraint job_automation_log_shop_id_id_key unique (shop_id, id),
  constraint job_automation_log_scheduled_for check ((key = 'appointment_reminder') = (scheduled_for is not null)),
  constraint job_automation_log_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  -- the recipient: the job's customer when the automation was processed
  constraint job_automation_log_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint job_automation_log_outcome check ((outcome = 'queued') = (cardinality(message_ids) > 0))
);
-- review requests / follow-ups: once per job
create unique index job_automation_log_once on public.job_automation_log (job_id, key)
  where key <> 'appointment_reminder';
-- reminders: once per job, appointment time and recipient
create unique index job_automation_log_reminder_once on public.job_automation_log (job_id, scheduled_for, customer_id)
  where key = 'appointment_reminder';
create index job_automation_log_shop_job_idx on public.job_automation_log (shop_id, job_id);
create index job_automation_log_shop_customer_idx on public.job_automation_log (shop_id, customer_id);

comment on table public.job_automation_log is
  'One row per (job, automation) ever processed — per (job, appointment time, customer) for reminders: the idempotency marker for enqueue_due_automations.';
comment on column public.job_automation_log.scheduled_for is
  'appointment_reminder: the appointment start the reminder was for. Null for review requests and follow-ups.';

alter table public.job_automation_log enable row level security;

-- Managers+ may see what automations did for their jobs; writes are
-- service/definer only.
create policy job_automation_log_select on public.job_automation_log for select to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.job_automation_log from anon;
revoke insert, update, delete, truncate, references, trigger on public.job_automation_log from authenticated;

-- Supports the review/follow-up scan.
create index jobs_shop_completed_idx on public.jobs (shop_id, completed_at) where completed_at is not null;

-- ---------------------------------------------------------------------------
-- enqueue_due_automations (service_role / cron). Returns the number of
-- messages queued.
-- ---------------------------------------------------------------------------
create function public.enqueue_due_automations(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := coalesce(p_now, now());
  v_stale    timestamptz := coalesce(p_now, now()) - interval '24 hours';
  v_due      record;
  v_log_id   uuid;
  v_ch       public.message_channel;
  v_msg      uuid;
  v_ids      uuid[];
  v_total    integer := 0;
begin
  -- Customer links (booking, quote, invoice, booking page, unsubscribe) need
  -- the web app origin. Refuse to run rather than log due automations as
  -- 'skipped' for good: once configured, the next run catches up on
  -- everything still inside the 24 hour window.
  if public.app_url('/') is null then
    raise exception 'app_base_url is not configured; automations cannot build customer links'
      using errcode = '55000', hint = 'Run supabase/setup/cron.sql (public.set_app_base_url).';
  end if;

  for v_due in
    with offsets as (
      select t.shop_id, t.key, max(t.offset_minutes) as offset_minutes
        from public.message_templates t
       where t.enabled and t.key in ('appointment_reminder', 'review_request', 'follow_up')
       group by t.shop_id, t.key
    )
    -- appointment reminders
    select j.shop_id, j.id as job_id, j.customer_id, o.key, j.scheduled_start as scheduled_for,
           j.scheduled_start + make_interval(mins => o.offset_minutes) as due_at
      from offsets o
      join public.jobs j on j.shop_id = o.shop_id
     where o.key = 'appointment_reminder'
       and j.status in ('scheduled', 'confirmed')
       and not exists (select 1 from public.job_automation_log l
                        where l.job_id = j.id and l.key = 'appointment_reminder'
                          and l.scheduled_for = j.scheduled_start and l.customer_id = j.customer_id)
       and j.scheduled_start + make_interval(mins => o.offset_minutes) <= v_now
       -- stale only 24 h after it could first have been sent
       and greatest(j.scheduled_start + make_interval(mins => o.offset_minutes), j.appointment_set_at) > v_stale
       and v_now < j.scheduled_start + case when o.offset_minutes = 0 then interval '15 minutes'
                                            else interval '0 minutes' end
    union all
    -- review requests and follow-ups
    select j.shop_id, j.id, j.customer_id, o.key, null::timestamptz,
           j.completed_at + make_interval(mins => o.offset_minutes)
      from offsets o
      join public.shops s on s.id = o.shop_id
      join public.jobs j on j.shop_id = o.shop_id
     where o.key in ('review_request', 'follow_up')
       and (o.key <> 'review_request' or (s.review_url is not null and btrim(s.review_url) <> ''))
       and j.status = 'completed'
       and (o.key <> 'review_request' or j.review_requested_at is null)
       and j.completed_at is not null
       and j.completed_at <= v_now - make_interval(mins => o.offset_minutes)
       and j.completed_at > v_stale - make_interval(mins => o.offset_minutes)
    order by 6, 2, 4
  loop
    insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at,
                                           outcome)
    values (v_due.shop_id, v_due.job_id, v_due.customer_id, v_due.key, v_due.scheduled_for, v_due.due_at, v_now,
            'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- already processed (this or another run)

    v_ids := '{}';
    foreach v_ch in array enum_range(null::public.message_channel) loop
      -- a job moved to another customer: an address that already got this
      -- appointment time's reminder (as a former customer's copy) is not
      -- reminded twice
      continue when v_due.key = 'appointment_reminder' and exists (
        select 1
          from public.job_automation_log l
          join public.messages m on m.id = any (l.message_ids) and m.shop_id = l.shop_id
          join public.customers c on c.id = v_due.customer_id and c.shop_id = v_due.shop_id
         where l.job_id = v_due.job_id and l.key = 'appointment_reminder'
           and l.scheduled_for = v_due.scheduled_for and l.customer_id <> v_due.customer_id
           and m.channel = v_ch and m.status in ('queued', 'sending', 'sent', 'delivered')
           and public.comms_address_key(m.channel, m.to_address)
               = public.comms_address_key(v_ch, case v_ch when 'sms' then c.phone else c.email::text end));
      -- staff already sent this job's message on the channel by hand
      -- (enqueue_template_message; not failed / withdrawn): not sent twice.
      -- A reminder counts only when it announces the job's current
      -- appointment for this customer: still queued (re-rendered on every
      -- reschedule) to go out BEFORE the appointment starts, or created
      -- since the job got its current time. A queued one scheduled for the
      -- start or later — e.g. staff scheduled it for the day before the
      -- original date and the appointment then moved earlier — would be
      -- withdrawn at the claim ("already started"; comms_withdraw_reason)
      -- and remind nobody, so it does not stand in for this reminder.
      -- Reminders the automation queued are tracked by their log rows instead.
      continue when exists (
        select 1
          from public.messages m
          join public.jobs j on j.id = m.job_id and j.shop_id = m.shop_id
         where m.shop_id = v_due.shop_id and m.job_id = v_due.job_id and m.direction = 'outbound'
           and m.template_key = v_due.key and m.channel = v_ch and m.status not in ('failed', 'cancelled')
           and (v_due.key <> 'appointment_reminder'
                or (m.customer_id = v_due.customer_id
                    and ((m.status = 'queued' and m.send_after < j.scheduled_start)
                         or (m.status <> 'queued' and m.created_at >= j.appointment_set_at))
                    and not exists (select 1 from public.job_automation_log l
                                     where l.shop_id = v_due.shop_id and l.job_id = v_due.job_id
                                       and l.key = 'appointment_reminder' and m.id = any (l.message_ids)))));
      v_msg := public.enqueue_customer_template(v_due.shop_id, v_due.customer_id, v_due.key, v_ch,
                                                v_due.job_id, null, v_now, null);
      if v_msg is not null then
        v_ids := v_ids || v_msg;
      end if;
    end loop;

    if cardinality(v_ids) > 0 then
      update public.job_automation_log l set outcome = 'queued', message_ids = v_ids where l.id = v_log_id;
      if v_due.key = 'appointment_reminder' then
        update public.jobs j set reminder_sent_at = v_now where j.id = v_due.job_id and j.shop_id = v_due.shop_id;
      elsif v_due.key = 'review_request' then
        update public.jobs j set review_requested_at = v_now where j.id = v_due.job_id and j.shop_id = v_due.shop_id;
      end if;
      v_total := v_total + cardinality(v_ids);
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;

-- ---------------------------------------------------------------------------
-- A reminder still queued when its appointment moves now describes the new
-- time (jobs_comms_sync_queued re-renders it), so its log row follows the
-- appointment; if the new time was already reminded (or the job is no
-- longer scheduled), the queued copy is a duplicate and is withdrawn.
-- Reminders already handed to the sender stay logged for the time they
-- announced, so the new time gets its own.
-- ---------------------------------------------------------------------------
create function public.jobs_comms_reminder_log_follow() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_log public.job_automation_log;
  v_new public.job_automation_log;
begin
  for v_log in
    select l.* from public.job_automation_log l
     where l.shop_id = new.shop_id and l.job_id = new.id and l.key = 'appointment_reminder'
       and l.scheduled_for = old.scheduled_start
       and exists (select 1 from public.messages m
                    where m.id = any (l.message_ids) and m.shop_id = l.shop_id and m.status = 'queued')
     for update
  loop
    v_new := null;
    if new.scheduled_start is not null then
      select d.* into v_new from public.job_automation_log d
       where d.job_id = new.id and d.key = 'appointment_reminder' and d.scheduled_for = new.scheduled_start
         and d.customer_id = v_log.customer_id
       for update;
    end if;
    if new.scheduled_start is null or v_new.outcome = 'queued' then
      update public.messages m
         set status = 'cancelled',
             error = case when new.scheduled_start is null then 'the appointment is no longer scheduled'
                          else 'a reminder for this appointment time was already sent' end
       where m.id = any (v_log.message_ids) and m.shop_id = v_log.shop_id and m.status = 'queued';
    elsif v_new.id is not null then
      -- the new time was processed before but nothing could be sent then
      -- (outcome 'skipped'): the queued reminder is that time's reminder now
      update public.job_automation_log d
         set outcome = 'queued', message_ids = v_log.message_ids
       where d.id = v_new.id;
      delete from public.job_automation_log l where l.id = v_log.id;
    else
      -- the queued copies announce the new time now (in the rare race where
      -- another channel's copy already went out, the new time is still
      -- announced on the queued channel and nothing is sent twice)
      update public.job_automation_log l set scheduled_for = new.scheduled_start where l.id = v_log.id;
    end if;
  end loop;
  return null;
end
$$;

create trigger jobs_zz_comms_reminder_log_follow after update of scheduled_start on public.jobs
  for each row when (old.scheduled_start is distinct from new.scheduled_start and old.scheduled_start is not null)
  execute function public.jobs_comms_reminder_log_follow();

-- ---------------------------------------------------------------------------
-- A job moved to another customer: the customer it now belongs to is
-- reminded by the next run (reminders are logged per recipient). Reminder
-- rows of former customers that reminded nobody — every copy still queued
-- (jobs_comms_sync_queued withdraws those) or withdrawn, or nothing could be
-- sent — are dropped, so the appointment is reminded again if it returns to
-- that customer. Rows whose reminder reached the sender stay.
-- ---------------------------------------------------------------------------
create function public.jobs_comms_reminder_log_recipient() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.job_automation_log l
   where l.shop_id = new.shop_id and l.job_id = new.id and l.key = 'appointment_reminder'
     and l.customer_id <> new.customer_id
     and not exists (select 1 from public.messages m
                      where m.id = any (l.message_ids) and m.shop_id = l.shop_id
                        and m.status not in ('queued', 'cancelled'));
  return null;
end
$$;

create trigger jobs_zz_comms_reminder_log_recipient after update of customer_id on public.jobs
  for each row when (old.customer_id is distinct from new.customer_id)
  execute function public.jobs_comms_reminder_log_recipient();

-- ---------------------------------------------------------------------------
-- A reminder that was already with the sender when its appointment moved
-- (so jobs_comms_reminder_log_follow left its log row on the old time) and
-- then comes back for a retry is withdrawn: it announces the old time, and
-- the new time gets its own reminder from the next run. Its log row is
-- dropped when none of its copies reached the sender, so the old time is
-- reminded again if the appointment moves back. A retried reminder whose
-- log row is for the current time (or that staff sent by hand) is
-- re-rendered instead (messages_30_retry_rerender, 0033).
-- ---------------------------------------------------------------------------
create function public.messages_comms_retry_reminder_time() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_start timestamptz;
  v_log   public.job_automation_log;
begin
  if new.status <> 'queued' or old.status <> 'sending' or new.job_id is null
     or new.template_key is distinct from 'appointment_reminder' then
    return new;
  end if;
  select j.scheduled_start into v_start from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
  select l.* into v_log from public.job_automation_log l
   where l.shop_id = new.shop_id and l.job_id = new.job_id and l.key = 'appointment_reminder'
     and new.id = any (l.message_ids)
   order by l.created_at desc, l.id
   limit 1
   for update;
  if v_log.id is null or v_log.scheduled_for is not distinct from v_start then
    return new;
  end if;
  new.status := 'cancelled';
  new.error := 'the appointment was rescheduled; the new time gets its own reminder';
  new.claimed_at := null;
  if not exists (select 1 from public.messages m
                  where m.id = any (v_log.message_ids) and m.shop_id = v_log.shop_id and m.id <> new.id
                    and m.status not in ('queued', 'cancelled')) then
    delete from public.job_automation_log l where l.id = v_log.id;
  end if;
  return new;
end
$$;

create trigger messages_20_retry_reminder_time before update of status on public.messages
  for each row when (old.status = 'sending' and new.status = 'queued')
  execute function public.messages_comms_retry_reminder_time();

revoke execute on function
  public.messages_comms_retry_reminder_time(),
  public.jobs_comms_appointment_set_at(),
  public.jobs_comms_reminder_log_follow(),
  public.jobs_comms_reminder_log_recipient()
from public, anon, authenticated;

revoke execute on function public.enqueue_due_automations(timestamptz) from public, anon, authenticated;
grant execute on function public.enqueue_due_automations(timestamptz) to service_role;
