-- ============================================================================
-- 0025 — Field operations: storage buckets and storage.objects policies
-- (SPEC §4.6), and the purge queue that removes the files of deleted jobs
-- and shops.
--
--   bucket        visibility  limit   types                         path
--   job-photos    private     20 MB   jpeg, png, webp, heic, heif   <shop_id>/<job_id>/<file>
--   signatures    private      2 MB   png, jpeg, webp               <shop_id>/...
--   shop-assets   public       5 MB   png, jpeg, webp               <shop_id>/...
--
-- Policies (the first folder is always a shop the caller belongs to):
--   job-photos   read: managers+ everything under the shop folder (also
--                the folders of deleted jobs, so they can clean up);
--                technicians the folders of jobs they are assigned to
--                (public.can_work_job); the uploader keeps reading their own
--                objects while still a member;
--                upload: managers+, or technicians assigned to the job in
--                folder 2; delete: managers+ or the uploader while still a
--                member; overwrite: managers+ or the uploader on the job.
--   signatures   read: managers+; other members only the signatures of
--                forms/inspections on jobs they work (public.can_work_job,
--                via the referencing row, i.e. once signed) and objects
--                they uploaded themselves while still a member —
--                signature images are customer PII and a form folder name
--                is the form's public token (the customer's credential,
--                0023), so a technician must not be able to list the shop's
--                folder nor see a customer's pending upload in a form's
--                token folder;
--                upload: any active member of the shop; public form
--                signers (anon or signed-in, e.g. portal clients) may upload
--                only to <shop_id>/forms/<token>/<file> of an unsigned form;
--                overwrite/delete: managers+ (signatures are evidence).
--   shop-assets  public bucket: files are read by public URL, which the
--                Storage API serves without consulting these policies; the
--                SELECT policy (listing/search, and the read-back of an
--                upsert) is limited to members of the shop, so nobody can
--                enumerate other shops' ids or unpublished file names;
--                owner/admin upload, overwrite and delete; managers too
--                under <shop_id>/services/ (service images: the catalog is
--                manager-editable). Logos and anything else stay admin-only.
-- Signed evidence is immutable for everyone through the API: a job photo
-- pinned to a mark of a signed inspection, the signature image of a signed
-- inspection and the signature image of a signed form cannot be uploaded
-- (re-created after a delete), overwritten, moved onto, moved away or
-- deleted (public.is_signed_evidence). An inspection cannot be signed while
-- a mark's photo is missing (0022). A manager un-signs the inspection first
-- (0022); signed forms are permanent.
-- Size and MIME limits are enforced by the Storage API from the bucket
-- configuration below.
--
-- Purge queue (public.storage_purge_requests, service-only): deleting rows
-- never deletes files, and the files of a deleted job or shop would be left
-- behind (customer photos and signature images are PII). Deleting
--   * a shop      queues its whole folder <shop_id>/ in all three buckets;
--   * a job       queues its photo folder <shop_id>/<job_id>/ (job-photos);
--   * an inspection or a form submission (directly or through its job)
--                 queues its signature image, and a form its public upload
--                 folder <shop_id>/forms/<token>/ (signatures);
--   * an inspection also queues the photos of its damage marks (job-photos;
--                 the marks go with it by cascade, so each deleted mark
--                 queues its own photo while its inspection is gone and its
--                 job still exists — a deleted job queues its whole folder);
--   * re-tokenizing an unsigned form (its job moved to another customer,
--                 0023) queues the old token's upload folder, which only
--                 the previous customer could have written to;
-- (rows removed by a shop deletion are covered by the shop's request). The
-- Paths are stored and matched in canonical lower-case uuid form: object
-- names are case-sensitive, so storage_path_uuid (0020) accepts only that
-- form and no policy or validator admits an upper-case folder the purge
-- could miss.
-- storage-purge edge function (pg_cron, supabase/setup/cron.sql) claims
-- batches with claim_storage_purge(), removes the objects through the
-- Storage API (which deletes the stored files too; deleting storage.objects
-- rows in SQL would orphan them and is refused by Supabase) and reports
-- with finish_storage_purge(). An object that a live row still references
-- (job photo, mark photo, signature, logo, service image) is never purged.
-- ============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('job-photos',  'job-photos',  false, 20971520,
   array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']),
  ('signatures',  'signatures',  false, 2097152,
   array['image/png', 'image/jpeg', 'image/webp']),
  ('shop-assets', 'shop-assets', true,  5242880,
   array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set name = excluded.name,
      public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Re-runnable: replace this migration's policies if they already exist.
drop policy if exists field_ops_job_photos_select on storage.objects;
drop policy if exists field_ops_job_photos_insert on storage.objects;
drop policy if exists field_ops_job_photos_update on storage.objects;
drop policy if exists field_ops_job_photos_delete on storage.objects;
drop policy if exists field_ops_signatures_select on storage.objects;
drop policy if exists field_ops_signatures_insert_staff on storage.objects;
drop policy if exists field_ops_signatures_insert_public_form on storage.objects;
drop policy if exists field_ops_signatures_update on storage.objects;
drop policy if exists field_ops_signatures_delete on storage.objects;
drop policy if exists field_ops_shop_assets_select on storage.objects;
drop policy if exists field_ops_shop_assets_insert on storage.objects;
drop policy if exists field_ops_shop_assets_update on storage.objects;
drop policy if exists field_ops_shop_assets_delete on storage.objects;

-- ---------------------------------------------------------------------------
-- Policy helpers (SECURITY DEFINER: they read tables the caller may not see;
-- both answer false for objects outside the caller's shops, so they are no
-- oracle for other tenants' paths).
-- ---------------------------------------------------------------------------

-- Is this object the evidence behind a signature? job-photos: the photo of a
-- mark on a signed inspection. signatures: the signature image of an
-- inspection (a path is only set while signed) or of a signed form.
create function public.is_signed_evidence(p_bucket text, p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_shop_member(s.shop_id)
     and case p_bucket
           when 'job-photos' then exists (
             select 1
             from public.inspection_marks m
             join public.inspections i on i.id = m.inspection_id and i.shop_id = m.shop_id
             where m.shop_id = s.shop_id and m.photo_path = p_name and i.signed_at is not null)
           when 'signatures' then
             exists (select 1 from public.inspections i
                     where i.shop_id = s.shop_id and i.customer_signature_path = p_name)
             or exists (select 1 from public.form_submissions fs
                        where fs.shop_id = s.shop_id and fs.signature_path = p_name and fs.signed_at is not null)
           else false
         end
  from (select public.storage_path_uuid(p_name, 1) as shop_id) s
$$;

-- May the caller read this signatures object (besides their own uploads)?
-- Managers+: everything of their shop. Other members: the signature of a
-- form or inspection on a job they work. Not a pending upload in a form's
-- public folder <shop_id>/forms/<token>/: its name carries the form token,
-- which would let a technician sign the form as the customer (0023). Once
-- the form is signed the image is readable through signature_path and the
-- token no longer signs anything.
create function public.can_read_signature_object(p_name text) returns boolean
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
                            and public.can_work_job(i.shop_id, i.job_id))))
  from (select public.storage_path_uuid(p_name, 1) as shop_id) s
$$;

revoke execute on function public.is_signed_evidence(text, text), public.can_read_signature_object(text)
  from public, anon;
grant execute on function public.is_signed_evidence(text, text), public.can_read_signature_object(text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- job-photos
-- ---------------------------------------------------------------------------
create policy field_ops_job_photos_select on storage.objects for select to authenticated
  using (bucket_id = 'job-photos'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1)))));

