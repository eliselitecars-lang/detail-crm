-- ============================================================================
-- 0025 — Field operations: storage buckets and storage.objects policies
-- (SPEC §4.6).
--
--   bucket        visibility  limit   types                         path
--   job-photos    private     20 MB   jpeg, png, webp, heic, heif   <shop_id>/<job_id>/<file>
--   signatures    private      2 MB   png, jpeg, webp               <shop_id>/...
--   shop-assets   public       5 MB   png, jpeg, webp               <shop_id>/...
--
-- Policies (the first folder is always a shop the caller belongs to):
--   job-photos   read + upload: managers+, or technicians assigned to the
--                job in folder 2 (public.can_work_job); the uploader keeps
--                reading and may delete their own objects while still a
--                member; overwrite: managers+ or the uploader on the job.
--   signatures   read: managers+; other members only the signatures of
--                forms/inspections on jobs they work (public.can_work_job,
--                via the referencing row or the form token folder) and
--                objects they uploaded themselves while still a member —
--                signature images are customer PII and a form folder name
--                is the form's public token, so a technician must not be
--                able to list the shop's folder;
--                upload: any active member of the shop; public form
--                signers (anon or signed-in, e.g. portal clients) may upload
--                only to <shop_id>/forms/<token>/<file> of an unsigned form;
--                overwrite/delete: managers+ (signatures are evidence).
--   shop-assets  anyone reads (public bucket; logos, service images);
--                owner/admin upload, overwrite and delete.
-- Signed evidence is immutable for everyone through the API: a job photo
-- pinned to a mark of a signed inspection, the signature image of a signed
-- inspection and the signature image of a signed form cannot be overwritten,
-- moved or deleted (public.is_signed_evidence). A manager un-signs the
-- inspection first (0022); signed forms are permanent.
-- Size and MIME limits are enforced by the Storage API from the bucket
-- configuration below.
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
-- form or inspection on a job they work, and the public upload folder
-- <shop_id>/forms/<token>/ of a form on a job they work.
create function public.can_read_signature_object(p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_shop_manager(s.shop_id)
      or (public.is_shop_member(s.shop_id)
          and (exists (select 1 from public.form_submissions fs
                       where fs.shop_id = s.shop_id and fs.signature_path = p_name
                         and public.can_work_job(fs.shop_id, fs.job_id))
               or exists (select 1 from public.form_submissions fs
                          where split_part(p_name, '/', 2) = 'forms'
                            and fs.public_token = public.storage_path_uuid(p_name, 3)
                            and fs.shop_id = s.shop_id
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
         and (public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1)))));

create policy field_ops_job_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'job-photos'
              and public.is_safe_storage_path(name)
              and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)));

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
                       and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)))));

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
              and public.is_shop_member(public.storage_path_uuid(name, 1)));

create policy field_ops_signatures_insert_public_form on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'signatures' and public.public_form_signature_upload_allowed(name));

create policy field_ops_signatures_update on storage.objects for update to authenticated
  using (bucket_id = 'signatures'
         and public.is_shop_manager(public.storage_path_uuid(name, 1))
         and not public.is_signed_evidence(bucket_id, name))
  with check (bucket_id = 'signatures'
              and public.is_safe_storage_path(name)
              and public.is_shop_manager(public.storage_path_uuid(name, 1)));

create policy field_ops_signatures_delete on storage.objects for delete to authenticated
  using (bucket_id = 'signatures'
         and public.is_shop_manager(public.storage_path_uuid(name, 1))
         and not public.is_signed_evidence(bucket_id, name));

-- ---------------------------------------------------------------------------
-- shop-assets
-- ---------------------------------------------------------------------------
create policy field_ops_shop_assets_select on storage.objects for select to anon, authenticated
  using (bucket_id = 'shop-assets');

create policy field_ops_shop_assets_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'shop-assets'
              and public.is_safe_storage_path(name)
              and public.is_shop_admin(public.storage_path_uuid(name, 1)));

create policy field_ops_shop_assets_update on storage.objects for update to authenticated
  using (bucket_id = 'shop-assets' and public.is_shop_admin(public.storage_path_uuid(name, 1)))
  with check (bucket_id = 'shop-assets'
              and public.is_safe_storage_path(name)
              and public.is_shop_admin(public.storage_path_uuid(name, 1)));

create policy field_ops_shop_assets_delete on storage.objects for delete to authenticated
  using (bucket_id = 'shop-assets' and public.is_shop_admin(public.storage_path_uuid(name, 1)));
