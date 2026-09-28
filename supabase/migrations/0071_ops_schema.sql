-- ============================================================================
-- 0071 — Field operations v2 schema (range 0070-0079). Every new table,
-- column, bucket, CHECK replacement, index, RLS policy, grant and backfill of
-- the range lives here; the behaviour files after it (0072-0078) add
-- functions and triggers and may use any of these columns.
--
-- Tenancy rules as everywhere: shop_id + RLS on every table, UNIQUE
-- (shop_id, id), composite (shop_id, x) foreign keys between tenant tables,
-- an index behind every foreign key, no anon access, no TRUNCATE / TRIGGER /
-- REFERENCES for API roles.
--
--   P-8   job_reports (own token: /r/<token>), job_photos.customer_visible,
--         inspections.signed_remotely, shops.techs_can_share_reports
--   P-11  checklist_templates.required, job_checklist_items.required,
--         services.min_before_photos / min_after_photos, job_gate_overrides
--   P-20  customers.merged_into_id, customer_payment_methods.stripe_customer_id
--   P-25  documents + bucket documents (25 MiB)
--   P-28  products, service_consumables, inventory_movements
--   P-30  job_photos media columns + bucket job-media (200 MiB, videos)
--
-- Storage (object names are stored WITHOUT the bucket):
--   documents   <shop_id>/customers/<customer_id>/<file>   customer files
--               <shop_id>/jobs/<job_id>/<file>             job files
--   job-media   <shop_id>/<job_id>/v-<file>                job videos
--   signatures  <shop_id>/reports/<report token>/<file>    remote inspection
--                                                           sign-off (0072)
-- Uploads over 6 MB use the resumable (TUS) endpoint; the hosted project's
-- global upload limit must be at least 200 MiB for job videos.
--
-- Customer merge (P-20, 0074): every customer_id column added here is moved
-- by merge_customers (documents.customer_id).
-- ============================================================================

-- ===========================================================================
-- Columns on existing tables (ALTER TABLE ADD COLUMN only)
-- ===========================================================================

-- P-8: photos shown on the customer-facing job report
alter table public.job_photos
  add column customer_visible boolean not null default false,
  -- P-30: videos live in the job-media bucket, images in job-photos
  add column media_type text not null default 'image' check (media_type in ('image', 'video')),
  add column bucket text not null default 'job-photos' check (bucket in ('job-photos', 'job-media')),
  add column duration_seconds integer check (duration_seconds is null or duration_seconds between 1 and 600),
  add column poster_path text check (poster_path is null or public.is_safe_storage_path(poster_path)),
  add constraint job_photos_media_bucket check ((media_type = 'video') = (bucket = 'job-media')),
  add constraint job_photos_video_extras check (media_type = 'video' or (duration_seconds is null and poster_path is null));

comment on column public.job_photos.customer_visible is
  'Shown on the customer-facing job report (/r/<token>) when its kind is one of the report''s photo_kinds.';
comment on column public.job_photos.media_type is 'image (bucket job-photos) or video (bucket job-media).';
comment on column public.job_photos.bucket is 'Storage bucket of storage_path: job-photos for images, job-media for videos.';
comment on column public.job_photos.duration_seconds is 'Video length in seconds (1-600).';
comment on column public.job_photos.poster_path is
  'Video poster frame: a JPEG in the job-photos bucket under <shop_id>/<job_id>/.';

-- P-8: the customer acknowledged a pre-inspection from the job report link
alter table public.inspections
  add column signed_remotely boolean not null default false,
  add constraint inspections_signed_remotely_signed check (not signed_remotely or signed_at is not null);
comment on column public.inspections.signed_remotely is
  'The customer signed this inspection from the job report link (public_ack_inspection), not on a staff device. Server-set.';

-- P-8: technicians assigned to a job may publish / share its report
alter table public.shops
  add column techs_can_share_reports boolean not null default false;
comment on column public.shops.techs_can_share_reports is
  'When true, technicians assigned to a job may publish and share its customer-facing job report.';

