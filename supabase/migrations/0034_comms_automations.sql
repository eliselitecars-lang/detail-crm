-- ============================================================================
-- 0034 — Time-based automations (SPEC §4.7): appointment reminders, review
-- requests and follow-ups, queued by enqueue_due_automations() from cron.
--
-- Exactly once per job per automation key, enforced by two durable markers:
--   * job_automation_log UNIQUE (job_id, key) — claimed with
--     INSERT … ON CONFLICT DO NOTHING before anything is queued, so re-runs
--     and concurrent runs never queue twice;
--   * jobs.reminder_sent_at / jobs.review_requested_at — stamped when the
--     reminder / review request was actually queued.
-- An automation for a job is due at
--   appointment_reminder  scheduled_start + offset   (job scheduled/confirmed and not yet started;
--                                                     offset ≤ 0, sent before the appointment
--                                                     starts — a reminder set to the start time
--                                                     itself (offset 0) may go out until 15
--                                                     minutes after it, one scheduler tick of slack)
--   review_request        completed_at + offset      (job completed; shop has a review URL)
--   follow_up             completed_at + offset      (job completed)
-- and is skipped (never logged) when its send time is more than 24 hours in
-- the past, so a scheduler outage never blasts stale messages. It delivers on
-- every ENABLED channel template of the key that the customer can receive;
-- if no template of the key is enabled, the job is not processed (enabling
-- the template later still catches jobs that are due within the window).
-- A due job whose customer cannot receive any enabled channel (no address,
-- opted out, no SMS number) is logged as 'skipped' and not retried.
-- ============================================================================

create table public.job_automation_log (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  job_id       uuid not null,
  key          public.message_template_key not null
                 check (key in ('appointment_reminder', 'review_request', 'follow_up')),
  due_at       timestamptz not null,
  processed_at timestamptz not null,
  outcome      text not null check (outcome in ('queued', 'skipped')),
  message_ids  uuid[] not null default '{}',
  created_at   timestamptz not null default now(),
  constraint job_automation_log_shop_id_id_key unique (shop_id, id),
  constraint job_automation_log_once unique (job_id, key),
  constraint job_automation_log_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint job_automation_log_outcome check ((outcome = 'queued') = (cardinality(message_ids) > 0))
);
create index job_automation_log_shop_job_idx on public.job_automation_log (shop_id, job_id);

comment on table public.job_automation_log is
  'One row per (job, automation) ever processed: the idempotency marker for enqueue_due_automations.';

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
  for v_due in
    with offsets as (
      select t.shop_id, t.key, max(t.offset_minutes) as offset_minutes
        from public.message_templates t
       where t.enabled and t.key in ('appointment_reminder', 'review_request', 'follow_up')
       group by t.shop_id, t.key
    )
    -- appointment reminders
    select j.shop_id, j.id as job_id, j.customer_id, o.key,
           j.scheduled_start + make_interval(mins => o.offset_minutes) as due_at
      from offsets o
      join public.jobs j on j.shop_id = o.shop_id
     where o.key = 'appointment_reminder'
       and j.status in ('scheduled', 'confirmed')
       and j.reminder_sent_at is null
       and j.scheduled_start + make_interval(mins => o.offset_minutes) <= v_now
       and j.scheduled_start + make_interval(mins => o.offset_minutes) > v_stale
       and v_now < j.scheduled_start + case when o.offset_minutes = 0 then interval '15 minutes'
                                            else interval '0 minutes' end
    union all
    -- review requests and follow-ups
    select j.shop_id, j.id, j.customer_id, o.key,
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
    order by 5, 2, 4
  loop
    insert into public.job_automation_log (shop_id, job_id, key, due_at, processed_at, outcome)
    values (v_due.shop_id, v_due.job_id, v_due.key, v_due.due_at, v_now, 'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- already processed (this or another run)

    v_ids := '{}';
    foreach v_ch in array enum_range(null::public.message_channel) loop
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

revoke execute on function public.enqueue_due_automations(timestamptz) from public, anon, authenticated;
grant execute on function public.enqueue_due_automations(timestamptz) to service_role;
