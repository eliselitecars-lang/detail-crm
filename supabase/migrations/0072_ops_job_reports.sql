-- ============================================================================
-- 0072 — Customer-facing job report and remote inspection sign-off (P-8).
--
-- A job report (/r/<token>) shows the customer the job's photos of the
-- chosen kinds that staff marked customer_visible, its inspections (when
-- included) and its customer-visible documents (P-25), and lets the customer
-- sign off a pre-inspection remotely. Its token is its OWN credential:
-- jobs.public_token is never used here (it grants cancel rights).
--
--   publish_job_report(job, ...)         manager+, or a technician assigned
--                                        to the job when
--                                        shops.techs_can_share_reports;
--                                        creates or updates the job's live
--                                        report and optionally texts/emails
--                                        the link (template 'job_report',
--                                        {{report_link}}; a missing or
--                                        disabled template is not an error).
--   revoke_job_report(report)            manager+; the link stops working.
--
-- The link belongs to the job's customer: when a job moves to another
-- customer (jobs.customer_id changes outside a merge, 0074) its live report
-- is revoked, exactly like revoke_job_report. A revoked report's queued
-- 'job_report' messages are withdrawn and its signature folder is queued
-- for the purge; a job_report message that comes back for a retry is
-- withdrawn unless the report it announced is still live. Staff publish
-- again for the new customer (new token).
--   set_job_photo_visibility(ids, bool)  staff on the job (can_work_job).
--   public_get_job_report(token)         anon + authenticated; curated JSON
--                                        (no VIN, plate, phone, internal
--                                        notes, inspection notes or storage
--                                        paths); stamps first_viewed_at when
--                                        the reader is not staff of the shop.
--   public_ack_inspection(token, ...)    anon + authenticated; the customer
--                                        signs an unsigned pre-inspection
--                                        with an image uploaded to
--                                        signatures/<shop>/reports/<token>/.
--   job_report_media(token)              service_role (public-media edge
--                                        function): the objects the report
--                                        may show, for short-lived signed URLs.
--
-- Unknown or revoked tokens raise PT404 (HTTP 404) in the public RPCs.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- inspections.signed_remotely is server-set: direct writes never set it, and
-- removing a signature clears it (the only way to change a signed inspection
-- through the API, 0022).
-- ---------------------------------------------------------------------------
create function public.inspections_ops_remote_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    new.signed_remotely := case when tg_op = 'INSERT' then false else old.signed_remotely end;
  end if;
  if new.signed_at is null then
    new.signed_remotely := false;
  end if;
  return new;
end
$$;

create trigger inspections_70_remote_guard before insert or update on public.inspections
  for each row execute function public.inspections_ops_remote_guard();

