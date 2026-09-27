-- ============================================================================
-- 0021 — Field operations: checklist_templates, job_checklist_items,
-- auto-attach on job line items, apply_checklist_template RPC (SPEC §4.6).
--
-- Rules
--   * checklist_templates are part of the catalog: all members read,
--     owner/admin/manager write (SPEC §3 "Service catalog").
--   * items is a JSON array of {id, label}; missing ids are generated, labels
--     trimmed, ids unique within the template.
--   * job_checklist_items: managers+ full edit; technicians assigned to the
--     job may only tick/untick (done_at). done_at/done_by are server-stamped
--     for direct writes (the tick time and the acting user).
--   * Adding a line item whose service (or a service inside a package) has
--     templates attaches their items once per (job, template, item id) —
--     adding the same service twice never duplicates the checklist.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Validation of template items (IMMUTABLE so it can back a CHECK).
-- ---------------------------------------------------------------------------
create function public.checklist_items_valid(p_items jsonb) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_items is not null
     and jsonb_typeof(p_items) = 'array'
     and jsonb_array_length(p_items) <= 200
     and not exists (
       select 1
       from jsonb_array_elements(p_items) e(item)
       where jsonb_typeof(e.item) <> 'object'
          or exists (select 1 from jsonb_object_keys(e.item) k where k not in ('id', 'label'))
          or jsonb_typeof(e.item -> 'id') is distinct from 'string'
          or (e.item ->> 'id') !~ '^[A-Za-z0-9_-]{1,64}$'
          or jsonb_typeof(e.item -> 'label') is distinct from 'string'
          or char_length(btrim(e.item ->> 'label')) not between 1 and 200
          or (e.item ->> 'label') <> btrim(e.item ->> 'label'))
     and (select count(distinct e.item ->> 'id') from jsonb_array_elements(p_items) e(item))
         = jsonb_array_length(p_items)
$$;

-- ---------------------------------------------------------------------------
-- checklist_templates
-- ---------------------------------------------------------------------------
create table public.checklist_templates (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 120),
  items       jsonb not null default '[]'::jsonb
                constraint checklist_templates_items_valid check (public.checklist_items_valid(items)),
  service_id  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint checklist_templates_shop_id_id_key unique (shop_id, id),
  constraint checklist_templates_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete set null (service_id)
);
create index checklist_templates_shop_service_idx on public.checklist_templates (shop_id, service_id);

comment on column public.checklist_templates.service_id is
  'When set, the template''s items are attached automatically to jobs that get a line item for this service (or a package containing it).';

-- Normalize items: generate missing ids, trim labels. Anything that is not
-- the expected shape is left untouched for the CHECK to reject.
create function public.checklist_templates_normalize() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  if jsonb_typeof(new.items) = 'array' then
    select coalesce(jsonb_agg(
             case
               when jsonb_typeof(x.item) = 'object' then
                 x.item
                 || case when x.item -> 'id' is null or jsonb_typeof(x.item -> 'id') = 'null'
                         then jsonb_build_object('id', gen_random_uuid()::text)
                         else '{}'::jsonb end
                 || case when jsonb_typeof(x.item -> 'label') = 'string'
                         then jsonb_build_object('label', btrim(x.item ->> 'label'))
                         else '{}'::jsonb end
               else x.item
             end order by x.ord), '[]'::jsonb)
      into new.items
      from jsonb_array_elements(new.items) with ordinality as x(item, ord);
  end if;
  return new;
end
$$;

create trigger checklist_templates_10_prevent_shop_change before update on public.checklist_templates
  for each row execute function public.prevent_shop_change();
create trigger checklist_templates_20_normalize before insert or update on public.checklist_templates
  for each row execute function public.checklist_templates_normalize();
create trigger checklist_templates_90_set_updated_at before update on public.checklist_templates
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- job_checklist_items
-- ---------------------------------------------------------------------------
create table public.job_checklist_items (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  job_id            uuid not null,
  label             text not null check (char_length(btrim(label)) between 1 and 200),
  sort              integer not null default 0,
  done_at           timestamptz,
  done_by           uuid references auth.users (id) on delete set null,
  template_id       uuid,
  template_item_id  text check (template_item_id is null or template_item_id ~ '^[A-Za-z0-9_-]{1,64}$'),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint job_checklist_items_shop_id_id_key unique (shop_id, id),
  constraint job_checklist_items_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade,
  constraint job_checklist_items_template_fk foreign key (shop_id, template_id)
    references public.checklist_templates (shop_id, id) on delete set null (template_id),
  constraint job_checklist_items_template_item check (template_id is null or template_item_id is not null),
  constraint job_checklist_items_done_by check (done_at is not null or done_by is null)
);
create index job_checklist_items_shop_job_idx on public.job_checklist_items (shop_id, job_id, sort);
create index job_checklist_items_shop_template_idx on public.job_checklist_items (shop_id, template_id);
create index job_checklist_items_done_by_idx on public.job_checklist_items (done_by);
-- one copy of each template item per job
create unique index job_checklist_items_template_item_key
  on public.job_checklist_items (job_id, template_id, template_item_id)
  where template_id is not null;

comment on column public.job_checklist_items.done_by is 'auth user who ticked the item (server-stamped).';