create policy field_ops_job_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'job-photos'
              and public.is_safe_storage_path(name)
              and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))
              and not public.is_signed_evidence(bucket_id, name));

create policy field_ops_job_photos_update on storage.objects for update to authenticated
  using (bucket_id = 'job-photos'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))))
         and not public.is_signed_evidence(bucket_id, name))
  with check (bucket_id = 'job-photos'
              and public.is_safe_storage_path(name)
              and (public.is_shop_manager(public.storage_path_uuid(name, 1))
                   or ((owner_id = auth.uid()::text or owner = auth.uid())
                       and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))))
              and not public.is_signed_evidence(bucket_id, name));

create policy field_ops_job_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'job-photos'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1))))
         and not public.is_signed_evidence(bucket_id, name));

-- ---------------------------------------------------------------------------
-- signatures
-- ---------------------------------------------------------------------------
create policy field_ops_signatures_select on storage.objects for select to authenticated
  using (bucket_id = 'signatures'
         and (public.can_read_signature_object(name)
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1)))));

create policy field_ops_signatures_insert_staff on storage.objects for insert to authenticated
  with check (bucket_id = 'signatures'
              and public.is_safe_storage_path(name)
              and public.is_shop_member(public.storage_path_uuid(name, 1))
              and not public.is_signed_evidence(bucket_id, name));