-- ---------------------------------------------------------------------------
-- Curated report JSON (internal).
-- ---------------------------------------------------------------------------
create function public.job_report_public_json(p_report_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', jsonb_build_object(
      'name', s.name,
      'logo_path', s.logo_path,
      'brand_color', s.brand_color,
      'phone', s.phone,
      'email', s.email,
      'review_url', s.review_url),
    'job', jsonb_build_object(
      'number', j.number,
      'status', j.status,
      'completed_at', j.completed_at,
      'local_date', (coalesce(j.completed_at, j.scheduled_start, j.created_at) at time zone s.timezone)::date),
    'vehicle', case when v.id is null then null else jsonb_build_object(
      'year', v.year, 'make', v.make, 'model', v.model, 'color', v.color) end,
    'services', coalesce((
      select jsonb_agg(li.name order by li.sort, li.created_at, li.id)
        from public.job_line_items li
       where li.job_id = j.id and li.shop_id = j.shop_id and li.fee_id is null), '[]'::jsonb),
    'message', r.message,
    'published_at', r.published_at,
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'kind', p.kind,
               'caption', p.caption,
               'media_type', p.media_type,
               'duration_seconds', p.duration_seconds,
               'has_poster', p.poster_path is not null,
               'created_at', p.created_at) order by p.created_at, p.id)
        from public.job_photos p
       where p.job_id = j.id and p.shop_id = j.shop_id
         and p.customer_visible and p.kind = any (r.photo_kinds)), '[]'::jsonb),
    'inspections', case when r.include_inspections then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id,
               'kind', i.kind,
               'mileage', i.mileage,
               'fuel_level', i.fuel_level,
               'marks', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', m.id,
                          'view', m.view,
                          'x', m.x,
                          'y', m.y,
                          'damage', m.damage,
                          'note', m.note,
                          'has_photo', m.photo_path is not null) order by m.created_at, m.id)
                   from public.inspection_marks m
                  where m.inspection_id = i.id and m.shop_id = i.shop_id), '[]'::jsonb),
               'signed_at', i.signed_at,
               'signed_by_name', i.signed_by_name,
               'signed_remotely', i.signed_remotely,
               'can_acknowledge', i.kind = 'pre' and i.signed_at is null
                                  and j.status not in ('cancelled', 'no_show'))
             order by i.kind, i.created_at, i.id)
        from public.inspections i
       where i.job_id = j.id and i.shop_id = j.shop_id), '[]'::jsonb)
      else '[]'::jsonb end,
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id,
               'file_name', d.file_name,
               'content_type', d.content_type,
               'size_bytes', d.size_bytes) order by d.created_at, d.id)
        from public.documents d
       where d.job_id = j.id and d.shop_id = j.shop_id and d.customer_visible), '[]'::jsonb),
    'signature_upload_prefix',
      case when r.include_inspections and j.status not in ('cancelled', 'no_show')
                and exists (select 1 from public.inspections i
                             where i.job_id = j.id and i.shop_id = j.shop_id and i.kind = 'pre' and i.signed_at is null)
           then r.shop_id::text || '/reports/' || r.token::text || '/' end)
  from public.job_reports r
  join public.shops s on s.id = r.shop_id
  join public.jobs j on j.id = r.job_id and j.shop_id = r.shop_id
  left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
  where r.id = p_report_id
$$;

-- ---------------------------------------------------------------------------
-- publish_job_report — create or update the job's live report; optionally
-- queue the 'job_report' message on every enabled channel (or p_channel).
-- Returns {report_id, token, url, queued}; url is null while the platform
-- has no app_base_url (and then nothing is sent).
-- ---------------------------------------------------------------------------
create function public.publish_job_report(
  p_job_id               uuid,
  p_include_inspections  boolean default true,
  p_photo_kinds          public.job_photo_kind[] default '{before,after}',
  p_message              text default null,
  p_send                 boolean default false,
  p_channel              public.message_channel default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job     public.jobs;
  v_report  public.job_reports;
  v_kinds   public.job_photo_kind[];
  v_msg     text := nullif(btrim(p_message), '');
  v_url     text;
  v_ch      public.message_channel;
  v_queued  boolean := false;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found or not public.is_shop_member(v_job.shop_id) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not (public.is_shop_manager(v_job.shop_id)
          or (public.can_work_job(v_job.shop_id, v_job.id)
              and exists (select 1 from public.shops s where s.id = v_job.shop_id and s.techs_can_share_reports))) then
    raise exception 'only managers, or technicians on the job when the shop allows it, can share job reports'
      using errcode = '42501';
  end if;
  if p_include_inspections is null or p_send is null then
    raise exception 'include_inspections and send are required' using errcode = '22023';
  end if;
  if p_photo_kinds is null or array_position(p_photo_kinds, null) is not null then
    raise exception 'photo_kinds must be a list of photo kinds' using errcode = '22023';
  end if;
  if char_length(v_msg) > 2000 then
    raise exception 'the message is limited to 2000 characters' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct k order by k), '{}') into v_kinds from unnest(p_photo_kinds) as k;

  -- one live report per job: publish again = update it (token unchanged)
  insert into public.job_reports as r (shop_id, job_id, include_inspections, photo_kinds, message, published_by)
  values (v_job.shop_id, v_job.id, p_include_inspections, v_kinds, v_msg, auth.uid())
  on conflict (job_id) where revoked_at is null do update
    set include_inspections = excluded.include_inspections,
        photo_kinds = excluded.photo_kinds,
        message = excluded.message,
        published_at = now(),
        published_by = excluded.published_by
  returning * into v_report;

  v_url := public.app_url('/r/' || v_report.token::text);
  if p_send and v_url is not null then
    foreach v_ch in array case when p_channel is null then array['sms', 'email']::public.message_channel[]
                               else array[p_channel] end loop
      if public.enqueue_customer_template(v_job.shop_id, v_job.customer_id, 'job_report', v_ch, v_job.id,
                                          jsonb_build_object('report_link', v_url), null, auth.uid()) is not null then
        v_queued := true;
      end if;
    end loop;
  end if;

  return jsonb_build_object('report_id', v_report.id, 'token', v_report.token, 'url', v_url, 'queued', v_queued);