-- P-11: required checklists and photo minimums block completion
alter table public.checklist_templates
  add column required boolean not null default false;
comment on column public.checklist_templates.required is
  'Items attached from this template must be ticked before the job can be completed (a manager can override).';
alter table public.job_checklist_items
  add column required boolean not null default false;
comment on column public.job_checklist_items.required is
  'Must be ticked before the job can be completed. Copied from the template; managers may flag ad-hoc items.';

alter table public.services
  add column min_before_photos smallint not null default 0 check (min_before_photos between 0 and 20),
  add column min_after_photos smallint not null default 0 check (min_after_photos between 0 and 20);
comment on column public.services.min_before_photos is
  'Minimum number of "before" photos a job with this service needs before it can start (in_progress).';
comment on column public.services.min_after_photos is
  'Minimum number of "after" photos a job with this service needs before it can be completed.';

-- P-20: a merged duplicate points at the surviving customer (server-set)
alter table public.customers
  add column merged_into_id uuid,
  add constraint customers_merged_into_fk foreign key (shop_id, merged_into_id)
    references public.customers (shop_id, id) on delete set null (merged_into_id),
  add constraint customers_merged_into_self check (merged_into_id is distinct from id);
create index customers_shop_merged_into_idx on public.customers (shop_id, merged_into_id);
comment on column public.customers.merged_into_id is
  'Set by merge_customers on the archived duplicate: the customer its records were moved to. Server-set only.';

-- P-20: the Stripe customer a saved card is attached to, so a card moved by
-- a merge keeps charging on the Stripe customer that owns it
alter table public.customer_payment_methods
  add column stripe_customer_id text
    check (stripe_customer_id is null or stripe_customer_id ~ '^cus_[A-Za-z0-9]+$');
comment on column public.customer_payment_methods.stripe_customer_id is
  'Stripe customer the payment method is attached to (filled from the owning customer on insert). Charge the card on this Stripe customer: after a merge it can differ from customers.stripe_customer_id.';

update public.customer_payment_methods pm
   set stripe_customer_id = c.stripe_customer_id
  from public.customers c
 where c.id = pm.customer_id and c.shop_id = pm.shop_id
   and pm.stripe_customer_id is null and c.stripe_customer_id is not null;

-- ===========================================================================
-- P-8 job_reports — the customer-facing report of a job. Its token is its
-- OWN credential (never jobs.public_token, which grants cancel rights); at
-- most one live (not revoked) report per job.
-- ===========================================================================
create table public.job_reports (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  job_id               uuid not null,
  token                uuid not null default gen_random_uuid() unique,
  include_inspections  boolean not null default true,
  photo_kinds          public.job_photo_kind[] not null default '{before,after}'
                         check (array_position(photo_kinds, null) is null and cardinality(photo_kinds) <= 4),
  message              text check (message is null or char_length(message) <= 2000),
  published_at         timestamptz not null default now(),
  published_by         uuid references auth.users (id) on delete set null,
  revoked_at           timestamptz,
  first_viewed_at      timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint job_reports_shop_id_id_key unique (shop_id, id),
  constraint job_reports_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade
);
create index job_reports_shop_job_idx on public.job_reports (shop_id, job_id);
create unique index job_reports_one_live on public.job_reports (job_id) where revoked_at is null;
create index job_reports_published_by_idx on public.job_reports (published_by);

comment on table public.job_reports is
  'Customer-facing job report (/r/<token>): chosen photo kinds, inspections, customer-visible documents. Written only by publish_job_report / revoke_job_report.';
comment on column public.job_reports.token is
  'The report link credential (/r/<token>). Readable by managers and, when the shop allows it, technicians on the job.';

