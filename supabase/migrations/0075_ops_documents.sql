-- ============================================================================
-- 0075 — Document uploads on customers and jobs (P-25).
--
-- Files live in the documents bucket (0071): customer files under
-- <shop_id>/customers/<customer_id>/<file>, job files under
-- <shop_id>/jobs/<job_id>/<file>. A documents row registers an uploaded
-- object; the object must exist and sit in the row's own folder.
--
-- Access (0071): managers+ everything; technicians the documents of jobs
-- they work (read, add, delete their own uploads; they cannot mark a file
-- customer-visible). Only file_name and customer_visible are editable, by
-- managers+.
--
-- A job document's customer_id is always the job's customer: filled on
-- insert and moved with the job when the job's customer changes (also by a
-- merge, 0074, which moves the customer documents itself).
--
-- Customer-facing lists (never storage paths; files are served as
-- short-lived signed URLs by the public-media edge function):
--   public_booking_documents(booking token)    anon: customer-visible files
--                                              of the booking's job
--   portal_documents()                         signed-in client: visible
--                                              files of their linked customers
--   portal_job_reports()                       signed-in client: live job
--                                              reports of their jobs (P-8)
--   booking_document_media / portal_document_media   service_role: the
--                                              object behind a listed file.
--
-- Storage purge (0025 queue): deleting a document queues its object;
-- deleting a customer queues its customer folder; job and shop folders are
-- queued by jobs_queue_storage_purge / shops_queue_storage_purge (0076).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 10: direct writes (SECURITY INVOKER: sees the caller).
-- ---------------------------------------------------------------------------
create function public.documents_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.file_name := btrim(new.file_name);
  new.content_type := lower(btrim(new.content_type));
  if tg_op = 'INSERT' then
    if public.is_client_context() then
      new.uploaded_by := auth.uid();
      if not public.is_shop_manager(new.shop_id) then
        new.customer_visible := false;   -- sharing with the customer is a manager decision
      end if;
    else
      new.uploaded_by := coalesce(auth.uid(), new.uploaded_by);
    end if;
    return new;
  end if;
  new.uploaded_by := public.audit_user_ref(new.uploaded_by, old.uploaded_by);
  return new;
end
$$;

-- 20: a job document belongs to the job's customer (filled when omitted).
create function public.documents_fill_customer() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.job_id is not null and new.customer_id is null then
    select j.customer_id into new.customer_id from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
  end if;
  return new;
end
$$;

-- AFTER (RLS, constraints and the composite FKs have passed): the row's
-- folder and object, and the job's customer.
create function public.documents_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_job_customer uuid;
begin
  if new.job_id is not null
     and (tg_op = 'INSERT' or new.job_id is distinct from old.job_id or new.customer_id is distinct from old.customer_id) then
    select j.customer_id into v_job_customer from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id;
    if v_job_customer is distinct from new.customer_id then
      raise exception 'a job document belongs to the job''s customer' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'INSERT' or new.storage_path is distinct from old.storage_path or new.job_id is distinct from old.job_id then
    if cardinality(string_to_array(new.storage_path, '/')) <> 4
       or public.storage_path_uuid(new.storage_path, 1) is distinct from new.shop_id
       or (new.job_id is not null
           and (split_part(new.storage_path, '/', 2) <> 'jobs'
                or public.storage_path_uuid(new.storage_path, 3) is distinct from new.job_id))
       or (new.job_id is null
           and (split_part(new.storage_path, '/', 2) <> 'customers'
                or public.storage_path_uuid(new.storage_path, 3) is distinct from new.customer_id)) then
      raise exception 'documents are stored under <shop_id>/jobs/<job_id>/ or <shop_id>/customers/<customer_id>/'
        using errcode = '23514';
    end if;
    if not public.storage_object_exists('documents', new.storage_path) then
      raise exception 'upload the file before saving it' using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

create trigger documents_10_client_guard before insert or update on public.documents
  for each row execute function public.documents_client_guard();
create trigger documents_20_fill_customer before insert or update of job_id, customer_id on public.documents
  for each row execute function public.documents_fill_customer();
create trigger documents_zz_ops_validate after insert or update on public.documents
  for each row execute function public.documents_validate();

-- A job's documents follow the job's customer.
create function public.jobs_ops_documents_follow() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  update public.documents d
     set customer_id = new.customer_id
   where d.shop_id = new.shop_id and d.job_id = new.id and d.customer_id is distinct from new.customer_id;
  return null;
end
$$;

create trigger jobs_zz_ops_documents_follow after update of customer_id on public.jobs
  for each row when (old.customer_id is distinct from new.customer_id)
  execute function public.jobs_ops_documents_follow();

