-- ============================================================================
-- 0023 — Field operations: form_templates, form_submissions, automatic
-- attachment to new jobs, public form view/sign RPCs and staff on-device
-- signing (SPEC §4.6, §4.9).
--
-- Rules
--   * form_templates are shop settings (SPEC §3 "templates", §6 settings ›
--     forms): all members read, owner/admin write.
--   * A new job gets one submission per active template with
--     attach_to = 'all_jobs', plus 'online_booking' templates when
--     jobs.source = 'online_booking'. Managers+ may attach any template to a
--     job by inserting a submission (the server copies the template's title,
--     body and signature requirement, the job's customer and issues the
--     token); at most one submission per template per job.
--   * The body is snapshotted at creation, so later template edits never
--     change what a customer sees or signed.
--   * Submissions are signed exactly once, only through the signing RPCs
--     (API roles have no UPDATE privilege): anonymous/portal signers use
--     public_sign_form(token, ...), staff on the job use
--     sign_form_submission(id, ...) on their device. A form cannot be signed
--     while its job is cancelled or a no-show (status "void").
--   * Signature images live in the signatures bucket. Public signers upload
--     to "<shop_id>/forms/<public_token>/<file>" (storage policy in 0025
--     allows that only while the form is unsigned); staff may use any path
--     under "<shop_id>/". The object must exist when signing. Because the
--     token folder name is the form's public token, technicians may read
--     only the signature objects of forms on jobs they work (0025), and a
--     signed form's image can no longer be overwritten or deleted.
--   * Signed submissions cannot be deleted through the API (job deletion
--     still cascades). Unsigned ones follow the job's customer (with a new
--     token). A job that carries records issued to or signed by its customer
--     (a signed form, any inspection, any invoice including void ones) keeps
--     that customer in every context (23514): those documents are the
--     customer's and their public links show the job, so moving the job would
--     hand one customer's signed paperwork to the other (and the other's
--     appointment to the first), and the new customer could never be asked
--     to sign a template the previous one already signed (one per job).
--     Book a new job for the other customer instead.
--   * The form token is the customer's credential: whoever holds it can,
--     without signing in, read the form and sign it as the customer
--     (signed_by null = an anonymous signer). Staff roles that may not act
--     as the customer must never see it (the same rule as jobs.public_token,
--     0042): `authenticated` gets SELECT on every form_submissions column
--     EXCEPT public_token, owners/admins/managers fetch it with
--     form_link_token(submission_id) to share the /f link, and technicians
--     collect signatures through sign_form_submission (attributed to them,
--     and only while they work the job). A migration that adds a
--     form_submissions column must grant SELECT on it to authenticated
--     (20_form_token_privacy.sql checks the whole column set). Defence in
--     depth: public_sign_form refuses a signed-in active member of the
--     form's shop below manager (42501) unless they are the client linked to
--     the form's customer.
--   * Signing locks the job row (FOR SHARE) before the submission, the same
--     order a customer move takes (job row, then its forms), so a form cannot
--     be signed between the move's check and its commit, and a public signer
--     whose link was re-tokenized by a concurrent move gets "form not found".
-- ============================================================================

-- ---------------------------------------------------------------------------
-- form_templates
-- ---------------------------------------------------------------------------
create table public.form_templates (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops (id) on delete cascade,
  name                text not null check (char_length(btrim(name)) between 1 and 120),
  body                text not null check (char_length(body) between 1 and 100000),
  requires_signature  boolean not null default true,
  attach_to           public.form_attach_to not null default 'manual',
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint form_templates_shop_id_id_key unique (shop_id, id)
);
create index form_templates_shop_attach_idx on public.form_templates (shop_id, attach_to) where active;

create function public.form_templates_normalize() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  return new;
end
$$;

create trigger form_templates_10_prevent_shop_change before update on public.form_templates
  for each row execute function public.prevent_shop_change();
create trigger form_templates_20_normalize before insert or update on public.form_templates
  for each row execute function public.form_templates_normalize();