create policy field_ops_signatures_insert_public_form on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'signatures' and public.public_form_signature_upload_allowed(name));

create policy field_ops_signatures_update on storage.objects for update to authenticated
  using (bucket_id = 'signatures'
         and public.is_shop_manager(public.storage_path_uuid(name, 1))
         and not public.is_signed_evidence(bucket_id, name))
  with check (bucket_id = 'signatures'
              and public.is_safe_storage_path(name)
              and public.is_shop_manager(public.storage_path_uuid(name, 1))
              and not public.is_signed_evidence(bucket_id, name));

create policy field_ops_signatures_delete on storage.objects for delete to authenticated
  using (bucket_id = 'signatures'
         and public.is_shop_manager(public.storage_path_uuid(name, 1))
         and not public.is_signed_evidence(bucket_id, name));

-- ---------------------------------------------------------------------------
-- shop-assets
-- ---------------------------------------------------------------------------
-- No anon policy: public files are downloaded by URL, not through RLS.
create policy field_ops_shop_assets_select on storage.objects for select to authenticated
  using (bucket_id = 'shop-assets' and public.is_shop_member(public.storage_path_uuid(name, 1)));

create policy field_ops_shop_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'shop-assets'
              and public.is_safe_storage_path(name)
              and (public.is_shop_admin(public.storage_path_uuid(name, 1))
                   or (split_part(name, '/', 2) = 'services' and split_part(name, '/', 3) <> ''
                       and public.is_shop_manager(public.storage_path_uuid(name, 1)))));

create policy field_ops_shop_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'shop-assets'
         and (public.is_shop_admin(public.storage_path_uuid(name, 1))
              or (split_part(name, '/', 2) = 'services' and split_part(name, '/', 3) <> ''
                  and public.is_shop_manager(public.storage_path_uuid(name, 1)))))
  with check (bucket_id = 'shop-assets'
              and public.is_safe_storage_path(name)
              and (public.is_shop_admin(public.storage_path_uuid(name, 1))
                   or (split_part(name, '/', 2) = 'services' and split_part(name, '/', 3) <> ''
                       and public.is_shop_manager(public.storage_path_uuid(name, 1)))));

create policy field_ops_shop_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'shop-assets'
         and (public.is_shop_admin(public.storage_path_uuid(name, 1))
              or (split_part(name, '/', 2) = 'services' and split_part(name, '/', 3) <> ''
                  and public.is_shop_manager(public.storage_path_uuid(name, 1)))));