-- ===========================================================================
-- P-11 job_gate_overrides — a manager moved a job past its completion gates
-- (set_job_status with p_force); blockers is the snapshot that was waived.
-- ===========================================================================
create table public.job_gate_overrides (
  id             uuid primary key default gen_random_uuid(),
  shop_id        uuid not null references public.shops (id) on delete cascade,
  job_id         uuid not null,
  to_status      public.job_status not null,
  reason         text check (reason is null or char_length(reason) <= 500),
  blockers       jsonb not null check (jsonb_typeof(blockers) = 'object'),
  overridden_by  uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  constraint job_gate_overrides_shop_id_id_key unique (shop_id, id),
  constraint job_gate_overrides_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade
);
create index job_gate_overrides_shop_job_idx on public.job_gate_overrides (shop_id, job_id, created_at);
create index job_gate_overrides_overridden_by_idx on public.job_gate_overrides (overridden_by);

-- ===========================================================================
-- P-25 documents — uploaded files on customers and jobs. A job document's
-- customer_id is always the job's customer (filled on insert, follows the
-- job); a customer document has no job.
-- ===========================================================================
create table public.documents (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  customer_id       uuid,
  job_id            uuid,
  storage_path      text not null check (public.is_safe_storage_path(storage_path)),
  file_name         text not null check (char_length(btrim(file_name)) between 1 and 255),
  content_type      text not null check (char_length(content_type) between 1 and 120),
  size_bytes        bigint not null check (size_bytes between 0 and 26214400),
  customer_visible  boolean not null default false,
  uploaded_by       uuid references auth.users (id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint documents_shop_id_id_key unique (shop_id, id),
  constraint documents_storage_path_key unique (shop_id, storage_path),
  constraint documents_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint documents_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint documents_has_owner check (customer_id is not null or job_id is not null)
);
create index documents_shop_customer_idx on public.documents (shop_id, customer_id, created_at);
create index documents_shop_job_idx on public.documents (shop_id, job_id, created_at);
create index documents_uploaded_by_idx on public.documents (uploaded_by);

comment on table public.documents is
  'Files (PDF, Word, Excel, text, images) on customers and jobs, stored in the documents bucket: <shop_id>/customers/<customer_id>/<file> or <shop_id>/jobs/<job_id>/<file>.';
comment on column public.documents.customer_id is
  'The customer the file belongs to. For job files it is always the job''s customer (filled by the server).';
comment on column public.documents.customer_visible is
  'Shown to the customer on the job report, booking page and client portal.';

-- ===========================================================================
-- P-28 inventory
-- ===========================================================================
create table public.products (
  id                     uuid primary key default gen_random_uuid(),
  shop_id                uuid not null references public.shops (id) on delete cascade,
  name                   text not null check (char_length(btrim(name)) between 1 and 120),
  sku                    text check (sku is null or char_length(btrim(sku)) between 1 and 60),
  unit                   text not null check (char_length(btrim(unit)) between 1 and 20),
  unit_cost_cents        bigint not null default 0 check (unit_cost_cents >= 0),
  on_hand                numeric(12, 3) not null default 0,
  reorder_at             numeric(12, 3) check (reorder_at is null or reorder_at >= 0),
  reorder_qty            numeric(12, 3) check (reorder_qty is null or reorder_qty > 0),
  supplier               text check (supplier is null or char_length(supplier) <= 120),
  notes                  text check (notes is null or char_length(notes) <= 5000),
  active                 boolean not null default true,
  archived_at            timestamptz,
  low_stock_notified_at  timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint products_shop_id_id_key unique (shop_id, id)
);
create unique index products_shop_sku_key on public.products (shop_id, lower(sku)) where sku is not null;
create index products_shop_name_idx on public.products (shop_id, name);

comment on table public.products is
  'Consumables and retail stock. on_hand changes only through the inventory ledger (record_inventory_movement, job completion). Costs are entered by the shop.';
comment on column public.products.on_hand is
  'Current stock in the product''s unit. Server-maintained from inventory_movements; may go below zero.';
comment on column public.products.low_stock_notified_at is
  'When managers were told the product reached its reorder level; cleared once stock rises above it. Server-set.';

create table public.service_consumables (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  service_id           uuid not null,
  vehicle_category_id  uuid,
  product_id           uuid not null,
  quantity             numeric(12, 3) not null check (quantity > 0),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint service_consumables_shop_id_id_key unique (shop_id, id),
  constraint service_consumables_rule_key unique nulls not distinct (service_id, vehicle_category_id, product_id),
  constraint service_consumables_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete cascade,
  constraint service_consumables_category_fk foreign key (shop_id, vehicle_category_id)
    references public.vehicle_categories (shop_id, id) on delete cascade,
  constraint service_consumables_product_fk foreign key (shop_id, product_id)
    references public.products (shop_id, id) on delete cascade
);
create index service_consumables_shop_service_idx on public.service_consumables (shop_id, service_id);
create index service_consumables_shop_category_idx on public.service_consumables (shop_id, vehicle_category_id);
create index service_consumables_shop_product_idx on public.service_consumables (shop_id, product_id);

comment on table public.service_consumables is
  'Materials a service uses per unit of line quantity. vehicle_category_id null = every category; a category-specific rule for the same product wins.';

create table public.inventory_movements (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops (id) on delete cascade,
  product_id       uuid not null,
  kind             public.inventory_movement_kind not null,
  quantity         numeric(12, 3) not null,
  unit_cost_cents  bigint check (unit_cost_cents is null or unit_cost_cents >= 0),
  job_id           uuid,
  allocation       jsonb,
  note             text check (note is null or char_length(note) <= 500),
  created_by       uuid references auth.users (id) on delete set null,
  created_at       timestamptz not null default now(),
  constraint inventory_movements_shop_id_id_key unique (shop_id, id),
  constraint inventory_movements_product_fk foreign key (shop_id, product_id)
    references public.products (shop_id, id) on delete cascade,
  constraint inventory_movements_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id),
  constraint inventory_movements_sign check (
    case kind
      when 'receive' then quantity > 0
      when 'consume' then quantity < 0
      when 'adjust'  then quantity <> 0
      else true
    end),
  constraint inventory_movements_job_consume check (kind = 'consume' or job_id is null),
  constraint inventory_movements_allocation check (
    allocation is null or (kind = 'consume' and jsonb_typeof(allocation) = 'object'))
);
create index inventory_movements_shop_product_idx on public.inventory_movements (shop_id, product_id, created_at);
create index inventory_movements_shop_job_idx on public.inventory_movements (shop_id, job_id);
create index inventory_movements_created_by_idx on public.inventory_movements (created_by);
-- consume: one movement per product when the job is completed, plus one for
-- materials of lines added or changed afterwards (0077). Deduplication is by
-- the per-service allocation under the job's row lock, not a unique index.

