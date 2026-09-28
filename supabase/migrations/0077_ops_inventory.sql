-- ============================================================================
-- 0077 — Inventory: consumables per service, automatic deduction on job
-- completion, low-stock alerts (P-28). Job / service profit reports: 0078.
--
-- products.on_hand is maintained by the ledger (inventory_movements):
--   record_inventory_movement(product, kind, quantity, cost, note)
--     manager+; receive (+, optionally with the purchase cost per unit,
--     which becomes the product's cost), adjust (+/-), count (the counted
--     absolute level; stored as the delta). 'consume' is automatic only.
--   job completion (jobs_zz_ops_consume_inventory, AFTER UPDATE OF status
--     to 'completed'): for each line with a service — packages add the
--     rules of the services they include — the service's consumables for
--     the line vehicle's category (else the job vehicle's; a category rule
--     for a product wins over the every-category rule for it) times the line
--     quantity. The movement stores the product's current cost and how much
--     each line service used (allocation), for the profit reports. Archived /
--     inactive products are skipped.
--   A job that is ALREADY completed consumes too, so a walk-in recorded
--     after the fact (inserted as 'completed', lines added afterwards) and a
--     service line added to a completed job use up their materials:
--     job_line_items_zz_ops_consume_inventory (AFTER INSERT / UPDATE OF
--     job_id, service_id, quantity, vehicle_id while the job is completed)
--     and a vehicle change on a completed job run the same deduction.
--   The deduction is a top-up, per product and line service: what the job's
--     lines need now minus what the job's consume movements already
--     allocated to that service. Completing a job again never deducts twice;
--     a change after completion deducts only what is new; nothing is ever
--     restored (moving a job back from completed, or removing / lowering a
--     line after completion — the materials were used). One movement per
--     product and deduction. The job's row lock (the status update itself,
--     or the line's job touch) serializes concurrent deductions.
--   A new product's opening on_hand is recorded as a 'count' movement.
--   Direct writes never change on_hand or low_stock_notified_at.
--
-- Low stock: when a movement takes on_hand to reorder_at or below, active
-- owners/admins/managers get one 'low_stock' notification
-- (low_stock_notified_at); it re-arms once stock rises above reorder_at.
--   low_stock_products(shop)  manager+: active products at or below their
--                             reorder level.
-- Quantities are numeric(12,3) in the product's unit; costs are integer
-- cents entered by the shop (never invented; default 0).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- products: normalization and the server-maintained columns.
-- ---------------------------------------------------------------------------
create function public.products_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  new.unit := btrim(new.unit);
  new.sku := nullif(btrim(new.sku), '');
  new.supplier := nullif(btrim(new.supplier), '');
  if public.is_client_context() then
    if tg_op = 'INSERT' then
      new.low_stock_notified_at := null;
    else
      new.on_hand := old.on_hand;
      new.low_stock_notified_at := old.low_stock_notified_at;
    end if;
  end if;
  -- the alert re-arms whenever the product is no longer low
  if new.reorder_at is null or new.on_hand > new.reorder_at then
    new.low_stock_notified_at := null;
  end if;
  return new;
end
$$;

create trigger products_10_client_guard before insert or update on public.products
  for each row execute function public.products_client_guard();

create function public.products_opening_stock() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.on_hand <> 0 then
    insert into public.inventory_movements (shop_id, product_id, kind, quantity, note, created_by)
    values (new.shop_id, new.id, 'count', new.on_hand, 'Opening stock', auth.uid());
  end if;
  return null;
end
$$;

create trigger products_zz_ops_opening_stock after insert on public.products
  for each row execute function public.products_opening_stock();

-- ---------------------------------------------------------------------------
-- Set a (locked) product's stock and raise the low-stock alert on the way
-- down (internal).
-- ---------------------------------------------------------------------------
create function public.inventory_set_on_hand(p_product_id uuid, p_on_hand numeric) returns public.products
language plpgsql security definer
set search_path = ''
as $$
declare
  v_p public.products;
begin
  if abs(p_on_hand) >= 1000000000 then
    raise exception 'the stock level is out of range' using errcode = '22023';
  end if;
  update public.products p set on_hand = round(p_on_hand, 3) where p.id = p_product_id returning * into v_p;
  if v_p.active and v_p.archived_at is null and v_p.reorder_at is not null
     and v_p.on_hand <= v_p.reorder_at and v_p.low_stock_notified_at is null then
    update public.products p set low_stock_notified_at = now() where p.id = v_p.id returning * into v_p;
    perform public.notify_shop_staff(v_p.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'low_stock',
                                     format('Low stock: %s', v_p.name),
                                     format('%s %s left (reorder at %s%s).',
                                            trim_scale(v_p.on_hand), v_p.unit, trim_scale(v_p.reorder_at),
                                            case when v_p.reorder_qty is not null
                                                 then format('; usual order %s', trim_scale(v_p.reorder_qty)) else '' end));
  end if;
  return v_p;
