-- ============================================================================
-- 0086 — Up to 3 appointment reminders + per-service follow-ups (P-4), and
-- enqueue_due_automations v2 (which now also runs the document follow-ups
-- of 0085, the per-service follow-ups and the task reminders of 0084, so
-- the existing cron job and the messaging function's run_automations action
-- need no change).
--
-- Multiple reminders: message_templates.reminder_offsets_minutes (all
-- channels of appointment_reminder share it; null = the single
-- offset_minutes of 0034). Each (job, appointment start, customer, OFFSET)
-- is reminded at most once (job_automation_log.reminder_offset_minutes).
-- A shop with a single reminder logs it exactly as before P-4 (offset
-- null); once the shop adds more offsets, such a row stands for every
-- offset that was due when it was processed (comms_reminder_log_covers).
-- When several of a job's offsets are due at once (an appointment booked or
-- moved inside them), only the one nearest the appointment is sent; the
-- earlier ones are logged 'skipped' — a customer never gets two reminders
-- in one go. A
-- reminder staff sent by hand counts only for the offset whose window it
-- went out in (from that offset's due time to the next one's; the first
-- offset's window starts whenever), so a week-ahead manual reminder does not
-- cancel the day-before one. Every 0034 rule (staleness,
-- appointment_set_at, per-recipient rows, re-rendering of queued copies,
-- the address-already-reminded check) applies per offset.
--
-- Per-service follow-ups (service_followups): offset_days after a completed
-- job — due at 10:00 shop-local time on the local date of completed_at +
-- offset_days (comms_followup_due_at, 0085: calendar days, so a DST change
-- never moves it, and never at the minute of the day the job happened to be
-- closed) — once per (job, follow-up row), for each distinct service on the job
-- (a package counts as itself and as each service it includes). Skipped
-- while the customer has another job with that service that is still open
-- (requested, scheduled or under way — whatever its dates, so a request
-- logged while this job was being worked counts) or was completed after
-- this one. Sent on the
-- row's channel with the row's wording when the shop's service_followup
-- template of that channel is enabled (the shop-wide switch); marketing
-- rules apply (opt-in on the channel, re-checked at send time; SMS opt-out
-- line; email unsubscribe link). {{rebook_link}} opens the shop's online
-- booking page with the service (and the vehicle's size) preselected, while
-- online booking is on; lines using it are left out otherwise. Stale after
-- 24 hours like every automation. Never queued for an archived customer
-- (enqueue_message_core) and withdrawn at send time once the customer is
-- archived (comms_withdraw_reason). A run outside 08:00-21:00 shop-local
-- (a late scheduler) holds the promotional message until 10:00 local
-- (comms_marketing_send_after: TCPA limits marketing texts to 8 am-9 pm).
-- The same hold applies to the generic follow_up template (the other
-- comms_is_marketing_key key), which is due at completed_at + offset_minutes
-- and so keeps the time of day the job was closed: a job closed at 22:40
-- local gets its follow-up the next 10:00, not at 22:40 thirty days later.
-- Promotional follow-ups are scheduled in the shop's timezone (the
-- customer's own is not known).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- message_templates: reminder offsets normalised and shared by all channels
-- ---------------------------------------------------------------------------

-- BEFORE INSERT/UPDATE (replaced): trim; a new channel row of a time-based
-- key adopts the offset(s) its siblings already use; reminder offsets are
-- de-duplicated and sorted descending (nearest the appointment first) and
-- offset_minutes follows the nearest; an update that changes only
-- offset_minutes (a client predating multiple reminders) switches the key
-- back to a single reminder at that offset.
create or replace function public.message_templates_before_write() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sib_offset  integer;
  v_sib_offsets integer[];
begin
  new.body := btrim(new.body, E' \t\r\n');
  new.subject := nullif(btrim(new.subject), '');
  if tg_op = 'UPDATE' then
    if new.key <> old.key or new.channel <> old.channel then
      raise exception 'a template''s key and channel cannot be changed' using errcode = '42501';
    end if;
    if new.reminder_offsets_minutes is not null
       and new.reminder_offsets_minutes is not distinct from old.reminder_offsets_minutes
       and new.offset_minutes is distinct from old.offset_minutes then
      new.reminder_offsets_minutes := null;
    end if;
  else
    select t.offset_minutes, t.reminder_offsets_minutes into v_sib_offset, v_sib_offsets
      from public.message_templates t
     where t.shop_id = new.shop_id and t.key = new.key and t.offset_minutes is not null
     limit 1;
    if v_sib_offset is not null then
      new.offset_minutes := v_sib_offset;
      new.reminder_offsets_minutes := v_sib_offsets;
    end if;
  end if;
  if new.key = 'appointment_reminder' and coalesce(cardinality(new.reminder_offsets_minutes), 0) > 0
     and array_position(new.reminder_offsets_minutes, null) is null then
    new.reminder_offsets_minutes := (select array_agg(distinct o order by o desc)
                                       from unnest(new.reminder_offsets_minutes) as o);
    new.offset_minutes := new.reminder_offsets_minutes[1];
  end if;
  return new;
end
$$;

-- AFTER UPDATE (replaced): all channels of a key share one schedule — the
-- offset and the reminder offsets.
create or replace function public.message_templates_sync_offset() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.message_templates t
     set offset_minutes = new.offset_minutes, reminder_offsets_minutes = new.reminder_offsets_minutes
   where t.shop_id = new.shop_id and t.key = new.key and t.id <> new.id
     and (t.offset_minutes is distinct from new.offset_minutes
          or t.reminder_offsets_minutes is distinct from new.reminder_offsets_minutes);
  return null;
end
$$;

drop trigger message_templates_sync_offset on public.message_templates;
create trigger message_templates_sync_offset after update of offset_minutes, reminder_offsets_minutes
  on public.message_templates
  for each row when (old.offset_minutes is distinct from new.offset_minutes
                     or old.reminder_offsets_minutes is distinct from new.reminder_offsets_minutes)
  execute function public.message_templates_sync_offset();

-- Does a reminder log row stand for the reminder at offset p_offset (due at
-- p_due_at)? A row logged for that offset does. A row without an offset (a
-- single-reminder shop, or logged before P-4) is THE reminder while the
-- shop has a single reminder; once it has several, it stands for every
-- offset that was due by the time it was processed (a reminder sent a day
-- before covers the "1 day before" offset, not the "1 hour before" one).
create function public.comms_reminder_log_covers(
  p_log_offset        integer,
  p_log_processed_at  timestamptz,
  p_offset            integer,
  p_due_at            timestamptz,
  p_multi             boolean
) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(p_log_offset = p_offset
                  or (p_log_offset is null and (not p_multi or p_due_at <= p_log_processed_at)), false)
$$;

-- ---------------------------------------------------------------------------
-- service_followups: at most 4 per service and channel (serialised per
-- service, so concurrent inserts cannot exceed it).
-- ---------------------------------------------------------------------------
create function public.service_followups_limit() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.body := btrim(new.body, E' \t\r\n');
  new.subject := nullif(btrim(new.subject), '');
  if tg_op = 'UPDATE' and new.service_id = old.service_id and new.channel = old.channel then
    return new;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.service_followups:' || new.service_id::text, 0));
  if (select count(*) from public.service_followups f
       where f.shop_id = new.shop_id and f.service_id = new.service_id and f.channel = new.channel
         and f.id <> new.id) >= 4 then
    raise exception 'a service can have at most 4 % follow-ups', new.channel using errcode = '23514';
  end if;
  return new;
end
$$;

create trigger service_followups_80_limit before insert or update on public.service_followups
  for each row execute function public.service_followups_limit();

-- ---------------------------------------------------------------------------
-- When a promotional message produced at p_now may go out: p_now while it
-- is between 08:00 and 21:00 in p_timezone, else the next 10:00 there
-- (the same morning before 08:00, the next morning from 21:00). Internal.
-- ---------------------------------------------------------------------------
create function public.comms_marketing_send_after(p_now timestamptz, p_timezone text) returns timestamptz
language sql immutable
set search_path = ''
as $$
  select case when l.local_time >= time '08:00' and l.local_time < time '21:00' then p_now
              else ((l.local_date + case when l.local_time >= time '21:00' then 1 else 0 end)
                    + time '10:00') at time zone p_timezone end
    from (select (p_now at time zone p_timezone)::time as local_time,
                 (p_now at time zone p_timezone)::date as local_date) as l
$$;

-- ---------------------------------------------------------------------------
-- enqueue_service_followups (service_role; called by enqueue_due_automations).
-- Returns the number of messages queued.
-- ---------------------------------------------------------------------------
create function public.enqueue_service_followups(p_now timestamptz default now()) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := coalesce(p_now, now());
  v_due    record;
  v_log_id uuid;
  v_msg    uuid;
  v_total  integer := 0;
begin
  for v_due in
    with job_services as (
      select distinct li.shop_id, li.job_id, li.service_id
        from public.job_line_items li
       where li.service_id is not null
      union
      select li.shop_id, li.job_id, pi.service_id
        from public.job_line_items li
        join public.package_items pi on pi.package_id = li.service_id and pi.shop_id = li.shop_id
    )
    select j.shop_id, j.id as job_id, j.customer_id, f.id as followup_id, f.service_id, f.channel,
           f.subject, f.body, d.due_at, s.timezone,
           case when b.enabled then public.app_url('/book/' || s.slug || '?services=' || f.service_id::text
                                                   || coalesce('&category=' || v.category_id::text, '')) end
             as rebook_link
      from public.service_followups f
      join public.message_templates t on t.shop_id = f.shop_id and t.key = 'service_followup'
                                     and t.channel = f.channel and t.enabled
      join public.shops s on s.id = f.shop_id
      left join public.booking_settings b on b.shop_id = f.shop_id
      join job_services js on js.shop_id = f.shop_id and js.service_id = f.service_id
      join public.jobs j on j.id = js.job_id and j.shop_id = js.shop_id
      left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
      -- 10:00 shop-local on the local date of completed_at + offset_days
      cross join lateral (
        select public.comms_followup_due_at(j.completed_at, make_interval(days => f.offset_days), interval '0',
                                            true, s.timezone, 1) as due_at) d
     where f.enabled
       and j.status = 'completed' and j.completed_at is not null
       and d.due_at <= v_now
       and d.due_at > v_now - interval '24 hours'
       and not exists (select 1 from public.job_automation_log l
                        where l.job_id = j.id and l.key = 'service_followup' and l.service_followup_id = f.id)
       -- the customer already has the service again: any open job (requested,
       -- scheduled or under way, whatever its dates — a request logged while
       -- this job was being worked is still a request), or a job completed
       -- after this one
       and not exists (
         select 1
           from public.jobs j2
           join public.job_line_items l2 on l2.job_id = j2.id and l2.shop_id = j2.shop_id
          where j2.shop_id = j.shop_id and j2.customer_id = j.customer_id and j2.id <> j.id
            and (j2.status in ('requested', 'scheduled', 'confirmed', 'en_route', 'in_progress')
                 or (j2.status = 'completed'
                     and coalesce(j2.completed_at, j2.scheduled_start, j2.created_at) > j.completed_at))
            and (l2.service_id = f.service_id
                 or exists (select 1 from public.package_items pi
                             where pi.shop_id = l2.shop_id and pi.package_id = l2.service_id
                               and pi.service_id = f.service_id)))
     order by d.due_at, j.id, f.sort, f.id
  loop
    insert into public.job_automation_log (shop_id, job_id, customer_id, key, service_followup_id, due_at,
                                           processed_at, outcome)
    values (v_due.shop_id, v_due.job_id, v_due.customer_id, 'service_followup', v_due.followup_id, v_due.due_at,
            v_now, 'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;

    v_msg := public.enqueue_message_core(v_due.shop_id, v_due.customer_id, 'service_followup', v_due.channel,
                                         v_due.subject, v_due.body, v_due.job_id,
                                         jsonb_build_object('rebook_link', v_due.rebook_link),
                                         public.comms_marketing_send_after(v_now, v_due.timezone));
    if v_msg is not null then
      update public.job_automation_log l set outcome = 'queued', message_ids = array[v_msg] where l.id = v_log_id;
      v_total := v_total + 1;
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;

-- ---------------------------------------------------------------------------
-- enqueue_due_automations (replaced; service_role / cron). Returns the
-- number of messages queued plus task reminders created.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_due_automations(p_now timestamptz default now()) returns integer
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
  v_send_after timestamptz;
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
    with tpl as (
      select t.shop_id, t.key, max(t.offset_minutes) as offset_minutes,
             max(t.reminder_offsets_minutes) as offsets    -- shared by every channel of the key
        from public.message_templates t
       where t.enabled and t.key in ('appointment_reminder', 'review_request', 'follow_up')
       group by t.shop_id, t.key
    ), reminder_offsets as (
      -- ascending: prev_offset = the reminder before this one, next_offset = the one after it
      select o.shop_id, x.off, o.offsets is not null as multi,
             lag(x.off) over (partition by o.shop_id order by x.off) as prev_offset,
             lead(x.off) over (partition by o.shop_id order by x.off) as next_offset
        from tpl o
        cross join lateral unnest(coalesce(o.offsets, array[o.offset_minutes])) as x(off)
       where o.key = 'appointment_reminder'
    ), reminders as (
      select j.shop_id, j.id as job_id, j.customer_id, 'appointment_reminder'::public.message_template_key as key,
             j.scheduled_start as scheduled_for, j.scheduled_start + make_interval(mins => r.off) as due_at,
             r.off as reminder_offset, r.prev_offset, r.next_offset, r.multi
        from reminder_offsets r
        join public.jobs j on j.shop_id = r.shop_id
       where j.status in ('scheduled', 'confirmed')
         and not exists (select 1 from public.job_automation_log l
                          where l.job_id = j.id and l.key = 'appointment_reminder'
                            and l.scheduled_for = j.scheduled_start and l.customer_id = j.customer_id
                            and public.comms_reminder_log_covers(l.reminder_offset_minutes, l.processed_at, r.off,
                                                                 j.scheduled_start + make_interval(mins => r.off), r.multi))
         and j.scheduled_start + make_interval(mins => r.off) <= v_now
         -- stale only 24 h after it could first have been sent
         and greatest(j.scheduled_start + make_interval(mins => r.off), j.appointment_set_at) > v_stale
         and v_now < j.scheduled_start + case when r.off = 0 then interval '15 minutes'
                                              else interval '0 minutes' end
    )
    select r.shop_id, r.job_id, r.customer_id, r.key, r.scheduled_for, r.due_at, r.reminder_offset,
           r.prev_offset, r.next_offset, r.multi,
           -- several offsets due at once: only the one nearest the appointment is sent
           row_number() over (partition by r.job_id order by r.reminder_offset desc) = 1 as latest
      from reminders r
    union all
    -- review requests and follow-ups
    select j.shop_id, j.id, j.customer_id, o.key, null::timestamptz,
           j.completed_at + make_interval(mins => o.offset_minutes), null::integer, null::integer, null::integer,
           false, true
      from tpl o
      join public.shops s on s.id = o.shop_id
      join public.jobs j on j.shop_id = o.shop_id
     where o.key in ('review_request', 'follow_up')
       and (o.key <> 'review_request' or (s.review_url is not null and btrim(s.review_url) <> ''))
       and j.status = 'completed'
       and (o.key <> 'review_request' or j.review_requested_at is null)
       and j.completed_at is not null
       and j.completed_at <= v_now - make_interval(mins => o.offset_minutes)
       and j.completed_at > v_stale - make_interval(mins => o.offset_minutes)
    order by 6, 2, 4, 7
  loop
    insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, reminder_offset_minutes,
                                           due_at, processed_at, outcome)
    values (v_due.shop_id, v_due.job_id, v_due.customer_id, v_due.key, v_due.scheduled_for,
            case when v_due.multi then v_due.reminder_offset end,   -- a single reminder is logged as before P-4
            v_due.due_at, v_now, 'skipped')
    on conflict do nothing
    returning id into v_log_id;
    continue when v_log_id is null;          -- already processed (this or another run)
    if not v_due.latest then                 -- superseded by a reminder nearer the appointment
      v_log_id := null;
      continue;
    end if;

    v_ids := '{}';
    -- promotional (follow_up): only between 08:00 and 21:00 shop-local, else
    -- held until the next 10:00 there; transactional keys go out now
    v_send_after := v_now;
    if public.comms_is_marketing_key(v_due.key) then
      select public.comms_marketing_send_after(v_now, s.timezone) into v_send_after
        from public.shops s where s.id = v_due.shop_id;
      v_send_after := coalesce(v_send_after, v_now);
    end if;
    foreach v_ch in array enum_range(null::public.message_channel) loop
      -- a job moved to another customer: an address that already got this
      -- appointment time's reminder (at this offset, as a former customer's
      -- copy) is not reminded twice
      continue when v_due.key = 'appointment_reminder' and exists (
        select 1
          from public.job_automation_log l
          join public.messages m on m.id = any (l.message_ids) and m.shop_id = l.shop_id
          join public.customers c on c.id = v_due.customer_id and c.shop_id = v_due.shop_id
         where l.job_id = v_due.job_id and l.key = 'appointment_reminder'
           and l.scheduled_for = v_due.scheduled_for and l.customer_id <> v_due.customer_id
           and public.comms_reminder_log_covers(l.reminder_offset_minutes, l.processed_at, v_due.reminder_offset,
                                                v_due.due_at, v_due.multi)
           and m.channel = v_ch and m.status in ('queued', 'sending', 'sent', 'delivered')
           and public.comms_address_key(m.channel, m.to_address)
               = public.comms_address_key(v_ch, case v_ch when 'sms' then c.phone else c.email::text end));
      -- staff already sent this job's message on the channel by hand
      -- (enqueue_template_message; not failed / withdrawn): not sent twice.
      -- A reminder counts only when it announces the job's current
      -- appointment for this customer: still queued (re-rendered on every
      -- reschedule) to go out BEFORE the appointment starts, or created
      -- since the job got its current time — and, with several reminder
      -- offsets, only for the offset whose window it went out in (a
      -- reminder a week ahead does not stand in for the one a day before). A queued one scheduled for the start or
      -- later would be withdrawn at the claim and remind nobody, so it does
      -- not stand in for this reminder. Reminders the automation queued are
      -- tracked by their log rows instead.
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
                    -- several offsets: only a reminder that went out in this offset's
                    -- window [its due time, the next offset's due time) stands in for it
                    and (v_due.prev_offset is null
                         or greatest(m.created_at, m.send_after)
                              >= j.scheduled_start + make_interval(mins => v_due.reminder_offset))
                    and (v_due.next_offset is null
                         or greatest(m.created_at, m.send_after)
                              < j.scheduled_start + make_interval(mins => v_due.next_offset))
                    and not exists (select 1 from public.job_automation_log l
                                     where l.shop_id = v_due.shop_id and l.job_id = v_due.job_id
                                       and l.key = 'appointment_reminder' and m.id = any (l.message_ids)))));
      v_msg := public.enqueue_customer_template(v_due.shop_id, v_due.customer_id, v_due.key, v_ch,
                                                v_due.job_id, null, v_send_after, null);
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

  v_total := v_total + public.enqueue_document_followups(v_now);
  v_total := v_total + public.enqueue_service_followups(v_now);
  v_total := v_total + public.enqueue_task_reminders(v_now);
  return v_total;
