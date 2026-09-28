-- ============================================================================
-- 0087 — CSV import of customers (+ vehicles) and services, CSV export of
-- jobs (P-5). The web app parses the file and sends rows as JSON objects
-- (column mapping is the web's job); customers and vehicles are exported
-- with plain RLS selects.
--
-- import_customers / import_services (owner/admin/manager; 42501 otherwise)
--   * at most 1000 rows per call (22023 above); a large file is sent in
--     chunks, and p_batch_id continues the same import_batches row;
--   * p_dry_run (default true) validates and reports exactly what a commit
--     would do — every row is really processed inside a subtransaction that
--     is rolled back, so the per-row result (create / update / skip / error)
--     is exact, also for duplicates within the file — and writes nothing;
--   * each row is processed on its own: a bad row is reported as 'error'
--     with the reason and never blocks the others;
--   * imports of one shop are serialised (advisory lock).
-- Result: {batch_id, dry_run, counts: {created, updated, skipped, errors},
--          rows: [{row, action, customer_id | service_id, vehicle_action, message}]}
-- where row is the 1-based position in p_rows (in a dry run a row that would
-- be created has no id).
--
-- Customers. Keys: first_name, last_name, company, email, phone,
-- address_line1, address_line2, city, region, postal_code, country, notes,
-- tags (a list, or text separated by ';' or ','), lifecycle ('lead' |
-- 'customer'; blank or absent = 'customer' for a NEW customer only), sms_opt_in, email_opt_in, vehicle {year, make, model, trim,
-- color, license_plate, vin, category (vehicle size name, case-insensitive)}.
-- Any other key is a row error (a mapping mistake should not silently drop
-- data). Phones are normalised to E.164 with the shop's country; emails are
-- lower-cased and validated.
--   * Matching (non-archived customers of the shop): same email; else same
--     phone among customers WITHOUT an email (as online booking does). A
--     later row of the same file matches the customer an earlier row created.
--   * A matched customer is never overwritten: only EMPTY fields are
--     filled, tags are added, notes are appended (after a blank line, unless
--     already present), a lead becomes a customer only when the row says
--     lifecycle 'customer' explicitly (never the reverse).
--     Nothing changed = 'skip'.
--   * Consent: sms_opt_in / email_opt_in are set only when the file says so
--     explicitly (true / yes / y / 1); anything else leaves them off (new
--     customers) or unchanged (matched ones). Consent belongs to an address
--     (TCPA: to a number): the row's text consent is applied only when the
--     row has a phone and that phone is the one the customer ends up with,
--     its email consent only when the row has an email and it is the
--     customer's email. So a row matched by email whose phone differs from
--     the one on file (which is kept) does not opt the number on file in,
--     and a customer created without a phone gets no text consent that a
--     number added later would inherit; the row's message says why consent
--     was not applied. Opt-outs and suppressed addresses always win (0033
--     triggers); an import never opts anyone out or clears an opt-out.
--   * New customers get source 'import'.
--   * Vehicle (when make, model or VIN is given): matched among the
--     customer's non-archived vehicles by VIN, else by make + model + year
--     (case-insensitive); a match only has its empty fields filled.
--
-- Services. Keys: name (required), category (service category name,
-- created when missing), kind (service | package | addon | product;
-- default service), description, duration_minutes, taxable (default true),
-- online_bookable (default false), prices {"base" | "<vehicle size name>":
-- cents}. Prices come ONLY from the file (whole cents); an unknown vehicle
-- size is a row error. Existing services are matched by name
-- (case-insensitive, non-archived): only empty fields (description,
-- category) are filled and prices are added only for sizes that have none —
-- an existing price is never changed (reported in the row's message).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helpers (pure)
-- ---------------------------------------------------------------------------

-- True only for an explicit yes: JSON true, or "true" / "yes" / "y" / "1"
-- (any case). Used for consent: anything else is not consent.
create function public.comms_import_yes(p_obj jsonb, p_key text) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(case jsonb_typeof(p_obj -> p_key)
                    when 'boolean' then (p_obj -> p_key)::text = 'true'
                    when 'number' then (p_obj ->> p_key) = '1'
                    when 'string' then lower(btrim(p_obj ->> p_key)) in ('true', 'yes', 'y', '1')
                    else false end, false)
$$;

-- A yes / no flag: true / yes / y / 1 and false / no / n / 0 (any case);
-- missing or blank = p_default; anything else is invalid (22023).
create function public.comms_import_flag(p_obj jsonb, p_key text, p_label text, p_default boolean) returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  v text;
begin
  if p_obj -> p_key is null or jsonb_typeof(p_obj -> p_key) = 'null' then
    return p_default;
  end if;
  v := lower(btrim(p_obj ->> p_key));
  if v = '' then
    return p_default;
  elsif v in ('true', 'yes', 'y', '1') then
    return true;
  elsif v in ('false', 'no', 'n', '0') then
    return false;
  end if;
  raise exception '% must be yes or no', p_label using errcode = '22023';
end
$$;

-- Tags from a JSON list of text or a ';' / ',' separated text: trimmed,
-- blanks and duplicates dropped, each at most 50 characters.
create function public.comms_import_tags(p_value jsonb) returns text[]
language plpgsql immutable
set search_path = ''
as $$
declare
  v_raw text[];
  v_out text[] := '{}';
  v_t   text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return '{}';
  elsif jsonb_typeof(p_value) = 'array' then
    if exists (select 1 from jsonb_array_elements(p_value) e where jsonb_typeof(e) not in ('string', 'number')) then
      raise exception 'tags must be text' using errcode = '22023';
    end if;
    select coalesce(array_agg(e #>> '{}'), '{}') into v_raw from jsonb_array_elements(p_value) e;
  elsif jsonb_typeof(p_value) in ('string', 'number') then
    v_raw := regexp_split_to_array(p_value #>> '{}', '[;,]');
  else
    raise exception 'tags must be a list or text' using errcode = '22023';
  end if;
  foreach v_t in array v_raw loop
    v_t := btrim(v_t);
    continue when v_t = '' or v_t = any (v_out);
    if char_length(v_t) > 50 then
      raise exception 'tag "%" is too long (max 50 characters)', left(v_t, 20) using errcode = '22023';
    end if;
    v_out := v_out || v_t;
  end loop;
  return v_out;
end
$$;

-- Common argument checks of the import RPCs; returns the shop.
create function public.comms_import_begin(
  p_shop_id    uuid,
  p_kind       text,
  p_rows       jsonb,
  p_dry_run    boolean,
  p_batch_id   uuid,
  p_file_name  text
) returns public.shops
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
begin
  if not public.is_shop_manager(p_shop_id) and auth.uid() is not null then
    raise exception 'only owners, admins and managers can import' using errcode = '42501';
  end if;
  select * into v_shop from public.shops s where s.id = p_shop_id;
  if not found then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  if p_dry_run is null then
    raise exception 'dry_run must be true or false' using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'rows must be a list' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 1000 then
    raise exception 'at most 1000 rows per request; send the file in chunks' using errcode = '22023';
  end if;
  if p_file_name is not null and char_length(p_file_name) > 255 then
    raise exception 'file name is too long (max 255 characters)' using errcode = '22023';
  end if;
  if p_batch_id is not null
     and not exists (select 1 from public.import_batches b
                      where b.id = p_batch_id and b.shop_id = p_shop_id and b.kind = p_kind) then
    raise exception 'import batch not found' using errcode = 'P0002';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.import:' || p_shop_id::text, 0));
  return v_shop;
end
$$;

-- Records a committed chunk in import_batches (new row, or accumulated into
-- p_batch_id). status: 'failed' when the whole import so far created and
-- updated nothing but had errors, else 'committed'. errors keeps the first
-- 1000 {row, message}.
create function public.comms_import_record(
  p_shop_id    uuid,
  p_kind       text,
  p_batch_id   uuid,
  p_file_name  text,
  p_rows       integer,
  p_created    integer,
  p_updated    integer,
  p_skipped    integer,
  p_errors     jsonb
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id uuid := p_batch_id;
begin
  if v_id is null then
    insert into public.import_batches (shop_id, kind, status, file_name, created_by)
    values (p_shop_id, p_kind, 'committed', nullif(btrim(coalesce(p_file_name, '')), ''), auth.uid())
    returning id into v_id;
  end if;
  update public.import_batches b
     set row_count = b.row_count + p_rows,
         created_count = b.created_count + p_created,
         updated_count = b.updated_count + p_updated,
         skipped_count = b.skipped_count + p_skipped,
         error_count = b.error_count + jsonb_array_length(p_errors),
         errors = (select coalesce(jsonb_agg(e order by o), '[]')
                     from (select e, o from jsonb_array_elements(b.errors || p_errors) with ordinality as x(e, o)
                            order by o limit 1000) y),
         file_name = coalesce(b.file_name, nullif(btrim(coalesce(p_file_name, '')), '')),
         status = case when b.created_count + p_created + b.updated_count + p_updated = 0
                            and b.error_count + jsonb_array_length(p_errors) > 0
                       then 'failed' else 'committed' end
   where b.id = v_id and b.shop_id = p_shop_id;
  return v_id;
end
$$;

-- ---------------------------------------------------------------------------
-- import_customers
-- ---------------------------------------------------------------------------
create function public.import_customers(
  p_shop_id    uuid,
  p_rows       jsonb,
  p_dry_run    boolean default true,
  p_batch_id   uuid default null,
  p_file_name  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['first_name', 'last_name', 'company', 'email', 'phone', 'address_line1',
                                  'address_line2', 'city', 'region', 'postal_code', 'country', 'notes', 'tags',
                                  'lifecycle', 'sms_opt_in', 'email_opt_in', 'vehicle'];
  c_vkeys constant text[] := array['year', 'make', 'model', 'trim', 'color', 'license_plate', 'vin', 'category'];
  v_shop     public.shops;
  v_results  jsonb := '[]';
  v_errors   jsonb := '[]';
  v_created  integer := 0;
  v_updated  integer := 0;
  v_skipped  integer := 0;
  v_row      jsonb;
  v_n        integer;
  v_unknown  text;
  v_first    text;
  v_last     text;
  v_company  text;
  v_email    text;
  v_phone    text;
  v_raw      text;
  v_line1    text;
  v_line2    text;
  v_city     text;
  v_region   text;
  v_postal   text;
  v_country  text;
  v_notes    text;
  v_tags     text[];
  v_life     public.customer_lifecycle;
  v_sms_yes  boolean;
  v_mail_yes boolean;
  v_sms_ok   boolean;
  v_mail_ok  boolean;
  v_note     text;
  v_veh      jsonb;
  v_year     integer;
  v_make     text;
  v_model    text;
  v_trim     text;
  v_color    text;
  v_plate    text;
  v_vin      text;
  v_cat      uuid;
  v_cust     public.customers;
  v_before   jsonb;
  v_vehicle  public.vehicles;
  v_vaction  text;
  v_action   text;
  v_message  text;
  v_batch    uuid := p_batch_id;
begin
  v_shop := public.comms_import_begin(p_shop_id, 'customers', p_rows, p_dry_run, p_batch_id, p_file_name);

  begin
    for v_row, v_n in select e, o::integer from jsonb_array_elements(p_rows) with ordinality as x(e, o) loop
      v_action := null; v_message := null; v_note := null; v_vaction := 'none'; v_cust := null; v_vehicle := null;
      begin
        if jsonb_typeof(v_row) <> 'object' then
          raise exception 'each row must be an object' using errcode = '22023';
        end if;
        select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_row) k where k <> all (c_keys);
        if v_unknown is not null then
          raise exception 'unknown column(s): %', v_unknown using errcode = '22023';
        end if;
        v_first := public.payload_text(v_row, 'first_name', 100, 'first name');
        v_last := public.payload_text(v_row, 'last_name', 100, 'last name');
        v_company := public.payload_text(v_row, 'company', 200, 'company');
        v_email := lower(public.payload_text(v_row, 'email', 320, 'email'));
        if v_email is not null and not public.is_valid_email(v_email) then
          raise exception 'email "%" is not a valid address', left(v_email, 80) using errcode = '22023';
        end if;
        v_raw := public.payload_text(v_row, 'phone', 40, 'phone');
        v_phone := public.normalize_phone_e164(v_raw, v_shop.country);
        if v_raw is not null and v_phone is null then
          raise exception 'phone "%" is not a valid number', v_raw using errcode = '22023';
        end if;
        v_line1 := public.payload_text(v_row, 'address_line1', 200, 'address line 1');
        v_line2 := public.payload_text(v_row, 'address_line2', 200, 'address line 2');
        v_city := public.payload_text(v_row, 'city', 100, 'city');
        v_region := public.payload_text(v_row, 'region', 100, 'state / region');
        v_postal := public.payload_text(v_row, 'postal_code', 20, 'postal code');
        v_country := upper(public.payload_text(v_row, 'country', 2, 'country'));
        if v_country is not null and v_country !~ '^[A-Z]{2}$' then
          raise exception 'country must be a 2-letter code' using errcode = '22023';
        end if;
        v_notes := public.payload_text(v_row, 'notes', 20000, 'notes');
        v_tags := public.comms_import_tags(v_row -> 'tags');
        if cardinality(v_tags) > 50 then
          raise exception 'at most 50 tags' using errcode = '22023';
        end if;
        v_raw := lower(public.payload_text(v_row, 'lifecycle', 20, 'lifecycle'));
        if v_raw is not null and v_raw not in ('lead', 'customer') then
          raise exception 'lifecycle must be lead or customer' using errcode = '22023';
        end if;
        -- only an explicit value: a matched lead is promoted when the row
        -- says 'customer'; a new customer defaults to 'customer' below
        v_life := v_raw::public.customer_lifecycle;
        v_sms_yes := public.comms_import_yes(v_row, 'sms_opt_in');
        v_mail_yes := public.comms_import_yes(v_row, 'email_opt_in');

        -- vehicle
        v_veh := v_row -> 'vehicle';
        v_year := null; v_make := null; v_model := null; v_trim := null; v_color := null; v_plate := null;
        v_vin := null; v_cat := null;
        if v_veh is not null and jsonb_typeof(v_veh) <> 'null' then
          if jsonb_typeof(v_veh) <> 'object' then
            raise exception 'vehicle must be an object' using errcode = '22023';
          end if;
          select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_veh) k where k <> all (c_vkeys);
          if v_unknown is not null then
            raise exception 'unknown vehicle column(s): %', v_unknown using errcode = '22023';
          end if;
          v_year := public.payload_int(v_veh, 'year', 'vehicle year', 1886, 2100);
          v_make := public.payload_text(v_veh, 'make', 60, 'vehicle make');
          v_model := public.payload_text(v_veh, 'model', 60, 'vehicle model');
          v_trim := public.payload_text(v_veh, 'trim', 60, 'vehicle trim');
          v_color := public.payload_text(v_veh, 'color', 40, 'vehicle color');
          v_plate := upper(public.payload_text(v_veh, 'license_plate', 15, 'license plate'));
          v_vin := nullif(upper(regexp_replace(coalesce(public.payload_text(v_veh, 'vin', 40, 'VIN'), ''),
                                               '[[:space:]-]', '', 'g')), '');
          if v_vin is not null and v_vin !~ '^[A-Z0-9]{5,17}$' then
            raise exception 'VIN "%" is not valid', v_vin using errcode = '22023';
          end if;
          v_raw := public.payload_text(v_veh, 'category', 60, 'vehicle size');
          if v_raw is not null then
            select vc.id into v_cat from public.vehicle_categories vc
             where vc.shop_id = p_shop_id and lower(vc.name) = lower(v_raw);
            if v_cat is null then
              raise exception 'unknown vehicle size "%"', v_raw using errcode = '22023';
            end if;
          end if;
        end if;

        -- match
        if v_email is not null then
          select * into v_cust from public.customers c
           where c.shop_id = p_shop_id and c.archived_at is null and c.email is not null
             and lower(c.email::text) = v_email
           order by c.created_at desc, c.id limit 1;
        end if;
        if v_cust.id is null and v_phone is not null then
          select * into v_cust from public.customers c
           where c.shop_id = p_shop_id and c.archived_at is null and c.email is null and c.phone = v_phone
           order by c.created_at desc, c.id limit 1;
        end if;

        -- consent applies to the address the row gives, and only when that
        -- is the address the customer has (or will have) on file
        v_sms_ok := v_phone is not null and (v_cust.id is null or coalesce(v_cust.phone, v_phone) = v_phone);
        v_mail_ok := v_email is not null
                     and (v_cust.id is null or lower(coalesce(v_cust.email::text, v_email)) = v_email);
        if v_sms_yes and not v_sms_ok then
          v_note := case when v_phone is null then 'text consent not applied: the row has no phone'
                         else 'text consent not applied: the row''s phone is not the one on file' end;
        end if;
        if v_mail_yes and not v_mail_ok then
          v_note := concat_ws('; ', v_note,
                              case when v_email is null then 'email consent not applied: the row has no email'
                                   else 'email consent not applied: the row''s email is not the one on file' end);
        end if;
        v_sms_yes := v_sms_yes and v_sms_ok;
        v_mail_yes := v_mail_yes and v_mail_ok;

        if v_cust.id is null then
          if coalesce(v_first, v_last, v_company) is null then
            raise exception 'a first name, last name or company is required' using errcode = '22023';
          end if;
          insert into public.customers (shop_id, first_name, last_name, company, email, phone, address_line1,
                                        address_line2, city, region, postal_code, country, notes, tags, lifecycle,
                                        source, sms_opt_in, email_opt_in)
          values (p_shop_id, v_first, v_last, v_company, v_email::extensions.citext, v_phone, v_line1, v_line2, v_city,
                  v_region, v_postal, v_country, v_notes, v_tags,
                  coalesce(v_life, 'customer'::public.customer_lifecycle), 'import', v_sms_yes, v_mail_yes)
          returning * into v_cust;
          v_action := 'create';
        else
          v_before := to_jsonb(v_cust);
          update public.customers c
             set first_name = coalesce(nullif(btrim(c.first_name), ''), v_first),
                 last_name = coalesce(nullif(btrim(c.last_name), ''), v_last),
                 company = coalesce(nullif(btrim(c.company), ''), v_company),
                 email = coalesce(c.email, v_email::extensions.citext),
                 phone = coalesce(c.phone, v_phone),
                 address_line1 = coalesce(c.address_line1, v_line1),
                 address_line2 = coalesce(c.address_line2, v_line2),
                 city = coalesce(c.city, v_city),
                 region = coalesce(c.region, v_region),
                 postal_code = coalesce(c.postal_code, v_postal),
                 country = coalesce(c.country, v_country),
                 notes = case when v_notes is null then c.notes
                              when c.notes is null or btrim(c.notes) = '' then v_notes
                              when strpos(c.notes, v_notes) > 0 then c.notes
                              when char_length(c.notes) + 2 + char_length(v_notes) > 20000 then c.notes
                              else c.notes || E'\n\n' || v_notes end,
                 tags = (select coalesce(array_agg(t order by o), '{}')
                           from (select t, o from unnest(c.tags || array(select x from unnest(v_tags) x
                                                                           where x <> all (c.tags)))
                                   with ordinality as u(t, o)
                                  order by o limit 50) y),
                 lifecycle = case when c.lifecycle = 'lead' and v_life is not distinct from 'customer'
                                  then 'customer'::public.customer_lifecycle
                                  else c.lifecycle end,
                 sms_opt_in = c.sms_opt_in or (v_sms_yes and c.sms_opted_out_at is null),
                 email_opt_in = c.email_opt_in or (v_mail_yes and c.email_opted_out_at is null)
           where c.id = v_cust.id and c.shop_id = p_shop_id
          returning * into v_cust;
          v_action := case when (to_jsonb(v_cust) - 'updated_at') = (v_before - 'updated_at') then 'skip'
                           else 'update' end;
        end if;

        -- vehicle
        if coalesce(v_make, v_model, v_vin) is not null then
          if v_vin is not null then
            select * into v_vehicle from public.vehicles v
             where v.shop_id = p_shop_id and v.customer_id = v_cust.id and v.archived_at is null and v.vin = v_vin
             order by v.created_at desc, v.id limit 1;
          end if;
          if v_vehicle.id is null then
            select * into v_vehicle from public.vehicles v
             where v.shop_id = p_shop_id and v.customer_id = v_cust.id and v.archived_at is null
               and lower(btrim(coalesce(v.make, ''))) = lower(coalesce(v_make, ''))
               and lower(btrim(coalesce(v.model, ''))) = lower(coalesce(v_model, ''))
               and v.year is not distinct from v_year
               and (v_vin is null or v.vin is null)
             order by v.created_at desc, v.id limit 1;
          end if;
          if v_vehicle.id is null then
            insert into public.vehicles (shop_id, customer_id, year, make, model, trim, color, license_plate, vin,
                                         category_id)
            values (p_shop_id, v_cust.id, v_year, v_make, v_model, v_trim, v_color, v_plate, v_vin, v_cat)
            returning * into v_vehicle;
            v_vaction := 'create';
            if v_action = 'skip' then
              v_action := 'update';
            end if;
          else
            v_before := to_jsonb(v_vehicle);
            update public.vehicles v
               set year = coalesce(v.year, v_year),
                   trim = coalesce(v.trim, v_trim),
                   color = coalesce(v.color, v_color),
                   license_plate = coalesce(v.license_plate, v_plate),
                   vin = coalesce(v.vin, v_vin),
                   category_id = coalesce(v.category_id, v_cat)
             where v.id = v_vehicle.id and v.shop_id = p_shop_id
            returning * into v_vehicle;
            v_vaction := 'match';
            if v_action = 'skip' and (to_jsonb(v_vehicle) - 'updated_at') <> (v_before - 'updated_at') then
              v_action := 'update';
            end if;
          end if;
        end if;

        if v_action = 'skip' then
          v_message := 'already up to date';
        end if;
        v_message := nullif(concat_ws('; ', v_message, v_note), '');
      exception when others then
        v_action := 'error';
        v_message := sqlerrm;
        v_cust := null;
        v_vaction := 'none';
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', v_n, 'message', left(sqlerrm, 500)));
      end;
      if v_action = 'create' then v_created := v_created + 1;
      elsif v_action = 'update' then v_updated := v_updated + 1;
      elsif v_action = 'skip' then v_skipped := v_skipped + 1;
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_n,
        'action', v_action,
        'customer_id', case when p_dry_run and v_action = 'create' then null else v_cust.id end,
        'vehicle_action', v_vaction,
        'message', v_message));
    end loop;

    if p_dry_run then
      raise exception using errcode = 'P0001', message = 'comms_import_dry_run';
    end if;
  exception when sqlstate 'P0001' then
    if sqlerrm is distinct from 'comms_import_dry_run' then
      raise;
    end if;
  end;

  if not p_dry_run then
    v_batch := public.comms_import_record(p_shop_id, 'customers', p_batch_id, p_file_name,
                                          jsonb_array_length(p_rows), v_created, v_updated, v_skipped, v_errors);
  end if;

  return jsonb_build_object(
    'batch_id', v_batch,
    'dry_run', p_dry_run,
    'counts', jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped,
                                 'errors', jsonb_array_length(v_errors)),
    'rows', v_results);
end
$$;

-- ---------------------------------------------------------------------------
-- import_services
-- ---------------------------------------------------------------------------
create function public.import_services(
  p_shop_id    uuid,
  p_rows       jsonb,
  p_dry_run    boolean default true,
  p_batch_id   uuid default null,
  p_file_name  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['name', 'category', 'kind', 'description', 'duration_minutes', 'taxable',
                                  'online_bookable', 'prices'];
  v_shop      public.shops;
  v_results   jsonb := '[]';
  v_errors    jsonb := '[]';
  v_created   integer := 0;
  v_updated   integer := 0;
  v_skipped   integer := 0;
  v_row       jsonb;
  v_n         integer;
  v_unknown   text;
  v_name      text;
  v_catname   text;
  v_cat       uuid;
  v_raw       text;
  v_kind      public.service_kind;
  v_desc      text;
  v_duration  integer;
  v_taxable   boolean;
  v_bookable  boolean;
  v_prices    jsonb;
  v_pkey      text;
  v_pval      jsonb;
  v_vcat      uuid;
  v_cents     bigint;
  v_price_rows jsonb;
  v_svc       public.services;
  v_before    jsonb;
  v_added     integer;
  v_kept      text[];
  v_action    text;
  v_message   text;
  v_batch     uuid := p_batch_id;
begin
  v_shop := public.comms_import_begin(p_shop_id, 'services', p_rows, p_dry_run, p_batch_id, p_file_name);

  begin
    for v_row, v_n in select e, o::integer from jsonb_array_elements(p_rows) with ordinality as x(e, o) loop
      v_action := null; v_message := null; v_svc := null; v_added := 0; v_kept := '{}';
      begin
        if jsonb_typeof(v_row) <> 'object' then
          raise exception 'each row must be an object' using errcode = '22023';
        end if;
        select string_agg(k, ', ' order by k) into v_unknown from jsonb_object_keys(v_row) k where k <> all (c_keys);
        if v_unknown is not null then
          raise exception 'unknown column(s): %', v_unknown using errcode = '22023';
        end if;
        v_name := public.payload_text(v_row, 'name', 120, 'name', true);
        v_catname := public.payload_text(v_row, 'category', 80, 'category');
        v_raw := lower(public.payload_text(v_row, 'kind', 20, 'kind'));
        if v_raw is not null and v_raw not in ('service', 'package', 'addon', 'product') then
          raise exception 'kind must be service, package, addon or product' using errcode = '22023';
        end if;
        v_kind := coalesce(v_raw, 'service')::public.service_kind;
        v_desc := public.payload_text(v_row, 'description', 10000, 'description');
        v_duration := public.payload_int(v_row, 'duration_minutes', 'duration (minutes)', 0, 1440);
        v_taxable := public.comms_import_flag(v_row, 'taxable', 'taxable', true);
        v_bookable := public.comms_import_flag(v_row, 'online_bookable', 'online bookable', false);

        -- prices: validated completely before anything is written
        v_prices := v_row -> 'prices';
        v_price_rows := '[]';
        if v_prices is not null and jsonb_typeof(v_prices) <> 'null' then
          if jsonb_typeof(v_prices) <> 'object' then
            raise exception 'prices must be an object {"base" or vehicle size: cents}' using errcode = '22023';
          end if;
          for v_pkey, v_pval in select k, v from jsonb_each(v_prices) as p(k, v) order by k loop
            continue when jsonb_typeof(v_pval) = 'null' or (jsonb_typeof(v_pval) = 'string' and btrim(v_pval #>> '{}') = '');
            if jsonb_typeof(v_pval) not in ('number', 'string') or btrim(v_pval #>> '{}') !~ '^[0-9]{1,9}$' then
              raise exception 'price for "%" must be whole cents', v_pkey using errcode = '22023';
            end if;
            v_cents := btrim(v_pval #>> '{}')::bigint;
            if v_cents > 100000000 then
              raise exception 'price for "%" is too large', v_pkey using errcode = '22023';
            end if;
            v_vcat := null;
            if lower(btrim(v_pkey)) <> 'base' then
              select vc.id into v_vcat from public.vehicle_categories vc
               where vc.shop_id = p_shop_id and lower(vc.name) = lower(btrim(v_pkey));
              if v_vcat is null then
                raise exception 'unknown vehicle size "%"', v_pkey using errcode = '22023';
              end if;
            end if;
            v_price_rows := v_price_rows || jsonb_build_array(jsonb_build_object('label', v_pkey, 'category_id', v_vcat,
                                                                                 'cents', v_cents));
          end loop;
        end if;

        -- category (created when missing)
        v_cat := null;
        if v_catname is not null then
          select sc.id into v_cat from public.service_categories sc
           where sc.shop_id = p_shop_id and lower(btrim(sc.name)) = lower(v_catname);
          if v_cat is null then
            insert into public.service_categories (shop_id, name) values (p_shop_id, v_catname) returning id into v_cat;
          end if;
        end if;

        select * into v_svc from public.services s
         where s.shop_id = p_shop_id and s.archived_at is null and lower(btrim(s.name)) = lower(v_name)
         order by s.created_at, s.id limit 1;
        if v_svc.id is null then
          insert into public.services (shop_id, category_id, name, description, kind, duration_minutes, taxable,
                                       online_bookable)
          values (p_shop_id, v_cat, v_name, v_desc, v_kind, coalesce(v_duration, 60), v_taxable, v_bookable)
          returning * into v_svc;
          v_action := 'create';
        else
          v_before := to_jsonb(v_svc);
          update public.services s
             set description = coalesce(s.description, v_desc),
                 category_id = coalesce(s.category_id, v_cat)
           where s.id = v_svc.id and s.shop_id = p_shop_id
          returning * into v_svc;
          v_action := case when (to_jsonb(v_svc) - 'updated_at') = (v_before - 'updated_at') then 'skip'
                           else 'update' end;
        end if;

        -- prices: only where the service has none for that size
        for v_pval in select e from jsonb_array_elements(v_price_rows) e loop
          if exists (select 1 from public.service_prices sp
                      where sp.shop_id = p_shop_id and sp.service_id = v_svc.id
                        and sp.vehicle_category_id is not distinct from (v_pval ->> 'category_id')::uuid) then
            v_kept := v_kept || (v_pval ->> 'label');
          else
            insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
            values (p_shop_id, v_svc.id, (v_pval ->> 'category_id')::uuid, (v_pval ->> 'cents')::bigint);
            v_added := v_added + 1;
          end if;
        end loop;
        if v_added > 0 and v_action = 'skip' then
          v_action := 'update';
        end if;
        if cardinality(v_kept) > 0 then
          v_message := 'existing price kept for: ' || array_to_string(v_kept, ', ');
        elsif v_action = 'skip' then
          v_message := 'already up to date';
        end if;
      exception when others then
        v_action := 'error';
        v_message := sqlerrm;
        v_svc := null;
        v_errors := v_errors || jsonb_build_array(jsonb_build_object('row', v_n, 'message', left(sqlerrm, 500)));
      end;
      if v_action = 'create' then v_created := v_created + 1;
      elsif v_action = 'update' then v_updated := v_updated + 1;
      elsif v_action = 'skip' then v_skipped := v_skipped + 1;
      end if;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'row', v_n,
        'action', v_action,
        'service_id', case when p_dry_run and v_action = 'create' then null else v_svc.id end,
        'message', v_message));
    end loop;

    if p_dry_run then
      raise exception using errcode = 'P0001', message = 'comms_import_dry_run';
    end if;
  exception when sqlstate 'P0001' then
    if sqlerrm is distinct from 'comms_import_dry_run' then
      raise;
    end if;
  end;

  if not p_dry_run then
    v_batch := public.comms_import_record(p_shop_id, 'services', p_batch_id, p_file_name,
                                          jsonb_array_length(p_rows), v_created, v_updated, v_skipped, v_errors);
  end if;

  return jsonb_build_object(
    'batch_id', v_batch,
    'dry_run', p_dry_run,
    'counts', jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped,
                                 'errors', jsonb_array_length(v_errors)),
    'rows', v_results);
end
$$;

-- ---------------------------------------------------------------------------
-- comms_grouped_invoice_job_amounts(invoice) — INTERNAL (service_role and
-- definer code). A grouped invoice's amounts split per job, so that summing
-- the rows of its jobs gives the invoice's own figures exactly (a CSV that
-- repeated the invoice-wide amounts on every job would count a fleet
-- invoice once per job):
--   total_cents    each job's own total, in job order (appointment, then
--                  number); the last job takes whatever the invoice total
--                  differs by (tax rounded once on the invoice, lines edited
--                  on the invoice), and no job gets more than is left of it;
--   paid_cents     the invoice's received money (amount_paid_cents, net of
--                  refunds, tips excluded): first each job's own payments
--                  (a deposit taken on the job, carried onto the invoice),
--                  up to its total; the rest — whole-invoice payments, which
--                  carry no job_id — fills the jobs in the same order, the
--                  last job taking any overpayment;
--   balance_cents  total_cents − paid_cents (sums to the invoice balance).
-- ---------------------------------------------------------------------------
create function public.comms_grouped_invoice_job_amounts(p_invoice_id uuid)
returns table (job_id uuid, total_cents bigint, paid_cents bigint, balance_cents bigint)
language sql stable
set search_path = ''
as $$
  with inv as (
    select i.id, i.shop_id, i.total_cents, i.amount_paid_cents from public.invoices i where i.id = p_invoice_id
  ),
  jobs as (
    select j.id, greatest(j.total_cents, 0)::bigint as jt,
           coalesce((select sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents))
                       from public.payments p
                      where p.shop_id = inv.shop_id and p.invoice_id = inv.id and p.job_id = j.id), 0)::bigint as jp,
           inv.total_cents as t, inv.amount_paid_cents as paid,
           row_number() over (order by j.scheduled_start nulls last, j.number, j.id) as rn,
           count(*) over () as n
      from inv
      join public.invoice_jobs ij on ij.invoice_id = inv.id and ij.shop_id = inv.shop_id
      join public.jobs j on j.id = ij.job_id and j.shop_id = ij.shop_id
  ),
  cum as (
    select jobs.*, sum(jt) over (order by rn rows between unbounded preceding and current row) as cum_jt
      from jobs
  ),
  shares as (
    select c.*,
           case when rn = n then greatest(t, 0) - least(greatest(t, 0), cum_jt - jt)
                else least(greatest(t, 0), cum_jt) - least(greatest(t, 0), cum_jt - jt) end as share
      from cum c
  ),
  own as (
    select sh.*, least(greatest(jp, 0), share) as own_paid from shares sh
  ),
  pool as (
    select o.*,
           greatest(paid - sum(own_paid) over (), 0) as pool,
           sum(share - own_paid) over (order by rn rows between unbounded preceding and current row) as cum_cap
      from own o
  )
  select p.id,
         p.share::bigint,
         (p.own_paid + case when p.rn = p.n then p.pool - least(p.pool, p.cum_cap - (p.share - p.own_paid))
                            else least(p.pool, p.cum_cap) - least(p.pool, p.cum_cap - (p.share - p.own_paid)) end)::bigint,
         (p.share - p.own_paid
            - case when p.rn = p.n then p.pool - least(p.pool, p.cum_cap - (p.share - p.own_paid))
                   else least(p.pool, p.cum_cap) - least(p.pool, p.cum_cap - (p.share - p.own_paid)) end)::bigint
    from pool p