comment on table public.inventory_movements is
  'Inventory ledger. quantity is signed (receive +, consume -, adjust +/-, count = the delta to the counted level). Written only by record_inventory_movement and job completion.';
comment on column public.inventory_movements.unit_cost_cents is
  'receive: purchase cost per unit (updates the product cost); consume: the product cost when the materials were consumed (job completion, or a line added to a completed job).';
comment on column public.inventory_movements.allocation is
  'consume: {"<line service_id>": quantity, ...} — how much of this product each service of the job used (job/service profit).';

-- ===========================================================================
-- Buckets
-- ===========================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('documents', 'documents', false, 26214400,
   array['application/pdf', 'application/msword',
         'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
         'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
         'text/plain', 'text/csv', 'image/jpeg', 'image/png', 'image/webp', 'image/heic']),
  ('job-media', 'job-media', false, 209715200,
   array['video/mp4', 'video/quicktime'])
on conflict (id) do update
  set name = excluded.name,
      public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ===========================================================================
-- Storage policies (existing helpers only; the public report signature
-- policy needs a function of 0072 and lives there).
-- ===========================================================================
drop policy if exists ops_documents_select on storage.objects;
drop policy if exists ops_documents_insert on storage.objects;
drop policy if exists ops_documents_update on storage.objects;
drop policy if exists ops_documents_delete on storage.objects;
drop policy if exists ops_job_media_select on storage.objects;
drop policy if exists ops_job_media_insert on storage.objects;
drop policy if exists ops_job_media_update on storage.objects;
drop policy if exists ops_job_media_delete on storage.objects;

