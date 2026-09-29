-- ============================================================================
-- 0129 — Marketing follow-ups held back for a missing postal address are
-- logged as such.
--
-- Marketing email needs the shop's postal address (0119): without one,
-- messages_02_marketing_postal_address drops the insert and the queueing
-- code returns null. enqueue_due_automations (follow_up) and
-- enqueue_service_followups (0102 bodies) log each due job before
-- enqueueing ('skipped') and flip the row to 'queued' only when a message
-- id comes back — so a follow-up lost to the missing address looked exactly
-- like one skipped for any other reason (no consent, template off, …), and
-- the log row consumed it for good. Nobody could tell the shop why its
-- follow-ups never went out.
--
-- Now:
--   * job_automation_log.outcome may also be 'no_postal_address': nothing
--     was queued for the job, and on the email channel the only thing in the
--     way was the missing address — the customer has an email address,
--     marketing consent (email_opt_in, not opted out or unsuppressed, not
--     archived / erased) and the key's email template is on
--     (comms_marketing_email_needs_address). An SMS sent for the same
--     follow-up makes it 'queued' as before.
--   * These follow-ups are NOT sent late once the address is added (the
--     row still marks the job as processed; promotions days late would
--     surprise customers). Staff see how many were held back: web / iOS
--     count job_automation_log rows with outcome 'no_postal_address'
--     (managers read the log) and show "N follow-ups weren't sent because
--     the shop has no mailing address".
-- ============================================================================

alter table public.job_automation_log
  drop constraint job_automation_log_outcome_check,
  add constraint job_automation_log_outcome_check check (outcome in ('queued', 'skipped', 'no_postal_address'));

comment on column public.job_automation_log.outcome is
  'queued (message_ids holds what was queued), skipped (nothing to send: superseded, no consent, template off, …) or no_postal_address (0129: a marketing email the customer had consented to was held back because the shop has no postal address on file; not sent later).';

create index job_automation_log_shop_no_address_idx on public.job_automation_log (shop_id, processed_at)
  where outcome = 'no_postal_address';

-- ---------------------------------------------------------------------------
-- comms_marketing_email_needs_address — would this marketing email have been
-- queued but for the shop's missing postal address?
-- ---------------------------------------------------------------------------
create function public.comms_marketing_email_needs_address(
  p_shop_id      uuid,
  p_customer_id  uuid,
  p_key          public.message_template_key
) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.comms_is_marketing_key(p_key)
     and public.comms_shop_postal_address(p_shop_id) is null
     and exists (select 1 from public.message_templates t
                  where t.shop_id = p_shop_id and t.key = p_key and t.channel = 'email' and t.enabled)
     and exists (select 1 from public.customers c
                  where c.id = p_customer_id and c.shop_id = p_shop_id
                    and c.email is not null and c.email_opt_in and c.email_opted_out_at is null
                    and c.archived_at is null and c.erased_at is null
                    and not public.comms_is_marketing_suppressed(p_shop_id, 'email', c.email::text))
$$;

comment on function public.comms_marketing_email_needs_address(uuid, uuid, public.message_template_key) is
  'Internal (0129): true when a marketing email of this key to this customer is held back only by the shop''s missing postal address (marketing key, no address on file, the email template on, the customer with an email address and marketing consent).';
revoke execute on function public.comms_marketing_email_needs_address(uuid, uuid, public.message_template_key)
  from public, anon, authenticated;
grant execute on function public.comms_marketing_email_needs_address(uuid, uuid, public.message_template_key) to service_role;

-- ---------------------------------------------------------------------------
-- enqueue_due_automations (0102 body) + the no_postal_address outcome
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
  v_no_addr  boolean;
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
         and public.shop_can_write(t.shop_id)       -- lapsed shops are skipped (0102)
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
    v_no_addr := false;
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
      elsif v_ch = 'email' and public.comms_marketing_email_needs_address(v_due.shop_id, v_due.customer_id, v_due.key) then
        v_no_addr := true;                   -- 0129: held back only by the missing postal address
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
    elsif v_no_addr then
      update public.job_automation_log l set outcome = 'no_postal_address' where l.id = v_log_id;
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
-- enqueue_service_followups (0102 body) + the no_postal_address outcome
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_service_followups(p_now timestamptz default now()) returns integer
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
       and public.shop_can_write(f.shop_id)          -- lapsed shops are skipped (0102)
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
    elsif v_due.channel = 'email'
          and public.comms_marketing_email_needs_address(v_due.shop_id, v_due.customer_id, 'service_followup') then
      -- 0129: held back only by the missing postal address
      update public.job_automation_log l set outcome = 'no_postal_address' where l.id = v_log_id;
    end if;
    v_log_id := null;
  end loop;
  return v_total;
end
$$;