end
$$;

-- ---------------------------------------------------------------------------
-- revoke_job_report — manager+. The link stops working; files a customer
-- uploaded to the report's signature folder but never submitted are queued
-- for the storage purge (a signed inspection keeps its image: in use).
-- ---------------------------------------------------------------------------
create function public.revoke_job_report(p_report_id uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_r public.job_reports;
begin
  select * into v_r from public.job_reports r where r.id = p_report_id;
  if not found or not public.is_shop_member(v_r.shop_id) then
    raise exception 'job report not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_r.shop_id) then
    raise exception 'only owners, admins and managers can revoke job reports' using errcode = '42501';
  end if;
  -- job_reports_ops_revoked withdraws its messages and queues the purge
  update public.job_reports r set revoked_at = now() where r.id = v_r.id and r.revoked_at is null;
end
$$;

-- A report is revoked (revoke_job_report, or its job moved to another
-- customer): its link is dead, so the 'job_report' messages still queued for
-- the job (all of them announce this report: a job has one live report and
-- earlier ones were withdrawn when they were revoked) are withdrawn, and
-- files uploaded to its signature folder but never submitted are queued for
-- the storage purge (a signed inspection keeps its image: in use).
create function public.job_reports_ops_revoked() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.messages m
     set status = 'cancelled', error = 'the job report link was withdrawn'
   where m.shop_id = new.shop_id and m.job_id = new.job_id and m.direction = 'outbound'
     and m.status = 'queued' and m.template_key::text = 'job_report';
  perform public.queue_storage_purge(new.shop_id, 'signatures',
                                     new.shop_id::text || '/reports/' || new.token::text || '/', true, 'report_revoked');
  return null;
end
$$;

create trigger job_reports_70_ops_revoked after update of revoked_at on public.job_reports
  for each row when (old.revoked_at is null and new.revoked_at is not null)
  execute function public.job_reports_ops_revoked();

-- The report link is the job's customer's credential (it shows the job's
-- vehicle, photos, documents and lets the holder sign off inspections). When
-- the job moves to another customer the live report is revoked, so the
-- previous customer's link stops working (forms rotate their token the same
-- way, 0023). A customer merge keeps it: the survivor is the same person
-- (detailcrm.customer_merge, 0074; a client write never gets the bypass).
create function public.jobs_ops_report_customer_change() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
    return null;
  end if;
  update public.job_reports r set revoked_at = now()
   where r.shop_id = new.shop_id and r.job_id = new.id and r.revoked_at is null;
  return null;
end
$$;

create trigger jobs_zz_ops_report_customer_change after update of customer_id on public.jobs
  for each row when (old.customer_id is distinct from new.customer_id)
  execute function public.jobs_ops_report_customer_change();

-- A 'job_report' message that was handed to the sender and comes back for a
-- retry (sending -> queued, mark_message_result) is withdrawn unless the
-- report it announced is still live: the job's live report must predate the
-- message (a report published after it has another link). Without a job
-- (deleted) there is no report either.
create function public.messages_ops_report_retry() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.status = 'queued' and new.direction = 'outbound' and new.template_key::text = 'job_report'
     and (new.job_id is null
          or not exists (select 1 from public.job_reports r
                          where r.shop_id = new.shop_id and r.job_id = new.job_id and r.revoked_at is null
                            and r.created_at <= new.created_at)) then
    new.status := 'cancelled';
    new.error := 'the job report link was withdrawn';
    new.claimed_at := null;
  end if;
  return new;