create trigger form_templates_90_set_updated_at before update on public.form_templates
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- form_submissions
-- ---------------------------------------------------------------------------
create table public.form_submissions (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops (id) on delete cascade,
  form_template_id    uuid,
  job_id              uuid not null,
  customer_id         uuid,
  title               text not null check (char_length(btrim(title)) between 1 and 120),
  body_snapshot       text not null check (char_length(body_snapshot) between 1 and 100000),
  requires_signature  boolean not null default true,
  public_token        uuid not null default gen_random_uuid() unique,
  signer_name         text check (signer_name is null or char_length(signer_name) between 1 and 200),
  signature_path      text check (signature_path is null or public.is_safe_storage_path(signature_path)),
  signed_at           timestamptz,
  signer_ip           inet,
  signed_by           uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint form_submissions_shop_id_id_key unique (shop_id, id),
  constraint form_submissions_template_fk foreign key (shop_id, form_template_id)
    references public.form_templates (shop_id, id) on delete set null (form_template_id),
  constraint form_submissions_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint form_submissions_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete set null (customer_id),
  constraint form_submissions_signed_pair check ((signed_at is null) = (signer_name is null)),
  constraint form_submissions_signature_signed check (signature_path is null or signed_at is not null),
  constraint form_submissions_signature_required check (
    signed_at is null or not requires_signature or signature_path is not null),
  constraint form_submissions_unsigned_extras check (signed_at is not null or (signer_ip is null and signed_by is null))
);
create unique index form_submissions_job_template_key on public.form_submissions (job_id, form_template_id)
  where form_template_id is not null;
create index form_submissions_shop_job_idx on public.form_submissions (shop_id, job_id);
create index form_submissions_shop_template_idx on public.form_submissions (shop_id, form_template_id);
create index form_submissions_shop_customer_idx on public.form_submissions (shop_id, customer_id);
create index form_submissions_signed_by_idx on public.form_submissions (signed_by);
-- storage policies look signatures up by path (0025)
create index form_submissions_shop_signature_path_idx on public.form_submissions (shop_id, signature_path)
  where signature_path is not null;

comment on column public.form_submissions.signature_path is
  'Object name in the signatures bucket (<shop_id>/...). Set only by the signing RPCs.';
comment on column public.form_submissions.signed_by is 'auth user who signed (portal user or staff); null for anonymous signers.';

-- Direct inserts (managers+): everything but the job and template is filled
-- by the server. SECURITY INVOKER: the template and job are read with the
-- caller's own RLS. Missing/foreign templates are left for RLS (which runs
-- before NOT NULL/CHECK), NOT NULL and the composite FKs to reject, so
-- unauthorized callers get 42501.
create function public.form_submissions_before_insert() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_template public.form_templates;
begin
  if public.is_client_context() then
    new.public_token := gen_random_uuid();
    new.signer_name := null;
    new.signature_path := null;
    new.signed_at := null;
    new.signer_ip := null;
    new.signed_by := null;
    new.title := null;
    new.body_snapshot := null;
    new.customer_id := null;
    if public.is_shop_manager(new.shop_id) then
      select * into v_template from public.form_templates t
       where t.id = new.form_template_id and t.shop_id = new.shop_id;
      if found then
        new.title := v_template.name;
        new.body_snapshot := v_template.body;
        new.requires_signature := v_template.requires_signature;
      end if;
      select j.customer_id into new.customer_id from public.jobs j
       where j.id = new.job_id and j.shop_id = new.shop_id;
    end if;
  end if;
  return new;
end
$$;

-- Signed submissions are permanent for API callers.
create function public.form_submissions_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() and old.signed_at is not null then
    raise exception 'signed forms cannot be deleted' using errcode = '42501';
  end if;
  return old;
end
$$;

create trigger form_submissions_05_prevent_shop_change before update on public.form_submissions
  for each row execute function public.prevent_shop_change();
create trigger form_submissions_10_before_insert before insert on public.form_submissions
  for each row execute function public.form_submissions_before_insert();
create trigger form_submissions_10_client_guard before delete on public.form_submissions
  for each row execute function public.form_submissions_client_guard();
create trigger form_submissions_90_set_updated_at before update on public.form_submissions
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Jobs → forms: attach on insert; unsigned forms follow the job's customer.
-- ---------------------------------------------------------------------------
create function public.jobs_attach_forms() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.form_submissions (shop_id, form_template_id, job_id, customer_id, title, body_snapshot,
                                       requires_signature)
  select new.shop_id, t.id, new.id, new.customer_id, t.name, t.body, t.requires_signature
  from public.form_templates t
  where t.shop_id = new.shop_id
    and t.active
    and (t.attach_to = 'all_jobs' or (t.attach_to = 'online_booking' and new.source = 'online_booking'))
  order by t.created_at, t.id
  on conflict (job_id, form_template_id) where form_template_id is not null do nothing;
  return null;
end
$$;

create trigger jobs_attach_forms after insert on public.jobs
  for each row execute function public.jobs_attach_forms();