$$;

-- ---------------------------------------------------------------------------
-- export_jobs (owner/admin/manager) — one row per job whose appointment
-- (else, for an unscheduled job, its creation) falls on a shop-local date in
-- [p_from, p_to] (at most 3 years). Times are shop-local text
-- ('YYYY-MM-DD HH24:MI'); money in cents, tips excluded:
--   * a job on a single-job invoice: the invoice's total and balance; paid =
--     received on the job, net of refunds;
--   * a job on a grouped (fleet) invoice: its share of that invoice
--     (comms_grouped_invoice_job_amounts), so the jobs' rows add up to the
--     invoice exactly and summing the export never counts it once per job;
--   * a job without a live invoice: its own total, paid = received on the
--     job, balance = total − paid.
-- ---------------------------------------------------------------------------
create function public.export_jobs(p_shop_id uuid, p_from date, p_to date)
returns table (
  number            bigint,
  status            public.job_status,
  scheduled_local   text,
  completed_local   text,
  customer_name     text,
  customer_email    text,
  customer_phone    text,
  vehicle           text,
  services          text,
  location_type     public.location_type,
  service_address   text,
  total_cents       bigint,
  paid_cents        bigint,
  balance_cents     bigint,
  source            public.job_source
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_tz text;
begin
  if not public.is_shop_manager(p_shop_id) and auth.uid() is not null then
    raise exception 'only owners, admins and managers can export jobs' using errcode = '42501';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = p_shop_id;
  if v_tz is null then
    raise exception 'shop not found' using errcode = 'P0002';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a date range (from <= to)' using errcode = '22023';
  end if;
  if p_to > (p_from + interval '3 years')::date then
    raise exception 'the export covers at most 3 years' using errcode = '22023';
  end if;
  return query
  select j.number,
         j.status,
         to_char(j.scheduled_start at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
         to_char(j.completed_at at time zone v_tz, 'YYYY-MM-DD HH24:MI'),
         coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(c.first_name), ''), nullif(btrim(c.last_name), ''))), ''),
                  nullif(btrim(c.company), '')),
         c.email::text,
         c.phone,
         nullif(btrim(concat_ws(' ', v.year::text, nullif(btrim(v.make), ''), nullif(btrim(v.model), ''))), ''),
         (select string_agg(li.name, ', ' order by li.sort, li.created_at, li.id)
            from public.job_line_items li where li.job_id = j.id and li.shop_id = j.shop_id),
         j.location_type,
         case when j.location_type = 'mobile'
              then nullif(concat_ws(', ', j.service_address_line1, j.service_address_line2, j.service_city,
                                    j.service_region, j.service_postal_code), '') end,
         coalesce(grp.total_cents, inv.total_cents, j.total_cents),
         coalesce(grp.paid_cents, pay.paid, 0)::bigint,
         coalesce(grp.balance_cents, inv.balance_cents,
                  coalesce(inv.total_cents, j.total_cents) - coalesce(pay.paid, 0))::bigint,
         j.source
    from public.jobs j
    join public.customers c on c.id = j.customer_id and c.shop_id = j.shop_id
    left join public.vehicles v on v.id = j.vehicle_id and v.shop_id = j.shop_id
    left join lateral (
      select i.id, i.job_id, i.total_cents, i.balance_cents
        from public.invoice_jobs ij
        join public.invoices i on i.id = ij.invoice_id and i.shop_id = ij.shop_id
       where ij.shop_id = j.shop_id and ij.job_id = j.id and not ij.voided and i.status <> 'void'
       order by i.created_at desc
       limit 1) inv on true
    left join lateral (
      select g.total_cents, g.paid_cents, g.balance_cents
        from public.comms_grouped_invoice_job_amounts(inv.id) g
       where inv.id is not null and inv.job_id is null and g.job_id = j.id) grp on true
    left join lateral (
      select sum(public.payment_net_amount(p.status, p.amount_cents, p.tip_cents, p.refunded_cents)) as paid
        from public.payments p where p.shop_id = j.shop_id and p.job_id = j.id) pay on true
   where j.shop_id = p_shop_id
     and (coalesce(j.scheduled_start, j.created_at) at time zone v_tz)::date between p_from and p_to
   order by coalesce(j.scheduled_start, j.created_at), j.number;