end
$$;

-- ---------------------------------------------------------------------------
-- A reminder still queued when its appointment moves now describes the new
-- time (jobs_comms_sync_queued re-renders it), so its log row follows the
-- appointment — for the SAME offset; if the new time was already reminded
-- at that offset (or the job is no longer scheduled), the queued copy is a
-- duplicate and is withdrawn. Reminders already handed to the sender stay
-- logged for the time they announced, so the new time gets its own.
-- (replaced: per-offset rows)
-- ---------------------------------------------------------------------------
create or replace function public.jobs_comms_reminder_log_follow() returns trigger
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
     order by l.created_at, l.id
     for update
  loop
    v_new := null;
    if new.scheduled_start is not null then
      select d.* into v_new from public.job_automation_log d
       where d.job_id = new.id and d.key = 'appointment_reminder' and d.scheduled_for = new.scheduled_start
         and d.customer_id = v_log.customer_id
         and d.reminder_offset_minutes is not distinct from v_log.reminder_offset_minutes
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.service_followups_limit() from public, anon, authenticated;

revoke execute on function public.comms_reminder_log_covers(integer, timestamptz, integer, timestamptz, boolean) from public, anon;
grant execute on function public.comms_reminder_log_covers(integer, timestamptz, integer, timestamptz, boolean)
  to authenticated, service_role;

revoke execute on function
  public.comms_marketing_send_after(timestamptz, text),
  public.enqueue_service_followups(timestamptz)
from public, anon, authenticated;
grant execute on function
  public.comms_marketing_send_after(timestamptz, text),
  public.enqueue_service_followups(timestamptz)
to service_role;