-- The previous customer's public upload folder <shop_id>/forms/<old token>/
-- may already hold a signature image they drew but never submitted. Nothing
-- can reference it any more (the old link is dead and an unsigned form has
-- no signature_path), so it is queued for the storage purge (0025) now;
-- otherwise the customer's image would outlive the form and the job.
create function public.jobs_sync_form_customer() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sub record;
begin
  if new.customer_id is distinct from old.customer_id then
    -- a new token: the /f link sent to the previous customer must not show
    -- (or let them sign) the new customer's form
    for v_sub in
      select fs.id, fs.public_token from public.form_submissions fs
       where fs.job_id = new.id and fs.shop_id = new.shop_id and fs.signed_at is null
       order by fs.id
       for update
    loop
      update public.form_submissions fs
         set customer_id = new.customer_id,
             public_token = gen_random_uuid()
       where fs.id = v_sub.id;
      perform public.queue_storage_purge(new.shop_id, 'signatures',
                                         new.shop_id::text || '/forms/' || v_sub.public_token::text || '/',
                                         true, 'form_token_rotated');
    end loop;
  end if;
  return null;
end
$$;

create trigger jobs_sync_form_customer after update of customer_id on public.jobs
  for each row execute function public.jobs_sync_form_customer();

-- A job keeps its customer while it carries that customer's signed forms,
-- inspections or invoices (void ones included; jobs_money_guard in 0012 also
-- covers payments). All contexts. Inspections (0022) and form signing lock
-- the job row FOR SHARE, and create_invoice_from_job locks it FOR UPDATE, so
-- none of them can slip in between this check and the move's commit.
create function public.jobs_customer_records_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.customer_id is distinct from old.customer_id then
    if exists (select 1 from public.form_submissions fs
               where fs.job_id = new.id and fs.shop_id = new.shop_id and fs.signed_at is not null) then
      raise exception 'this job has a form signed by its customer; its customer cannot change (book a new job instead)'
        using errcode = '23514';
    end if;
    if exists (select 1 from public.inspections i where i.job_id = new.id and i.shop_id = new.shop_id) then
      raise exception 'this job has a vehicle inspection of its customer; its customer cannot change (book a new job instead)'
        using errcode = '23514';
    end if;
    if exists (select 1 from public.invoices i where i.job_id = new.id and i.shop_id = new.shop_id and i.status = 'void') then
      raise exception 'this job has an invoice (void) issued to its customer; its customer cannot change (book a new job instead)'
        using errcode = '23514';
    end if;
  end if;
  return null;
end
$$;

create trigger jobs_customer_records_guard after update of customer_id on public.jobs
  for each row execute function public.jobs_customer_records_guard();

-- ---------------------------------------------------------------------------
-- Curated public view of a submission (no internal ids, notes, IPs or paths
-- beyond the caller's own upload prefix). The customer's name on file is
-- returned only to the signed-in client linked to that customer (null
-- otherwise): a form token can be reached through a booking token that
-- anyone can mint by typing an existing customer's email into the public
-- booking form, so the token alone proves nothing about who is reading.
-- ---------------------------------------------------------------------------
create function public.form_submission_public_json(p_submission_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', jsonb_build_object(
      'name', s.name,
      'slug', s.slug,
      'logo_path', s.logo_path,
      'brand_color', s.brand_color,
      'timezone', s.timezone),
    'form', jsonb_build_object(
      'title', fs.title,
      'body', fs.body_snapshot,
      'requires_signature', fs.requires_signature,
      'status', case
                  when fs.signed_at is not null then 'signed'
                  when j.status in ('cancelled', 'no_show') then 'void'
                  else 'pending'
                end,
      'signer_name', fs.signer_name,
      'signed_at', fs.signed_at),
    'job', jsonb_build_object(
      'number', j.number,
      'scheduled_start', j.scheduled_start,
      'scheduled_end', j.scheduled_end,
      'vehicle', nullif(btrim(concat_ws(' ', v.year::text, v.make, v.model)), '')),
    'customer', case when c.id is null or c.portal_user_id is null or c.portal_user_id is distinct from auth.uid()
                     then null else jsonb_build_object(
      'first_name', c.first_name,
      'last_name', c.last_name,
      'company', c.company) end,
    'signature_upload_prefix', case when fs.signed_at is null
                                    then fs.shop_id::text || '/forms/' || fs.public_token::text || '/' end)
  from public.form_submissions fs
  join public.shops s on s.id = fs.shop_id
  join public.jobs j on j.id = fs.job_id and j.shop_id = fs.shop_id
  left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
  left join public.customers c on c.id = fs.customer_id and c.shop_id = fs.shop_id
  where fs.id = p_submission_id
$$;