-- ---------------------------------------------------------------------------
-- Storage purge: a deleted document's object; a deleted customer's folder.
-- Rows removed by a shop deletion are covered by the shop's request.
-- ---------------------------------------------------------------------------
create function public.documents_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'documents', old.storage_path, false, 'document_deleted');
  end if;
  return null;
end
$$;

create trigger documents_zz_ops_queue_storage_purge after delete on public.documents
  for each row execute function public.documents_queue_storage_purge();

create function public.customers_ops_queue_storage_purge() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.shops s where s.id = old.shop_id) then
    perform public.queue_storage_purge(old.shop_id, 'documents',
                                       old.shop_id::text || '/customers/' || old.id::text || '/', true, 'customer_deleted');
  end if;
  return null;
end
$$;

create trigger customers_zz_ops_queue_storage_purge after delete on public.customers
  for each row execute function public.customers_ops_queue_storage_purge();

-- ---------------------------------------------------------------------------
-- Booking page (/booking/<jobs.public_token>): the job's customer-visible
-- files. The booking page is already the job's customer surface.
-- ---------------------------------------------------------------------------
create function public.public_booking_documents(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  select * into v_job from public.jobs j where j.public_token = p_token;
  if not found then
    raise exception 'booking not found' using errcode = 'PT404';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', d.id,
             'file_name', d.file_name,
             'content_type', d.content_type,
             'size_bytes', d.size_bytes,
             'created_at', d.created_at) order by d.created_at, d.id)
      from public.documents d
     where d.job_id = v_job.id and d.shop_id = v_job.shop_id and d.customer_visible), '[]'::jsonb);
end
$$;

-- service_role: the objects behind public_booking_documents (no rows for an
-- unknown token).
create function public.booking_document_media(p_token uuid)
returns table (ref_id uuid, bucket text, path text)
language sql stable security definer
set search_path = ''
as $$
  select d.id, 'documents', d.storage_path
    from public.jobs j
    join public.documents d on d.job_id = j.id and d.shop_id = j.shop_id
   where j.public_token = p_token and d.customer_visible
   order by d.created_at, d.id
$$;

-- ---------------------------------------------------------------------------
-- Client portal
-- ---------------------------------------------------------------------------
create function public.portal_documents() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', d.id,
             'shop_name', s.name,
             'file_name', d.file_name,
             'content_type', d.content_type,
             'size_bytes', d.size_bytes,
             'job_number', j.number,
             'created_at', d.created_at) order by d.created_at desc, d.id)
      from public.customers c
      join public.documents d on d.customer_id = c.id and d.shop_id = c.shop_id
      join public.shops s on s.id = d.shop_id
      left join public.jobs j on j.id = d.job_id and j.shop_id = d.shop_id
     where c.portal_user_id = v_uid and c.archived_at is null and d.customer_visible), '[]'::jsonb);
end
$$;

-- service_role (public-media): {bucket, path} of a document the user may
-- see through portal_documents, else null.
create function public.portal_document_media(p_document_id uuid, p_user_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object('bucket', 'documents', 'path', d.storage_path)
    from public.documents d
    join public.customers c on c.id = d.customer_id and c.shop_id = d.shop_id
   where d.id = p_document_id and d.customer_visible
     and p_user_id is not null and c.portal_user_id = p_user_id and c.archived_at is null
$$;

create function public.portal_job_reports() returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sign in to use the client portal' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'shop_name', s.name,
             'job_number', j.number,
             'completed_at', j.completed_at,
             'published_at', r.published_at,
             'report_path', '/r/' || r.token::text) order by r.published_at desc, r.id)
      from public.customers c
      join public.jobs j on j.customer_id = c.id and j.shop_id = c.shop_id
      join public.job_reports r on r.job_id = j.id and r.shop_id = j.shop_id and r.revoked_at is null
      join public.shops s on s.id = j.shop_id
     where c.portal_user_id = v_uid and c.archived_at is null), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.documents_client_guard(),
  public.documents_fill_customer(),
  public.documents_validate(),
  public.jobs_ops_documents_follow(),
  public.documents_queue_storage_purge(),
  public.customers_ops_queue_storage_purge()
from public, anon, authenticated;

revoke execute on function
  public.booking_document_media(uuid),
  public.portal_document_media(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.booking_document_media(uuid),
  public.portal_document_media(uuid, uuid)
to service_role;

revoke execute on function public.public_booking_documents(uuid) from public;
grant execute on function public.public_booking_documents(uuid) to anon, authenticated, service_role;

revoke execute on function public.portal_documents(), public.portal_job_reports() from public, anon;
grant execute on function public.portal_documents(), public.portal_job_reports() to authenticated, service_role;