-- documents: managers+ everything under the shop folder; technicians the
-- job folders of jobs they work (read, upload, delete their own uploads).
-- Customer folders are manager-only. Overwrites are manager-only.
create policy ops_documents_select on storage.objects for select to authenticated
  using (bucket_id = 'documents'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or (split_part(name, '/', 2) = 'jobs'
                  and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 3)))));

create policy ops_documents_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents'
              and public.is_safe_storage_path(name)
              and cardinality(string_to_array(name, '/')) = 4
              and public.storage_path_uuid(name, 3) is not null
              and ((split_part(name, '/', 2) = 'customers'
                    and public.is_shop_manager(public.storage_path_uuid(name, 1)))
                   or (split_part(name, '/', 2) = 'jobs'
                       and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 3)))));

create policy ops_documents_update on storage.objects for update to authenticated
  using (bucket_id = 'documents' and public.is_shop_manager(public.storage_path_uuid(name, 1)))
  with check (bucket_id = 'documents'
              and public.is_safe_storage_path(name)
              and cardinality(string_to_array(name, '/')) = 4
              and split_part(name, '/', 2) in ('customers', 'jobs')
              and public.storage_path_uuid(name, 3) is not null
              and public.is_shop_manager(public.storage_path_uuid(name, 1)));

create policy ops_documents_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and split_part(name, '/', 2) = 'jobs'
                  and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 3)))));

-- job-media: the job-photos rules (0025) for videos, directly inside the job
-- folder <shop_id>/<job_id>/<file>. Signed evidence does not apply (damage
-- marks and signatures are images).
create policy ops_job_media_select on storage.objects for select to authenticated
  using (bucket_id = 'job-media'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1)))));

create policy ops_job_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'job-media'
              and public.is_safe_storage_path(name)
              and cardinality(string_to_array(name, '/')) = 3
              and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)));

create policy ops_job_media_update on storage.objects for update to authenticated
  using (bucket_id = 'job-media'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)))))
  with check (bucket_id = 'job-media'
              and public.is_safe_storage_path(name)
              and cardinality(string_to_array(name, '/')) = 3
              and (public.is_shop_manager(public.storage_path_uuid(name, 1))
                   or ((owner_id = auth.uid()::text or owner = auth.uid())
                       and public.can_work_job(public.storage_path_uuid(name, 1), public.storage_path_uuid(name, 2)))));

create policy ops_job_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'job-media'
         and (public.is_shop_manager(public.storage_path_uuid(name, 1))
              or ((owner_id = auth.uid()::text or owner = auth.uid())
                  and public.is_shop_member(public.storage_path_uuid(name, 1)))));

-- ===========================================================================
-- Storage purge queue (0025): the new buckets, reasons and folder kinds.
--   prefixes: <shop>/, <shop>/<job>/, <shop>/forms/<token>/,
--             <shop>/customers/<customer>/, <shop>/jobs/<job>/,
--             <shop>/reports/<report token>/
-- ===========================================================================
alter table public.storage_purge_requests
  drop constraint storage_purge_requests_bucket_id_check,
  drop constraint storage_purge_requests_reason_check,
  drop constraint storage_purge_requests_path_check;
