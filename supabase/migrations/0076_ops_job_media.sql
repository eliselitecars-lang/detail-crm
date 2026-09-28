-- ============================================================================
-- 0076 — Job videos (P-30) and the storage purge for the range's files.
--
-- A job video is a job_photos row with media_type 'video': its file is in the
-- job-media bucket (200 MiB, mp4 / quicktime, uploaded with the resumable
-- endpoint) at <shop_id>/<job_id>/v-<file>, with an optional JPEG poster
-- frame in job-photos under the same job folder and its length in seconds.
-- Images keep job-photos. The 'v-' prefix keeps video names apart from photo
-- names (storage_path is unique per shop across both buckets).
--
-- Validation (job_photos_validate): the object exists in the row's bucket
-- under <shop_id>/<job_id>/, and so does the poster. A row's media type and
-- bucket never change through the API (upload a new video instead).
--
-- Storage purge: deleting a video row queues its object and its poster
-- (media_deleted), replacing a poster queues the old one; a deleted job
-- queues its job-media folder and its documents folder (jobs/<job>/), a
-- deleted shop its documents and job-media folders too. Objects still
-- referenced by a live row (documents, video rows and their posters) are
-- never purged (storage_object_in_use).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- job_photos_client_guard (0022) — + media columns are fixed after insert.
-- ---------------------------------------------------------------------------
create or replace function public.job_photos_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if public.is_client_context() then
      new.uploaded_by := auth.uid();
    else
      new.uploaded_by := coalesce(auth.uid(), new.uploaded_by);
    end if;
    return new;
  end if;
  new.uploaded_by := public.audit_user_ref(new.uploaded_by, old.uploaded_by);
  if public.is_client_context()
     and (new.job_id <> old.job_id or new.storage_path <> old.storage_path) then
    raise exception 'a photo''s job and file cannot be changed; upload a new photo instead' using errcode = '42501';
  end if;
  if public.is_client_context()
     and (new.media_type <> old.media_type or new.bucket <> old.bucket) then
    raise exception 'a photo or video keeps its media type; upload a new file instead' using errcode = '42501';
  end if;
  return new;
end
$$;

-- ---------------------------------------------------------------------------
-- job_photos_validate (0022) — the object exists in the row's bucket; video
-- names start with 'v-'; the poster is a JPEG of the same job folder.
-- ---------------------------------------------------------------------------
create or replace function public.job_photos_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.storage_path is distinct from old.storage_path or new.job_id is distinct from old.job_id
     or new.bucket is distinct from old.bucket then
    if public.storage_path_uuid(new.storage_path, 1) is distinct from new.shop_id
       or public.storage_path_uuid(new.storage_path, 2) is distinct from new.job_id then
      raise exception 'job photos must be stored under <shop_id>/<job_id>/' using errcode = '23514';
    end if;
    if new.media_type = 'video' then
      if cardinality(string_to_array(new.storage_path, '/')) <> 3 or split_part(new.storage_path, '/', 3) not like 'v-%' then
        raise exception 'job videos are stored as <shop_id>/<job_id>/v-<file>' using errcode = '23514';
      end if;
      if not public.storage_object_exists('job-media', new.storage_path) then
        raise exception 'upload the video before saving it' using errcode = '23514';
      end if;
    elsif not public.storage_object_exists('job-photos', new.storage_path) then
      raise exception 'upload the photo before saving it' using errcode = '23514';
    end if;
  end if;
  if new.poster_path is not null
     and (tg_op = 'INSERT' or new.poster_path is distinct from old.poster_path or new.job_id is distinct from old.job_id) then
    if public.storage_path_uuid(new.poster_path, 1) is distinct from new.shop_id
       or public.storage_path_uuid(new.poster_path, 2) is distinct from new.job_id
       or new.poster_path !~* '\.jpe?g$' then
      raise exception 'a video poster is a JPEG stored under <shop_id>/<job_id>/ in job-photos' using errcode = '23514';
    end if;
    if not public.storage_object_exists('job-photos', new.poster_path) then
      raise exception 'upload the poster image before saving it' using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