-- ---------------------------------------------------------------------------
-- Purge queue: files of deleted jobs and shops (see the header).
-- One row per folder (is_prefix: path is "<shop_id>/", "<shop_id>/<job_id>/"
-- or "<shop_id>/forms/<token>/", uuids only, so it holds no LIKE wildcards)
-- or per object name. shop_id is the tenant the files belong to; it has no
-- foreign key because the shop is usually gone by the time the row is read.
-- Service-only: RLS on, no policies, no API grants.
-- ---------------------------------------------------------------------------
create table public.storage_purge_requests (
  id            bigint generated always as identity primary key,
  shop_id       uuid not null,
  bucket_id     text not null check (bucket_id in ('job-photos', 'signatures', 'shop-assets')),
  path          text not null,
  is_prefix     boolean not null,
  reason        text not null check (reason in ('shop_deleted', 'job_deleted', 'inspection_deleted', 'form_deleted',
                                             'form_token_rotated')),
  requested_at  timestamptz not null default now(),
  attempts      integer not null default 0 check (attempts >= 0),
  locked_until  timestamptz,
  last_error    text check (last_error is null or char_length(last_error) <= 2000),
  constraint storage_purge_requests_shop_id_id_key unique (shop_id, id),
  constraint storage_purge_requests_target_key unique (bucket_id, path, is_prefix),
  constraint storage_purge_requests_path_check check (
    case when is_prefix
      then path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/((forms/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?$'
      else public.is_safe_storage_path(path)
    end
    and public.storage_path_uuid(path, 1) = shop_id)
);
create index storage_purge_requests_due_idx on public.storage_purge_requests (locked_until, id);

comment on table public.storage_purge_requests is
  'Storage folders/objects of deleted shops, jobs, inspections and forms, removed by the storage-purge edge function through the Storage API.';

alter table public.storage_purge_requests enable row level security;
revoke all on public.storage_purge_requests from anon, authenticated;
revoke all on sequence public.storage_purge_requests_id_seq from anon, authenticated;

-- Queue one folder or object (idempotent). Callers are the triggers below.
create function public.queue_storage_purge(p_shop_id uuid, p_bucket text, p_path text, p_is_prefix boolean, p_reason text)
returns void
language sql security definer
set search_path = ''
as $$
  insert into public.storage_purge_requests (shop_id, bucket_id, path, is_prefix, reason)
  select p_shop_id, p_bucket, p_path, p_is_prefix, p_reason
   where p_path is not null
     -- a stored path that is not under its own shop's folder is not ours to purge
     and public.storage_path_uuid(p_path, 1) = p_shop_id
     and (p_is_prefix or public.is_safe_storage_path(p_path))
  on conflict (bucket_id, path, is_prefix) do nothing
$$;

-- Is this object still referenced by a live row of its shop? Such objects
-- are never purged (for example a signature image an inspection of another
-- job points at).
create function public.storage_object_in_use(p_bucket text, p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case p_bucket
           when 'job-photos' then
             exists (select 1 from public.job_photos p where p.shop_id = s.shop_id and p.storage_path = p_name)
             or exists (select 1 from public.inspection_marks m where m.shop_id = s.shop_id and m.photo_path = p_name)
           when 'signatures' then
             exists (select 1 from public.inspections i where i.shop_id = s.shop_id and i.customer_signature_path = p_name)
             or exists (select 1 from public.form_submissions fs where fs.shop_id = s.shop_id and fs.signature_path = p_name)
           when 'shop-assets' then
             exists (select 1 from public.shops sh where sh.id = s.shop_id and sh.logo_path = p_name)
             or exists (select 1 from public.services sv where sv.shop_id = s.shop_id and sv.image_path = p_name)
           else false
         end
  from (select public.storage_path_uuid(p_name, 1) as shop_id) s
$$;

-- Triggers (AFTER DELETE, every context: a row that is really gone). Rows
-- removed by a shop deletion are skipped: the shop's own request covers the
-- whole folder (the cascade runs after the shop row is gone).
create function public.shops_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.queue_storage_purge(old.id, b.bucket, old.id::text || '/', true, 'shop_deleted')
     from unnest(array['job-photos', 'signatures', 'shop-assets']) as b(bucket);
  return null;
end
$$;

create function public.jobs_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'job-photos', old.shop_id::text || '/' || old.id::text || '/', true, 'job_deleted');
  end if;
  return null;
end
$$;

create function public.inspections_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.customer_signature_path is not null
     and exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'signatures', old.customer_signature_path, false, 'inspection_deleted');
  end if;
  return null;
end
$$;

-- A mark's photo: queued when the mark goes with its inspection (the
-- inspection row is already gone when the cascaded mark deletion runs). A
-- mark deleted on its own keeps its photo (the app removes it through the
-- Storage API, or it stays in the job's gallery); a mark removed with its
-- job or shop is covered by that folder's request.
create function public.inspection_marks_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if old.photo_path is not null
     and not exists (select 1 from public.inspections i where i.id = old.inspection_id and i.shop_id = old.shop_id)
     and exists (select 1 from public.jobs j
                 where j.shop_id = old.shop_id and j.id = public.storage_path_uuid(old.photo_path, 2)) then
    perform public.queue_storage_purge(old.shop_id, 'job-photos', old.photo_path, false, 'inspection_deleted');
  end if;
  return null;
end
$$;

create function public.form_submissions_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'signatures', old.signature_path, false, 'form_deleted');
    perform public.queue_storage_purge(old.shop_id, 'signatures',
                                       old.shop_id::text || '/forms/' || old.public_token::text || '/', true, 'form_deleted');
  end if;
  return null;