alter table public.storage_purge_requests
  add constraint storage_purge_requests_bucket_id_check
    check (bucket_id in ('job-photos', 'signatures', 'shop-assets', 'documents', 'job-media')),
  add constraint storage_purge_requests_reason_check
    check (reason in ('shop_deleted', 'job_deleted', 'inspection_deleted', 'form_deleted', 'form_token_rotated',
                      'document_deleted', 'media_deleted', 'customer_deleted', 'report_revoked')),
  add constraint storage_purge_requests_path_check check (
    case when is_prefix
      then path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/((forms/|customers/|jobs/|reports/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/)?$'
      else public.is_safe_storage_path(path)
    end
    and public.storage_path_uuid(path, 1) = shop_id);

comment on table public.storage_purge_requests is
  'Storage folders/objects of deleted shops, jobs, customers, inspections, forms, documents, videos and revoked job reports, removed by the storage-purge edge function through the Storage API.';

-- ===========================================================================
-- Generic triggers (behaviour triggers live with their functions, 0072+)
-- ===========================================================================
create trigger job_reports_05_prevent_shop_change before update on public.job_reports
  for each row execute function public.prevent_shop_change();
create trigger job_reports_90_set_updated_at before update on public.job_reports
  for each row execute function public.set_updated_at();
create trigger job_gate_overrides_05_prevent_shop_change before update on public.job_gate_overrides
  for each row execute function public.prevent_shop_change();
create trigger documents_05_prevent_shop_change before update on public.documents
  for each row execute function public.prevent_shop_change();
create trigger documents_90_set_updated_at before update on public.documents
  for each row execute function public.set_updated_at();
create trigger products_05_prevent_shop_change before update on public.products
  for each row execute function public.prevent_shop_change();
create trigger products_90_set_updated_at before update on public.products
  for each row execute function public.set_updated_at();
create trigger service_consumables_05_prevent_shop_change before update on public.service_consumables
  for each row execute function public.prevent_shop_change();
create trigger service_consumables_90_set_updated_at before update on public.service_consumables
  for each row execute function public.set_updated_at();
create trigger inventory_movements_05_prevent_shop_change before update on public.inventory_movements
  for each row execute function public.prevent_shop_change();

-- ===========================================================================
-- RLS
-- ===========================================================================
alter table public.job_reports         enable row level security;
alter table public.job_gate_overrides  enable row level security;
alter table public.documents           enable row level security;
alter table public.products            enable row level security;
alter table public.service_consumables enable row level security;
alter table public.inventory_movements enable row level security;

-- the report token is a credential: managers+, and technicians on the job
-- only when the shop lets technicians share reports
create policy job_reports_select on public.job_reports for select to authenticated
  using (public.is_shop_manager(shop_id)
         or (public.can_work_job(shop_id, job_id)
             and exists (select 1 from public.shops s where s.id = job_reports.shop_id and s.techs_can_share_reports)));

create policy job_gate_overrides_select on public.job_gate_overrides for select to authenticated
  using (public.can_work_job(shop_id, job_id));

create policy documents_select on public.documents for select to authenticated
  using (public.is_shop_manager(shop_id) or (job_id is not null and public.can_work_job(shop_id, job_id)));
create policy documents_insert on public.documents for insert to authenticated
  with check (public.is_shop_manager(shop_id) or (job_id is not null and public.can_work_job(shop_id, job_id)));
create policy documents_update on public.documents for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy documents_delete on public.documents for delete to authenticated
  using (public.is_shop_manager(shop_id)
         or (uploaded_by = auth.uid() and job_id is not null and public.can_work_job(shop_id, job_id)));

create policy products_select on public.products for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy products_insert on public.products for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy products_update on public.products for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy products_delete on public.products for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy service_consumables_select on public.service_consumables for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy service_consumables_insert on public.service_consumables for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy service_consumables_update on public.service_consumables for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy service_consumables_delete on public.service_consumables for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy inventory_movements_select on public.inventory_movements for select to authenticated
  using (public.is_shop_manager(shop_id));

-- ===========================================================================
-- Grants: no anon access; API roles never TRUNCATE / TRIGGER / REFERENCES;
-- server-maintained tables have no client writes.
-- ===========================================================================
do $$
declare
  t text;
begin
  foreach t in array array['job_reports', 'job_gate_overrides', 'documents', 'products', 'service_consumables',
                           'inventory_movements'] loop
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke truncate, trigger, references on public.%I from authenticated', t);
  end loop;
end
$$;

revoke insert, update, delete on public.job_reports, public.job_gate_overrides, public.inventory_movements
  from authenticated;
-- documents: only the display name and the customer visibility are editable
revoke update on public.documents from authenticated;
grant update (file_name, customer_visible) on public.documents to authenticated;