end
$$;

create trigger messages_70_ops_report_retry before update of status on public.messages
  for each row when (old.status = 'sending' and new.status = 'queued')
  execute function public.messages_ops_report_retry();

-- A report removed with its job (or shop): its signature folder goes too
-- (rows removed by a shop deletion are covered by the shop's request).
create function public.job_reports_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'signatures',
                                       old.shop_id::text || '/reports/' || old.token::text || '/', true, 'job_deleted');
  end if;
  return null;
end
$$;

create trigger job_reports_zz_ops_queue_storage_purge after delete on public.job_reports
  for each row execute function public.job_reports_queue_storage_purge();

-- ---------------------------------------------------------------------------
-- set_job_photo_visibility — staff on each photo's job. 1..200 ids.
-- Returns the number of photos updated.
-- ---------------------------------------------------------------------------
create function public.set_job_photo_visibility(p_photo_ids uuid[], p_visible boolean) returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ids   uuid[];
  v_count integer;
  r       record;
begin
  if p_visible is null then
    raise exception 'visible is required' using errcode = '22023';
  end if;
  if p_photo_ids is null or cardinality(p_photo_ids) not between 1 and 200
     or array_position(p_photo_ids, null) is not null then
    raise exception 'pass 1 to 200 photo ids' using errcode = '22023';
  end if;
  select array_agg(distinct x) into v_ids from unnest(p_photo_ids) as x;
  for r in
    select x.id, p.shop_id, p.job_id
      from unnest(v_ids) as x(id)
      left join public.job_photos p on p.id = x.id
  loop
    if r.shop_id is null or not public.is_shop_member(r.shop_id) then
      raise exception 'photo not found' using errcode = 'P0002';
    end if;
    if not public.can_work_job(r.shop_id, r.job_id) then
      raise exception 'only managers and staff assigned to the job can change what the customer sees'
        using errcode = '42501';
    end if;
  end loop;
  update public.job_photos p set customer_visible = p_visible where p.id = any (v_ids);
  get diagnostics v_count = row_count;
  return v_count;
end
$$;

-- ---------------------------------------------------------------------------
-- public_get_job_report — the report page. Stamps first_viewed_at when the
-- reader is not a member of the shop (staff previews do not count).
-- ---------------------------------------------------------------------------
create function public.public_get_job_report(p_token uuid) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_r public.job_reports;
begin
  select * into v_r from public.job_reports r where r.token = p_token and r.revoked_at is null;
  if not found then
    raise exception 'job report not found' using errcode = 'PT404';
  end if;
  if v_r.first_viewed_at is null and not public.is_shop_member(v_r.shop_id) then
    update public.job_reports r set first_viewed_at = now() where r.id = v_r.id and r.first_viewed_at is null;
  end if;
  return public.job_report_public_json(v_r.id);
end
$$;

