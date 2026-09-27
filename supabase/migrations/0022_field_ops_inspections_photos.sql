-- ============================================================================
-- 0022 — Field operations: inspections, inspection_marks, job_photos
-- (SPEC §4.6).
--
-- Access: managers+ of the shop, and technicians assigned to the job
-- (public.can_work_job). Clients never touch these tables directly.
--
-- Signatures: customer_signature_path, signed_by_name and signed_at are set
-- together. For direct writes signed_at is stamped by the server and the
-- signature image must already be uploaded to the signatures bucket under
-- the shop's folder. Once signed, an inspection and its marks are locked:
-- nobody may edit or delete them through the API; a manager+ may un-sign
-- (clear exactly the three signature columns, nothing else) to unlock it.
-- Deleting the job still cascades (trusted RI context).
--
-- Vehicles: an inspection records the condition of one specific vehicle, so
-- a vehicle that has inspections cannot be deleted (ON DELETE RESTRICT,
-- 23503 naming inspections_vehicle_fk); archive it (vehicles.archived_at)
-- instead, like a vehicle with membership history. SET NULL is not an
-- option: at most one inspection of each kind exists per job and vehicle,
-- the vehicle-less slot included (UNIQUE NULLS NOT DISTINCT), so clearing
-- the vehicle of a multi-vehicle job's inspections would collide with each
-- other or with the job's vehicle-less inspection, and the evidence would
-- lose which car it describes. Deleting the job or the shop still cascades.
--
-- Files: job_photos.storage_path and inspection_marks.photo_path are object
-- names in the job-photos bucket, "<shop_id>/<job_id>/<file>", of the row's
-- own job, and the object must exist. Deleting a photo or mark row does not
-- delete the stored object (the app deletes it through the Storage API,
-- which enforces the storage policies in 0025); deleting a job queues its
-- photo folder, and deleting an inspection its signature image and its
-- marks' photos, for the storage purge (0025). An inspection cannot be signed while a mark's photo
-- is missing, and the photo of a mark on a signed inspection and the
-- signature image are locked in storage (0025: no upload, overwrite, move or
-- delete), so the evidence the customer signed off on cannot be replaced or
-- removed after signing.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- inspections
-- ---------------------------------------------------------------------------
create table public.inspections (
  id                       uuid primary key default gen_random_uuid(),
  shop_id                  uuid not null references public.shops (id) on delete cascade,
  job_id                   uuid not null,
  vehicle_id               uuid,
  kind                     public.inspection_kind not null,
  mileage                  integer check (mileage is null or mileage between 0 and 9999999),
  fuel_level               smallint check (fuel_level is null or fuel_level between 0 and 100),
  notes                    text check (notes is null or char_length(notes) <= 20000),
  customer_signature_path  text check (customer_signature_path is null or public.is_safe_storage_path(customer_signature_path)),
  signed_by_name           text check (signed_by_name is null or char_length(signed_by_name) between 1 and 200),
  signed_at                timestamptz,
  created_by               uuid references auth.users (id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  constraint inspections_shop_id_id_key unique (shop_id, id),
  constraint inspections_job_vehicle_kind_key unique nulls not distinct (job_id, vehicle_id, kind),
  constraint inspections_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint inspections_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete restrict,
  constraint inspections_signature_complete check (
    (customer_signature_path is null) = (signed_by_name is null)
    and (customer_signature_path is null) = (signed_at is null))
);
create index inspections_shop_job_idx on public.inspections (shop_id, job_id);
create index inspections_shop_vehicle_idx on public.inspections (shop_id, vehicle_id);
create index inspections_created_by_idx on public.inspections (created_by);
-- storage policies look signatures up by path (0025)
create index inspections_shop_signature_path_idx on public.inspections (shop_id, customer_signature_path)
  where customer_signature_path is not null;

comment on column public.inspections.fuel_level is 'Fuel gauge reading in percent (0-100).';
comment on column public.inspections.customer_signature_path is 'Object name in the signatures bucket: <shop_id>/...';

-- Direct writes: sign/un-sign rules and the signed lock.
create function public.inspections_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_sig constant text[] := array['customer_signature_path', 'signed_by_name', 'signed_at', 'updated_at'];
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    if old.signed_at is not null then
      raise exception 'signed inspections cannot be deleted; a manager must remove the signature first'
        using errcode = '42501';
    end if;
    return old;
  end if;

  new.signed_by_name := nullif(btrim(new.signed_by_name), '');

  if tg_op = 'UPDATE' then
    if new.job_id <> old.job_id then
      raise exception 'inspections cannot move to another job' using errcode = '42501';
    end if;
    if old.signed_at is not null then
      -- the only permitted change: a manager+ clears the signature
      if public.is_shop_manager(old.shop_id)
         and new.customer_signature_path is null and new.signed_by_name is null and new.signed_at is null
         and (to_jsonb(new) - v_sig) = (to_jsonb(old) - v_sig) then
        return new;
      end if;
      raise exception 'this inspection is signed and locked; a manager must remove the signature before editing'
        using errcode = '42501';
    end if;
  end if;

  -- signing (on insert or on an unsigned row): the server stamps the time
  if new.customer_signature_path is not null or new.signed_by_name is not null or new.signed_at is not null then
    if new.customer_signature_path is null or new.signed_by_name is null then
      raise exception 'a signature needs both the signature image and the signer''s name' using errcode = '23514';
    end if;
    new.signed_at := now();
  end if;
  return new;
end
$$;

-- AFTER: the vehicle belongs to the job's customer (or is a vehicle on one of
-- the job's line items); a new signature image exists under the shop folder.
create function public.inspections_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  -- a job with an inspection keeps its customer (jobs_customer_records_guard,
  -- 0023): hold the job row so a concurrent customer move either waits for
  -- this insert (and then sees it) or commits first (and the vehicle check
  -- below then reads the job's new customer)
  if tg_op = 'INSERT' then
    perform 1 from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id for share;
  end if;
  if new.vehicle_id is not null
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id)
     and not exists (
       select 1 from public.jobs j
       where j.id = new.job_id and j.shop_id = new.shop_id
         and (exists (select 1 from public.vehicles v
                      where v.id = new.vehicle_id and v.shop_id = j.shop_id and v.customer_id = j.customer_id)
              or exists (select 1 from public.job_line_items li
                         where li.job_id = j.id and li.shop_id = j.shop_id and li.vehicle_id = new.vehicle_id))) then
    raise exception 'the vehicle is not on this job' using errcode = '23514';
  end if;

  if new.customer_signature_path is not null
     and (tg_op = 'INSERT' or new.customer_signature_path is distinct from old.customer_signature_path) then
    if public.storage_path_uuid(new.customer_signature_path, 1) is distinct from new.shop_id then
      raise exception 'the signature must be stored under this shop''s folder' using errcode = '23514';
    end if;
    if not public.storage_object_exists('signatures', new.customer_signature_path) then
      raise exception 'upload the signature image before saving it' using errcode = '23514';
    end if;
  end if;

  -- the customer signs off on the photos too: every mark's photo must still
  -- be there (a photo deleted before signing could otherwise be re-created
  -- with different content at the signed path; 0025 also refuses uploads to
  -- signed evidence paths)
  if new.signed_at is not null and (tg_op = 'INSERT' or old.signed_at is null)
     and exists (select 1 from public.inspection_marks m
                 where m.inspection_id = new.id and m.shop_id = new.shop_id and m.photo_path is not null
                   and not public.storage_object_exists('job-photos', m.photo_path)) then
    raise exception 'a damage photo of this inspection is missing; attach it again or remove the mark before signing'
      using errcode = '23514';
  end if;
  return null;
end
$$;

create trigger inspections_05_prevent_shop_change before update on public.inspections
  for each row execute function public.prevent_shop_change();
create trigger inspections_10_client_guard before insert or update or delete on public.inspections
  for each row execute function public.inspections_client_guard();
create trigger inspections_20_set_created_by before insert or update on public.inspections
  for each row execute function public.set_created_by();
create trigger inspections_90_set_updated_at before update on public.inspections
  for each row execute function public.set_updated_at();
create trigger inspections_validate after insert or update on public.inspections
  for each row execute function public.inspections_validate();

-- ---------------------------------------------------------------------------
-- inspection_marks — damage pins on a vehicle diagram (x, y in 0..1).
-- ---------------------------------------------------------------------------
create table public.inspection_marks (
  id             uuid primary key default gen_random_uuid(),
  shop_id        uuid not null references public.shops (id) on delete cascade,
  inspection_id  uuid not null,
  view           public.vehicle_view not null,
  x              double precision not null check (x between 0 and 1),
  y              double precision not null check (y between 0 and 1),
  damage         public.damage_kind not null,
  note           text check (note is null or char_length(note) <= 2000),
  photo_path     text check (photo_path is null or public.is_safe_storage_path(photo_path)),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint inspection_marks_shop_id_id_key unique (shop_id, id),
  constraint inspection_marks_inspection_fk foreign key (shop_id, inspection_id)
    references public.inspections (shop_id, id) on delete cascade
);
create index inspection_marks_shop_inspection_idx on public.inspection_marks (shop_id, inspection_id);
-- storage policies look mark photos up by path (0025: signed evidence lock)
create index inspection_marks_shop_photo_path_idx on public.inspection_marks (shop_id, photo_path)
  where photo_path is not null;

comment on column public.inspection_marks.photo_path is 'Object name in the job-photos bucket: <shop_id>/<job_id>/<file>.';

-- Direct writes: marks of a signed inspection are locked. The parent is read
-- with the caller's own RLS; a parent the caller cannot see is rejected by
-- the marks policies anyway.
create function public.inspection_marks_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and new.inspection_id <> old.inspection_id then
    raise exception 'marks cannot move to another inspection' using errcode = '42501';
  end if;
  if exists (select 1 from public.inspections i
             where i.id = coalesce(new.inspection_id, old.inspection_id) and i.signed_at is not null) then
    raise exception 'this inspection is signed and locked; a manager must remove the signature before editing'
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end
$$;

-- AFTER: the mark photo belongs to the inspection's job folder and exists.
create function public.inspection_marks_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job uuid;
begin
  if new.photo_path is not null
     and (tg_op = 'INSERT' or new.photo_path is distinct from old.photo_path) then
    select i.job_id into v_job from public.inspections i
     where i.id = new.inspection_id and i.shop_id = new.shop_id;
    if public.storage_path_uuid(new.photo_path, 1) is distinct from new.shop_id
       or public.storage_path_uuid(new.photo_path, 2) is distinct from v_job then
      raise exception 'mark photos must be stored under <shop_id>/<job_id>/ of the inspection''s job'
        using errcode = '23514';
    end if;
    if not public.storage_object_exists('job-photos', new.photo_path) then
      raise exception 'upload the photo before attaching it' using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

create trigger inspection_marks_05_prevent_shop_change before update on public.inspection_marks
  for each row execute function public.prevent_shop_change();
create trigger inspection_marks_10_client_guard before insert or update or delete on public.inspection_marks
  for each row execute function public.inspection_marks_client_guard();
create trigger inspection_marks_90_set_updated_at before update on public.inspection_marks
  for each row execute function public.set_updated_at();
create trigger inspection_marks_validate after insert or update on public.inspection_marks
  for each row execute function public.inspection_marks_validate();

-- ---------------------------------------------------------------------------
-- job_photos
-- ---------------------------------------------------------------------------
create table public.job_photos (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  job_id        uuid not null,
  storage_path  text not null check (public.is_safe_storage_path(storage_path)),
  kind          public.job_photo_kind not null default 'other',
  caption       text check (caption is null or char_length(caption) <= 500),
  uploaded_by   uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint job_photos_shop_id_id_key unique (shop_id, id),
  constraint job_photos_storage_path_key unique (shop_id, storage_path),
  constraint job_photos_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade
);
create index job_photos_shop_job_idx on public.job_photos (shop_id, job_id, created_at);
create index job_photos_uploaded_by_idx on public.job_photos (uploaded_by);

comment on column public.job_photos.storage_path is 'Object name in the job-photos bucket: <shop_id>/<job_id>/<file>.';

create function public.job_photos_client_guard() returns trigger
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
  return new;
end
$$;

create function public.job_photos_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' or new.storage_path is distinct from old.storage_path or new.job_id is distinct from old.job_id then
    if public.storage_path_uuid(new.storage_path, 1) is distinct from new.shop_id
       or public.storage_path_uuid(new.storage_path, 2) is distinct from new.job_id then
      raise exception 'job photos must be stored under <shop_id>/<job_id>/' using errcode = '23514';
    end if;
    if not public.storage_object_exists('job-photos', new.storage_path) then
      raise exception 'upload the photo before saving it' using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

create trigger job_photos_05_prevent_shop_change before update on public.job_photos
  for each row execute function public.prevent_shop_change();
create trigger job_photos_10_client_guard before insert or update on public.job_photos
  for each row execute function public.job_photos_client_guard();
create trigger job_photos_90_set_updated_at before update on public.job_photos
  for each row execute function public.set_updated_at();
create trigger job_photos_validate after insert or update on public.job_photos
  for each row execute function public.job_photos_validate();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.inspections      enable row level security;
alter table public.inspection_marks enable row level security;
alter table public.job_photos       enable row level security;

create policy inspections_select on public.inspections for select to authenticated
  using (public.can_work_job(shop_id, job_id));
create policy inspections_insert on public.inspections for insert to authenticated
  with check (public.can_work_job(shop_id, job_id));
create policy inspections_update on public.inspections for update to authenticated
  using (public.can_work_job(shop_id, job_id)) with check (public.can_work_job(shop_id, job_id));
create policy inspections_delete on public.inspections for delete to authenticated
  using (public.can_work_job(shop_id, job_id));

-- marks follow their inspection: visible (and writable) exactly when the
-- caller can see the parent inspection through its own policy.
create policy inspection_marks_select on public.inspection_marks for select to authenticated
  using (exists (select 1 from public.inspections i
                 where i.id = inspection_marks.inspection_id and i.shop_id = inspection_marks.shop_id));
create policy inspection_marks_insert on public.inspection_marks for insert to authenticated
  with check (exists (select 1 from public.inspections i
                      where i.id = inspection_marks.inspection_id and i.shop_id = inspection_marks.shop_id));
create policy inspection_marks_update on public.inspection_marks for update to authenticated
  using (exists (select 1 from public.inspections i
                 where i.id = inspection_marks.inspection_id and i.shop_id = inspection_marks.shop_id))
  with check (exists (select 1 from public.inspections i
                      where i.id = inspection_marks.inspection_id and i.shop_id = inspection_marks.shop_id));
create policy inspection_marks_delete on public.inspection_marks for delete to authenticated
  using (exists (select 1 from public.inspections i
                 where i.id = inspection_marks.inspection_id and i.shop_id = inspection_marks.shop_id));

-- photos: staff on the job add and see them; the uploader (while still a
-- member) keeps seeing and may delete their own photos; captions are edited
-- by managers+ or the uploader while on the job.
create policy job_photos_select on public.job_photos for select to authenticated
  using (public.can_work_job(shop_id, job_id) or (uploaded_by = auth.uid() and public.is_shop_member(shop_id)));
create policy job_photos_insert on public.job_photos for insert to authenticated
  with check (public.can_work_job(shop_id, job_id));
create policy job_photos_update on public.job_photos for update to authenticated
  using (public.is_shop_manager(shop_id) or (uploaded_by = auth.uid() and public.can_work_job(shop_id, job_id)))
  with check (public.is_shop_manager(shop_id) or (uploaded_by = auth.uid() and public.can_work_job(shop_id, job_id)));
create policy job_photos_delete on public.job_photos for delete to authenticated
  using (public.is_shop_manager(shop_id) or (uploaded_by = auth.uid() and public.is_shop_member(shop_id)));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.inspections, public.inspection_marks, public.job_photos from anon;
revoke truncate, trigger, references on public.inspections, public.inspection_marks, public.job_photos
  from authenticated;

revoke execute on function
  public.inspections_client_guard(),
  public.inspections_validate(),
  public.inspection_marks_client_guard(),
  public.inspection_marks_validate(),
  public.job_photos_client_guard(),
  public.job_photos_validate()
from public, anon, authenticated;