end
$$;

-- ---------------------------------------------------------------------------
-- record_inventory_movement — manager+.
-- ---------------------------------------------------------------------------
create function public.record_inventory_movement(
  p_product_id       uuid,
  p_kind             public.inventory_movement_kind,
  p_quantity         numeric,
  p_unit_cost_cents  bigint default null,
  p_note             text default null
) returns public.inventory_movements
language plpgsql security definer
set search_path = ''
as $$
declare
  v_p      public.products;
  v_delta  numeric;
  v_note   text := nullif(btrim(p_note), '');
  v_m      public.inventory_movements;
begin
  select * into v_p from public.products p where p.id = p_product_id;
  if not found or not public.is_shop_member(v_p.shop_id) then
    raise exception 'product not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_p.shop_id) then
    raise exception 'only owners, admins and managers can change stock' using errcode = '42501';
  end if;
  if p_kind is null then
    raise exception 'kind is required' using errcode = '22023';
  end if;
  if p_kind = 'consume' then
    raise exception 'materials are consumed automatically when a job is completed' using errcode = '22023';
  end if;
  if p_quantity is null or p_quantity <> round(p_quantity, 3) or abs(p_quantity) >= 1000000000 then
    raise exception 'quantity is required (at most 3 decimals)' using errcode = '22023';
  end if;
  if (p_kind = 'receive' and p_quantity <= 0) or (p_kind = 'adjust' and p_quantity = 0)
     or (p_kind = 'count' and p_quantity < 0) then
    raise exception '%', case p_kind when 'receive' then 'a receipt adds a positive quantity'
                                     when 'adjust' then 'an adjustment changes the stock by a non-zero quantity'
                                     else 'a count is the level on hand (zero or more)' end
      using errcode = '22023';
  end if;
  if p_unit_cost_cents is not null and (p_kind <> 'receive' or p_unit_cost_cents < 0) then
    raise exception 'a unit cost (zero or more cents) goes with a receipt only' using errcode = '22023';
  end if;
  if char_length(v_note) > 500 then
    raise exception 'the note is limited to 500 characters' using errcode = '22023';
  end if;

  select * into v_p from public.products p where p.id = v_p.id for update;
  v_delta := case when p_kind = 'count' then p_quantity - v_p.on_hand else p_quantity end;

  insert into public.inventory_movements (shop_id, product_id, kind, quantity, unit_cost_cents, note, created_by)
  values (v_p.shop_id, v_p.id, p_kind, v_delta, p_unit_cost_cents, v_note, auth.uid())
  returning * into v_m;

  if p_kind = 'receive' and p_unit_cost_cents is not null then
    update public.products p set unit_cost_cents = p_unit_cost_cents where p.id = v_p.id;
  end if;
  perform public.inventory_set_on_hand(v_p.id, v_p.on_hand + v_delta);
  return v_m;
end
$$;

-- ---------------------------------------------------------------------------
-- Job completion consumes the job's materials, and so does a change to the
-- lines of a job that is already completed (see the header). One trigger
-- function for both tables.
-- ---------------------------------------------------------------------------
create function public.jobs_ops_consume_inventory() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  r        record;
  v_job    public.jobs;
  v_p      public.products;
  v_note   text;