-- A video's files go with its row (a photo's file stays until the app
-- removes it, 0022); a replaced poster is queued too. Rows removed with their
-- job or shop are covered by that folder's request.
create function public.job_photos_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.jobs j where j.id = old.job_id and j.shop_id = old.shop_id) then
    return null;
  end if;
  if tg_op = 'DELETE' then
    if old.media_type = 'video' then
      perform public.queue_storage_purge(old.shop_id, 'job-media', old.storage_path, false, 'media_deleted');
      perform public.queue_storage_purge(old.shop_id, 'job-photos', old.poster_path, false, 'media_deleted');
    end if;
  elsif old.poster_path is not null and new.poster_path is distinct from old.poster_path then
    perform public.queue_storage_purge(old.shop_id, 'job-photos', old.poster_path, false, 'media_deleted');
  end if;
  return null;
end
$$;

create trigger job_photos_zz_ops_queue_storage_purge after delete or update of poster_path on public.job_photos
  for each row execute function public.job_photos_queue_storage_purge();

-- ---------------------------------------------------------------------------
-- storage_object_in_use (0025) — + documents, videos and posters.
-- ---------------------------------------------------------------------------
create or replace function public.storage_object_in_use(p_bucket text, p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select case p_bucket
           when 'job-photos' then
             exists (select 1 from public.job_photos p
                      where p.shop_id = s.shop_id and p.bucket = 'job-photos' and p.storage_path = p_name)
             or exists (select 1 from public.job_photos p where p.shop_id = s.shop_id and p.poster_path = p_name)
             or exists (select 1 from public.inspection_marks m where m.shop_id = s.shop_id and m.photo_path = p_name)
           when 'job-media' then
             exists (select 1 from public.job_photos p
                      where p.shop_id = s.shop_id and p.bucket = 'job-media' and p.storage_path = p_name)
           when 'signatures' then
             exists (select 1 from public.inspections i where i.shop_id = s.shop_id and i.customer_signature_path = p_name)
             or exists (select 1 from public.form_submissions fs where fs.shop_id = s.shop_id and fs.signature_path = p_name)
           when 'shop-assets' then
             exists (select 1 from public.shops sh where sh.id = s.shop_id and sh.logo_path = p_name)
             or exists (select 1 from public.services sv where sv.shop_id = s.shop_id and sv.image_path = p_name)
           when 'documents' then
             exists (select 1 from public.documents d where d.shop_id = s.shop_id and d.storage_path = p_name)
           else false
         end
  from (select public.storage_path_uuid(p_name, 1) as shop_id) s
$$;

-- ---------------------------------------------------------------------------
-- shops_queue_storage_purge / jobs_queue_storage_purge (0025) — + the
-- range's buckets and folders. (A job's report signature folders are queued
-- by job_reports_zz_ops_queue_storage_purge, 0072: the reports are gone by
-- the time the job's AFTER DELETE trigger runs.)
-- ---------------------------------------------------------------------------
create or replace function public.shops_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.queue_storage_purge(old.id, b.bucket, old.id::text || '/', true, 'shop_deleted')
     from unnest(array['job-photos', 'signatures', 'shop-assets', 'documents', 'job-media']) as b(bucket);
  return null;
end
$$;

create or replace function public.jobs_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'job-photos', old.shop_id::text || '/' || old.id::text || '/', true, 'job_deleted');
    perform public.queue_storage_purge(old.shop_id, 'job-media', old.shop_id::text || '/' || old.id::text || '/', true, 'job_deleted');
    perform public.queue_storage_purge(old.shop_id, 'documents', old.shop_id::text || '/jobs/' || old.id::text || '/', true, 'job_deleted');
  end if;
  return null;
end
$$;

revoke execute on function public.job_photos_queue_storage_purge() from public, anon, authenticated;