end
$$;

create trigger shops_queue_storage_purge after delete on public.shops
  for each row execute function public.shops_queue_storage_purge();
create trigger jobs_queue_storage_purge after delete on public.jobs
  for each row execute function public.jobs_queue_storage_purge();
create trigger inspections_queue_storage_purge after delete on public.inspections
  for each row execute function public.inspections_queue_storage_purge();
create trigger inspection_marks_queue_storage_purge after delete on public.inspection_marks
  for each row execute function public.inspection_marks_queue_storage_purge();
create trigger form_submissions_queue_storage_purge after delete on public.form_submissions
  for each row execute function public.form_submissions_queue_storage_purge();

-- Worker API (service_role; the storage-purge edge function).
--
-- claim_storage_purge: up to p_limit object names that are due for removal,
-- oldest request first. A request with nothing left to remove (every object
-- gone or still referenced) is deleted here, which is how requests finish.
-- Requests handed out are leased for 10 minutes (attempts + 1), and locked
-- rows are skipped, so overlapping workers never get the same request.
create function public.claim_storage_purge(p_limit integer default 500, p_now timestamptz default now())
returns table (request_id bigint, bucket_id text, object_name text)
language plpgsql security definer
set search_path = ''
as $$
declare
  r      public.storage_purge_requests;
  v_left integer;
  v_names text[];
begin
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'p_limit must be between 1 and 1000' using errcode = '22023';
  end if;
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  v_left := p_limit;
  for r in
    select * from public.storage_purge_requests q
     where q.locked_until is null or q.locked_until <= p_now
     order by q.id
     for update skip locked
  loop
    if r.is_prefix then
      select coalesce(array_agg(x.name order by x.name), '{}') into v_names
        from (select o.name from storage.objects o
               where o.bucket_id = r.bucket_id and o.name like r.path || '%'
                 and not public.storage_object_in_use(o.bucket_id, o.name)
               order by o.name
               limit v_left) x;
    else
      select coalesce(array_agg(o.name), '{}') into v_names
        from storage.objects o
       where o.bucket_id = r.bucket_id and o.name = r.path
         and not public.storage_object_in_use(o.bucket_id, o.name);
    end if;

    if cardinality(v_names) = 0 then
      delete from public.storage_purge_requests q where q.id = r.id;
      continue;
    end if;

    update public.storage_purge_requests q
       set locked_until = p_now + interval '10 minutes',
           attempts = q.attempts + 1
     where q.id = r.id;
    return query select r.id, r.bucket_id, n.name from unnest(v_names) as n(name);
    v_left := v_left - cardinality(v_names);
    exit when v_left <= 0;
  end loop;
end
$$;

-- finish_storage_purge: the worker's report for claimed requests. Success
-- releases the lease, so the next claim either finds the request empty (and
-- deletes it) or continues with its remaining objects. Failure records the
-- error and retries after 15 minutes. Returns the number of requests updated.
create function public.finish_storage_purge(p_request_ids bigint[], p_error text default null,
                                            p_now timestamptz default now())
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_now is null then
    raise exception 'p_now is required' using errcode = '22023';
  end if;
  update public.storage_purge_requests q
     set locked_until = case when p_error is null then null else p_now + interval '15 minutes' end,
         last_error = case when p_error is null then null else left(p_error, 2000) end
   where q.id = any (coalesce(p_request_ids, '{}'));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

revoke execute on function
  public.queue_storage_purge(uuid, text, text, boolean, text),
  public.storage_object_in_use(text, text),
  public.shops_queue_storage_purge(),
  public.jobs_queue_storage_purge(),
  public.inspections_queue_storage_purge(),
  public.inspection_marks_queue_storage_purge(),
  public.form_submissions_queue_storage_purge(),
  public.claim_storage_purge(integer, timestamptz),
  public.finish_storage_purge(bigint[], text, timestamptz)
from public, anon, authenticated;
grant execute on function
  public.claim_storage_purge(integer, timestamptz),
  public.finish_storage_purge(bigint[], text, timestamptz)
to service_role;