-- ---------------------------------------------------------------------------
-- public_ack_inspection — the customer signs an unsigned pre-inspection of
-- the report's job. The signature image must already be uploaded directly
-- inside signatures/<shop_id>/reports/<token>/ (storage policy below). The
-- inspection is then signed and locked exactly like an on-device signature
-- (0022); managers of the shop are notified. Returns the report JSON.
-- ---------------------------------------------------------------------------
create function public.public_ack_inspection(p_token uuid, p_inspection_id uuid, p_signer_name text,
                                             p_signature_path text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_r       public.job_reports;
  v_job     public.jobs;
  v_ins     public.inspections;
  v_name    text := nullif(btrim(p_signer_name), '');
  v_path    text := nullif(btrim(p_signature_path), '');
  v_prefix  text;
begin
  select * into v_r from public.job_reports r where r.token = p_token and r.revoked_at is null;
  if not found then
    raise exception 'job report not found' using errcode = 'PT404';
  end if;
  -- job row first, then the inspection: the lock order of a customer move
  select * into v_job from public.jobs j where j.id = v_r.job_id and j.shop_id = v_r.shop_id for share;
  select * into v_r from public.job_reports r where r.id = v_r.id and r.revoked_at is null;
  if not found then
    raise exception 'job report not found' using errcode = 'PT404';
  end if;
  -- staff below manager collect signatures on their device, never as the
  -- customer through the customer's link
  if auth.uid() is not null and public.is_shop_member(v_r.shop_id) and not public.is_shop_manager(v_r.shop_id)
     and not exists (select 1 from public.customers c
                      where c.id = v_job.customer_id and c.shop_id = v_job.shop_id and c.portal_user_id = auth.uid()) then
    raise exception 'staff collect signatures on their device, not through the customer''s link' using errcode = '42501';
  end if;

  select * into v_ins from public.inspections i
   where i.id = p_inspection_id and i.shop_id = v_r.shop_id and i.job_id = v_r.job_id
   for update;
  if not found or not v_r.include_inspections then
    raise exception 'this inspection is not part of the job report' using errcode = '22023';
  end if;
  if v_ins.kind <> 'pre' then
    raise exception 'only the pre-service inspection can be acknowledged' using errcode = '22023';
  end if;
  if v_ins.signed_at is not null then
    raise exception 'this inspection has already been signed' using errcode = '22023';
  end if;
  if v_job.status in ('cancelled', 'no_show') then
    raise exception 'this appointment was cancelled' using errcode = '22023';
  end if;
  if v_name is null or char_length(v_name) > 200 then
    raise exception 'signer name is required (max 200 characters)' using errcode = '22023';
  end if;
  v_prefix := v_r.shop_id::text || '/reports/' || v_r.token::text || '/';
  if v_path is null
     or not public.is_safe_storage_path(v_path)
     or left(v_path, char_length(v_prefix)) <> v_prefix
     or cardinality(string_to_array(v_path, '/')) <> 4 then
    raise exception 'the signature must be uploaded directly under %', v_prefix using errcode = '22023';
  end if;
  if not public.storage_object_exists('signatures', v_path) then
    raise exception 'upload the signature image before signing' using errcode = '22023';
  end if;

  update public.inspections i
     set customer_signature_path = v_path,
         signed_by_name = v_name,
         signed_at = now(),
         signed_remotely = true
   where i.id = v_ins.id;

  perform public.notify_shop_staff(v_r.shop_id, array['owner', 'admin', 'manager']::public.shop_role[],
                                   'inspection_acknowledged',
                                   format('Inspection signed off for job #%s', v_job.number),
                                   format('%s signed the pre-service inspection from the job report.', v_name),
                                   v_job.id, null, v_job.customer_id);
  return public.job_report_public_json(v_r.id);
end
$$;

-- Storage policy helper: may the caller upload this signatures object for a
-- job report? Only "<shop_id>/reports/<token>/<file>" of a live report that
-- includes inspections and whose (not void) job has an unsigned
-- pre-inspection.
create function public.public_report_signature_upload_allowed(p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_safe_storage_path(p_name)
     and cardinality(string_to_array(p_name, '/')) = 4
     and split_part(p_name, '/', 2) = 'reports'
     and exists (
       select 1
       from public.job_reports r
       join public.jobs j on j.id = r.job_id and j.shop_id = r.shop_id
       where r.shop_id = public.storage_path_uuid(p_name, 1)
         and r.token = public.storage_path_uuid(p_name, 3)
         and r.revoked_at is null
         and r.include_inspections
         and j.status not in ('cancelled', 'no_show')
         and exists (select 1 from public.inspections i
                      where i.job_id = r.job_id and i.shop_id = r.shop_id and i.kind = 'pre' and i.signed_at is null))
$$;

drop policy if exists ops_signatures_insert_public_report on storage.objects;
create policy ops_signatures_insert_public_report on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'signatures' and public.public_report_signature_upload_allowed(name));

-- ---------------------------------------------------------------------------
-- can_read_signature_object (0025) + the report sign-off folder
-- <shop_id>/reports/<token>/: readable by staff who may see the report's
-- token (managers+, and technicians on the job when the shop lets them share
-- reports), since the folder name is the report credential.
-- ---------------------------------------------------------------------------
create or replace function public.can_read_signature_object(p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_shop_manager(s.shop_id)
      or (public.is_shop_member(s.shop_id)
          and (exists (select 1 from public.form_submissions fs
                       where fs.shop_id = s.shop_id and fs.signature_path = p_name
                         and fs.signed_at is not null
                         and public.can_work_job(fs.shop_id, fs.job_id))
               or exists (select 1 from public.inspections i
                          where i.shop_id = s.shop_id and i.customer_signature_path = p_name
                            and public.can_work_job(i.shop_id, i.job_id))
               or (split_part(p_name, '/', 2) = 'reports'
                   and exists (select 1
                               from public.job_reports r
                               join public.shops sh on sh.id = r.shop_id
                               where r.shop_id = s.shop_id
                                 and r.token = public.storage_path_uuid(p_name, 3)
                                 and sh.techs_can_share_reports
                                 and public.can_work_job(r.shop_id, r.job_id)))))
  from (select public.storage_path_uuid(p_name, 1) as shop_id) s
$$;

-- ---------------------------------------------------------------------------
-- job_report_media — service_role (public-media edge function): the stored
-- objects the live report may show, for short-lived signed URLs. ref_id is
-- the photo, mark or document id of the report JSON. No rows for an unknown
-- or revoked token.
--   photo       job-photos  visible images of the report's kinds
--   video       job-media   visible videos of the report's kinds
--   poster      job-photos  poster frame of such a video (ref_id = photo id)
--   mark_photo  job-photos  damage-mark photos of included inspections
--   document    documents   customer-visible documents of the job
-- ---------------------------------------------------------------------------
create function public.job_report_media(p_token uuid)
returns table (ref_id uuid, kind text, bucket text, path text)
language sql stable security definer
set search_path = ''
as $$
  with r as (
    select * from public.job_reports r where r.token = p_token and r.revoked_at is null
  )
  select p.id, case p.media_type when 'video' then 'video' else 'photo' end, p.bucket, p.storage_path
    from r join public.job_photos p on p.job_id = r.job_id and p.shop_id = r.shop_id
   where p.customer_visible and p.kind = any (r.photo_kinds)
  union all
  select p.id, 'poster', 'job-photos', p.poster_path
    from r join public.job_photos p on p.job_id = r.job_id and p.shop_id = r.shop_id
   where p.customer_visible and p.kind = any (r.photo_kinds) and p.poster_path is not null
  union all
  select m.id, 'mark_photo', 'job-photos', m.photo_path
    from r
    join public.inspections i on i.job_id = r.job_id and i.shop_id = r.shop_id
    join public.inspection_marks m on m.inspection_id = i.id and m.shop_id = i.shop_id
   where r.include_inspections and m.photo_path is not null
  union all
  select d.id, 'document', 'documents', d.storage_path
    from r join public.documents d on d.job_id = r.job_id and d.shop_id = r.shop_id
   where d.customer_visible
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.inspections_ops_remote_guard(),
  public.job_reports_queue_storage_purge(),
  public.job_reports_ops_revoked(),
  public.jobs_ops_report_customer_change(),
  public.messages_ops_report_retry()
from public, anon, authenticated;

revoke execute on function
  public.job_report_public_json(uuid),
  public.job_report_media(uuid)
from public, anon, authenticated;
grant execute on function
  public.job_report_public_json(uuid),
  public.job_report_media(uuid)
to service_role;

revoke execute on function
  public.publish_job_report(uuid, boolean, public.job_photo_kind[], text, boolean, public.message_channel),
  public.revoke_job_report(uuid),
  public.set_job_photo_visibility(uuid[], boolean)
from public, anon;
grant execute on function
  public.publish_job_report(uuid, boolean, public.job_photo_kind[], text, boolean, public.message_channel),
  public.revoke_job_report(uuid),
  public.set_job_photo_visibility(uuid[], boolean)
to authenticated, service_role;

revoke execute on function
  public.public_get_job_report(uuid),
  public.public_ack_inspection(uuid, uuid, text, text),
  public.public_report_signature_upload_allowed(text)
from public;
grant execute on function
  public.public_get_job_report(uuid),
  public.public_ack_inspection(uuid, uuid, text, text),
  public.public_report_signature_upload_allowed(text)
to anon, authenticated, service_role;