-- Direct (PostgREST) writes. SECURITY INVOKER so trusted code (definer RPCs,
-- triggers, service_role) is not client context.
create function public.job_checklist_items_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_allowed constant text[] := array['done_at', 'done_by', 'updated_at'];
begin
  if not public.is_client_context() then
    if new.done_at is null then
      new.done_by := null;
    end if;
    return new;
  end if;

  new.label := btrim(new.label);
  if tg_op = 'INSERT' then
    -- template linkage is maintained by the server only
    new.template_id := null;
    new.template_item_id := null;
    if new.done_at is not null then
      new.done_at := now();
      new.done_by := auth.uid();
    else
      new.done_by := null;
    end if;
    return new;
  end if;

  if new.job_id <> old.job_id then
    raise exception 'checklist items cannot move to another job' using errcode = '42501';
  end if;
  if new.template_id is distinct from old.template_id
     or new.template_item_id is distinct from old.template_item_id then
    raise exception 'checklist template links are maintained by the server' using errcode = '42501';
  end if;

  -- done_at is a toggle: the server records when and by whom.
  if new.done_at is null then
    new.done_by := null;
  elsif old.done_at is null then
    new.done_at := now();
    new.done_by := auth.uid();
  else
    new.done_at := old.done_at;
    new.done_by := old.done_by;
  end if;

  if not public.is_shop_manager(old.shop_id)
     and (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'technicians can only tick checklist items on their assigned jobs' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger job_checklist_items_05_prevent_shop_change before update on public.job_checklist_items
  for each row execute function public.prevent_shop_change();
create trigger job_checklist_items_10_client_guard before insert or update on public.job_checklist_items
  for each row execute function public.job_checklist_items_client_guard();
create trigger job_checklist_items_90_set_updated_at before update on public.job_checklist_items
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Attaching template items to a job (trusted internal helper). Items are
-- appended after the job's current last item; items already attached from
-- the same template are skipped. Returns the inserted rows.
-- ---------------------------------------------------------------------------
create function public.checklist_attach_template(p_shop_id uuid, p_job_id uuid, p_template_id uuid)
returns setof public.job_checklist_items
language plpgsql security definer
set search_path = ''
as $$
declare
  v_base integer;
begin
  select coalesce(max(ci.sort), 0) into v_base
    from public.job_checklist_items ci
   where ci.job_id = p_job_id and ci.shop_id = p_shop_id;

  return query
    with ins as (
      insert into public.job_checklist_items as ci (shop_id, job_id, label, sort, template_id, template_item_id)
      select p_shop_id, p_job_id, x.item ->> 'label', v_base + x.ord::integer, t.id, x.item ->> 'id'
      from public.checklist_templates t
      cross join lateral jsonb_array_elements(t.items) with ordinality as x(item, ord)
      where t.id = p_template_id and t.shop_id = p_shop_id
      order by x.ord
      on conflict (job_id, template_id, template_item_id) where template_id is not null do nothing
      returning ci.*)
    select * from ins order by ins.sort;
end
$$;

-- AFTER INSERT / UPDATE OF service_id on job_line_items.
create function public.job_line_items_attach_checklists() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_template uuid;
begin
  if new.service_id is null
     or (tg_op = 'UPDATE' and new.service_id is not distinct from old.service_id) then
    return null;
  end if;
  for v_template in
    select t.id
    from public.checklist_templates t
    where t.shop_id = new.shop_id
      and (t.service_id = new.service_id
           or t.service_id in (select pi.service_id from public.package_items pi
                               where pi.package_id = new.service_id and pi.shop_id = new.shop_id))
    order by t.created_at, t.id
  loop
    perform public.checklist_attach_template(new.shop_id, new.job_id, v_template);
  end loop;
  return null;
end
$$;

create trigger job_line_items_attach_checklists after insert or update of service_id on public.job_line_items
  for each row execute function public.job_line_items_attach_checklists();

-- ---------------------------------------------------------------------------
-- RPC: apply_checklist_template (manager+). Returns the newly added items.
-- ---------------------------------------------------------------------------
create function public.apply_checklist_template(p_job_id uuid, p_template_id uuid)
returns setof public.job_checklist_items
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select j.shop_id into v_shop from public.jobs j where j.id = p_job_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can apply checklist templates' using errcode = '42501';
  end if;
  if not exists (select 1 from public.checklist_templates t where t.id = p_template_id and t.shop_id = v_shop) then
    raise exception 'checklist template not found' using errcode = 'P0002';
  end if;
  return query select * from public.checklist_attach_template(v_shop, p_job_id, p_template_id);
end
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.checklist_templates enable row level security;
alter table public.job_checklist_items enable row level security;

create policy checklist_templates_select on public.checklist_templates for select to authenticated
  using (public.is_shop_member(shop_id));
create policy checklist_templates_insert on public.checklist_templates for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy checklist_templates_update on public.checklist_templates for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy checklist_templates_delete on public.checklist_templates for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy job_checklist_items_select on public.job_checklist_items for select to authenticated
  using (public.can_work_job(shop_id, job_id));
create policy job_checklist_items_insert on public.job_checklist_items for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy job_checklist_items_update on public.job_checklist_items for update to authenticated
  using (public.can_work_job(shop_id, job_id)) with check (public.can_work_job(shop_id, job_id));
create policy job_checklist_items_delete on public.job_checklist_items for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on public.checklist_templates, public.job_checklist_items from anon;
revoke truncate, trigger, references on public.checklist_templates, public.job_checklist_items from authenticated;

revoke execute on function
  public.checklist_templates_normalize(),
  public.job_checklist_items_client_guard(),
  public.job_line_items_attach_checklists(),
  public.checklist_attach_template(uuid, uuid, uuid)
from public, anon, authenticated;
grant execute on function public.checklist_attach_template(uuid, uuid, uuid) to service_role;

revoke execute on function public.apply_checklist_template(uuid, uuid) from public, anon;
grant execute on function public.apply_checklist_template(uuid, uuid) to authenticated, service_role;