-- ---------------------------------------------------------------------------
-- Shared signing step (trusted internal helper). p_path_prefix is the
-- folder the signature image must live in.
-- ---------------------------------------------------------------------------
create function public.form_submission_sign(
  p_submission_id  uuid,
  p_signer_name    text,
  p_signature_path text,
  p_path_prefix    text
) returns public.form_submissions
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sub    public.form_submissions;
  v_status public.job_status;
  v_name   text := nullif(btrim(p_signer_name), '');
  v_path   text := nullif(btrim(p_signature_path), '');
begin
  select * into v_sub from public.form_submissions fs where fs.id = p_submission_id;
  if not found then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  -- job row first, then the submission: the lock order of a customer move
  -- (jobs_customer_records_guard / jobs_sync_form_customer)
  select j.status into v_status from public.jobs j
   where j.id = v_sub.job_id and j.shop_id = v_sub.shop_id
  for share;
  select * into v_sub from public.form_submissions fs where fs.id = p_submission_id for update;
  if not found then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  if v_sub.signed_at is not null then
    raise exception 'this form has already been signed' using errcode = '22023';
  end if;
  if v_status in ('cancelled', 'no_show') then
    raise exception 'this form is void because the appointment was cancelled' using errcode = '22023';
  end if;
  if v_name is null or char_length(v_name) > 200 then
    raise exception 'signer name is required (max 200 characters)' using errcode = '22023';
  end if;
  if v_path is null then
    if v_sub.requires_signature then
      raise exception 'a signature is required' using errcode = '22023';
    end if;
  else
    if not public.is_safe_storage_path(v_path)
       or left(v_path, char_length(p_path_prefix)) <> p_path_prefix
       or char_length(v_path) <= char_length(p_path_prefix) then
      raise exception 'the signature must be uploaded under %', p_path_prefix using errcode = '22023';
    end if;
    if not public.storage_object_exists('signatures', v_path) then
      raise exception 'upload the signature image before signing' using errcode = '22023';
    end if;
  end if;

  update public.form_submissions fs
     set signer_name = v_name,
         signature_path = v_path,
         signed_at = now(),
         signer_ip = public.form_signer_ip(),
         signed_by = auth.uid()
   where fs.id = v_sub.id
  returning * into v_sub;
  return v_sub;
end
$$;