begin
  if tg_table_name = 'jobs' then
    v_job := new;
  else
    -- the line's job; its row is already locked by job_line_items_touch_job
    select * into v_job from public.jobs j where j.id = new.job_id and j.shop_id = new.shop_id for update;
    if v_job.id is null or v_job.status <> 'completed' then
      return null;
    end if;
  end if;
  v_note := case
              when exists (select 1 from public.inventory_movements m
                            where m.shop_id = v_job.shop_id and m.job_id = v_job.id and m.kind = 'consume')
              then format('Job #%s: lines changed after completion', v_job.number)
              else format('Job #%s completed', v_job.number)
            end;

  for r in
    with lines as (
      select li.id as line_id, li.service_id as line_service, li.quantity as lq,
             coalesce(lv.category_id, jv.category_id) as cat
        from public.job_line_items li
        left join public.vehicles lv on lv.id = li.vehicle_id and lv.shop_id = li.shop_id
        left join public.vehicles jv on jv.id = v_job.vehicle_id and jv.shop_id = v_job.shop_id
       where li.job_id = v_job.id and li.shop_id = v_job.shop_id and li.service_id is not null
    ), used as (
      select l.line_id, l.line_service, l.lq, l.cat, l.line_service as svc from lines l
      union all
      select l.line_id, l.line_service, l.lq, l.cat, pi.service_id
        from lines l
        join public.package_items pi on pi.package_id = l.line_service and pi.shop_id = v_job.shop_id
    ), rules as (
      select u.line_service, u.lq, sc.product_id, sc.quantity,
             rank() over (partition by u.line_id, u.svc, sc.product_id
                          order by (sc.vehicle_category_id is null)) as rk
        from used u
        join public.service_consumables sc
          on sc.shop_id = v_job.shop_id and sc.service_id = u.svc
         and (sc.vehicle_category_id is null or sc.vehicle_category_id = u.cat)
    ), per as (
      select ru.product_id, ru.line_service, round(sum(ru.quantity * ru.lq), 3) as qty
        from rules ru
       where ru.rk = 1
       group by ru.product_id, ru.line_service
    ), done as (
      -- what this job's consume movements already allocated per service
      select m.product_id, a.key::uuid as line_service, sum(a.value::numeric) as qty
        from public.inventory_movements m
        cross join lateral jsonb_each_text(coalesce(m.allocation, '{}'::jsonb)) as a(key, value)
       where m.shop_id = v_job.shop_id and m.job_id = v_job.id and m.kind = 'consume'
       group by m.product_id, a.key
    ), need as (
      select pe.product_id, pe.line_service, pe.qty - coalesce(d.qty, 0) as qty
        from per pe
        left join done d on d.product_id = pe.product_id and d.line_service = pe.line_service
       where pe.qty > coalesce(d.qty, 0)
    )
    select p.id as product_id, sum(n.qty) as qty,
           jsonb_object_agg(n.line_service::text, n.qty) as alloc
      from need n
      join public.products p on p.id = n.product_id and p.shop_id = v_job.shop_id
     where p.active and p.archived_at is null
     group by p.id
    having sum(n.qty) > 0
     order by p.id
  loop
    select * into v_p from public.products p where p.id = r.product_id for update;
    insert into public.inventory_movements (shop_id, product_id, kind, quantity, unit_cost_cents, job_id, allocation,
                                            note, created_by)
    values (v_job.shop_id, v_p.id, 'consume', -r.qty, v_p.unit_cost_cents, v_job.id, r.alloc, v_note, auth.uid());
    perform public.inventory_set_on_hand(v_p.id, v_p.on_hand - r.qty);
  end loop;
  return null;
end
$$;

create trigger jobs_zz_ops_consume_inventory after update of status, vehicle_id on public.jobs
  for each row when (new.status = 'completed'
                     and (old.status is distinct from 'completed' or old.vehicle_id is distinct from new.vehicle_id))
  execute function public.jobs_ops_consume_inventory();

-- after job_line_items_touch_job (which locks the job row)
create trigger job_line_items_zz_ops_consume_inventory
  after insert or update of job_id, service_id, quantity, vehicle_id on public.job_line_items
  for each row execute function public.jobs_ops_consume_inventory();

-- ---------------------------------------------------------------------------
-- low_stock_products — manager+.
-- ---------------------------------------------------------------------------
create function public.low_stock_products(p_shop_id uuid) returns setof public.products
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'inventory is available to owners, admins and managers' using errcode = '42501';
  end if;
  return query
    select * from public.products p
     where p.shop_id = p_shop_id and p.active and p.archived_at is null
       and p.reorder_at is not null and p.on_hand <= p.reorder_at
     order by p.name, p.id;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.products_client_guard(),
  public.products_opening_stock(),
  public.jobs_ops_consume_inventory()
from public, anon, authenticated;

revoke execute on function public.inventory_set_on_hand(uuid, numeric) from public, anon, authenticated;
grant execute on function public.inventory_set_on_hand(uuid, numeric) to service_role;

revoke execute on function
  public.record_inventory_movement(uuid, public.inventory_movement_kind, numeric, bigint, text),
  public.low_stock_products(uuid)
from public, anon;
grant execute on function
  public.record_inventory_movement(uuid, public.inventory_movement_kind, numeric, bigint, text),
  public.low_stock_products(uuid)
to authenticated, service_role;