end
$$;

-- (contract tags for scripts/gen_types.py: output columns that may be null)
comment on function public.export_jobs(uuid, date, date) is
  'CSV export of jobs (manager+). @nullable: scheduled_local, completed_local, customer_name, customer_email, customer_phone, vehicle, services, service_address';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.comms_import_yes(jsonb, text),
  public.comms_import_flag(jsonb, text, text, boolean),
  public.comms_import_tags(jsonb)
from public, anon;
grant execute on function
  public.comms_import_yes(jsonb, text),
  public.comms_import_flag(jsonb, text, text, boolean),
  public.comms_import_tags(jsonb)
to authenticated, service_role;

revoke execute on function
  public.comms_import_begin(uuid, text, jsonb, boolean, uuid, text),
  public.comms_import_record(uuid, text, uuid, text, integer, integer, integer, integer, jsonb),
  public.comms_grouped_invoice_job_amounts(uuid)
from public, anon, authenticated;
grant execute on function
  public.comms_import_begin(uuid, text, jsonb, boolean, uuid, text),
  public.comms_import_record(uuid, text, uuid, text, integer, integer, integer, integer, jsonb),
  public.comms_grouped_invoice_job_amounts(uuid)
to service_role;

revoke execute on function
  public.import_customers(uuid, jsonb, boolean, uuid, text),
  public.import_services(uuid, jsonb, boolean, uuid, text),
  public.export_jobs(uuid, date, date)
from public, anon;
grant execute on function
  public.import_customers(uuid, jsonb, boolean, uuid, text),
  public.import_services(uuid, jsonb, boolean, uuid, text),
  public.export_jobs(uuid, date, date)
to authenticated, service_role;