-- ---------------------------------------------------------------------------
-- Public RPCs (anon + authenticated, keyed by the unguessable token)
-- ---------------------------------------------------------------------------
create function public.public_get_form(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select fs.id into v_id from public.form_submissions fs where fs.public_token = p_token;
  if v_id is null then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  return public.form_submission_public_json(v_id);
end
$$;

-- The signature (when required) must be uploaded first to
-- signatures/<shop_id>/forms/<token>/<file>, directly inside that folder.
create function public.public_sign_form(p_token uuid, p_signer_name text, p_signature_path text default null)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sub public.form_submissions;
begin
  select * into v_sub from public.form_submissions fs where fs.public_token = p_token;
  if not found then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  -- lock the job, then look the token up again: a customer move committed
  -- meanwhile re-tokenized the form, and this link is no longer its link
  perform 1 from public.jobs j where j.id = v_sub.job_id and j.shop_id = v_sub.shop_id for share;
  select * into v_sub from public.form_submissions fs where fs.public_token = p_token;
  if not found then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  -- staff below manager sign on device (sign_form_submission), never as the
  -- customer through the customer's link
  if auth.uid() is not null and public.is_shop_member(v_sub.shop_id) and not public.is_shop_manager(v_sub.shop_id)
     and not exists (select 1 from public.customers c
                      where c.id = v_sub.customer_id and c.shop_id = v_sub.shop_id and c.portal_user_id = auth.uid()) then
    raise exception 'staff collect signatures on their device, not through the customer''s link' using errcode = '42501';
  end if;
  -- directly inside the token folder: <shop_id>/forms/<token>/<file>
  if nullif(btrim(p_signature_path), '') is not null
     and cardinality(string_to_array(btrim(p_signature_path), '/')) <> 4 then
    raise exception 'the signature must be uploaded directly under %/forms/%/', v_sub.shop_id, p_token
      using errcode = '22023';
  end if;
  v_sub := public.form_submission_sign(v_sub.id, p_signer_name, p_signature_path,
                                       v_sub.shop_id::text || '/forms/' || v_sub.public_token::text || '/');
  return public.form_submission_public_json(v_sub.id);
end
$$;

-- Storage policy helper: may the caller upload this signature object for a
-- public form? True only for "<shop_id>/forms/<token>/<file>" of an unsigned,
-- non-void submission of that shop.
create function public.public_form_signature_upload_allowed(p_name text) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select public.is_safe_storage_path(p_name)
     and cardinality(string_to_array(p_name, '/')) = 4
     and split_part(p_name, '/', 2) = 'forms'
     and exists (
       select 1
       from public.form_submissions fs
       join public.jobs j on j.id = fs.job_id and j.shop_id = fs.shop_id
       where fs.shop_id = public.storage_path_uuid(p_name, 1)
         and fs.public_token = public.storage_path_uuid(p_name, 3)
         and fs.signed_at is null
         and j.status not in ('cancelled', 'no_show'))
$$;

-- ---------------------------------------------------------------------------
-- Staff signing on device (managers+ or technicians assigned to the job).
-- Returns the signed row without public_token (see the header).
-- ---------------------------------------------------------------------------
create function public.sign_form_submission(p_submission_id uuid, p_signer_name text,
                                            p_signature_path text default null)
returns public.form_submissions
language plpgsql security definer
set search_path = ''
as $$
declare
  v_sub public.form_submissions;
begin
  select * into v_sub from public.form_submissions fs where fs.id = p_submission_id;
  if not found or not public.is_shop_member(v_sub.shop_id) then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  if not public.can_work_job(v_sub.shop_id, v_sub.job_id) then
    raise exception 'only managers and staff assigned to this job can collect signatures' using errcode = '42501';
  end if;
  v_sub := public.form_submission_sign(v_sub.id, p_signer_name, p_signature_path, v_sub.shop_id::text || '/');
  v_sub.public_token := null;  -- the customer's credential: form_link_token
  return v_sub;
end
$$;

-- ---------------------------------------------------------------------------
-- form_link_token(submission_id) — the /f/<token> credential for staff who
-- may act for the customer (owner/admin/manager). Technicians: 42501.
-- Unknown submission or another shop's: P0002.
-- ---------------------------------------------------------------------------
create function public.form_link_token(p_submission_id uuid) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop  uuid;
  v_token uuid;
begin
  select fs.shop_id, fs.public_token into v_shop, v_token
    from public.form_submissions fs where fs.id = p_submission_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'form not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can share the form link' using errcode = '42501';
  end if;
  return v_token;
end
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.form_templates   enable row level security;
alter table public.form_submissions enable row level security;

create policy form_templates_select on public.form_templates for select to authenticated
  using (public.is_shop_member(shop_id));
create policy form_templates_insert on public.form_templates for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy form_templates_update on public.form_templates for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy form_templates_delete on public.form_templates for delete to authenticated
  using (public.is_shop_admin(shop_id));

create policy form_submissions_select on public.form_submissions for select to authenticated
  using (public.can_work_job(shop_id, job_id));
create policy form_submissions_insert on public.form_submissions for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy form_submissions_delete on public.form_submissions for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.form_templates, public.form_submissions from anon;
revoke truncate, trigger, references on public.form_templates, public.form_submissions from authenticated;
revoke update on public.form_submissions from authenticated;

-- form_submissions.public_token column privilege (see the header):
-- authenticated reads every column except the token. service_role keeps full
-- access; anon has no table access.
revoke select on public.form_submissions from authenticated;
do $$
declare
  v_cols text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.form_submissions'::regclass
     and a.attnum > 0
     and not a.attisdropped
     and a.attname <> 'public_token';
  execute format('grant select (%s) on public.form_submissions to authenticated', v_cols);
end
$$;

revoke execute on function public.form_link_token(uuid) from public, anon, service_role;
grant execute on function public.form_link_token(uuid) to authenticated;

revoke execute on function
  public.form_templates_normalize(),
  public.form_submissions_before_insert(),
  public.form_submissions_client_guard(),
  public.jobs_attach_forms(),
  public.jobs_sync_form_customer(),
  public.jobs_customer_records_guard()
from public, anon, authenticated;

revoke execute on function
  public.form_submission_public_json(uuid),
  public.form_submission_sign(uuid, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.form_submission_public_json(uuid),
  public.form_submission_sign(uuid, text, text, text)
to service_role;

revoke execute on function
  public.public_get_form(uuid),
  public.public_sign_form(uuid, text, text),
  public.public_form_signature_upload_allowed(text)
from public;
grant execute on function
  public.public_get_form(uuid),
  public.public_sign_form(uuid, text, text),
  public.public_form_signature_upload_allowed(text)
to anon, authenticated, service_role;

revoke execute on function public.sign_form_submission(uuid, text, text) from public, anon;
grant execute on function public.sign_form_submission(uuid, text, text) to authenticated, service_role;
