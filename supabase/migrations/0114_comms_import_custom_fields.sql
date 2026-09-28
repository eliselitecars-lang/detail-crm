-- ============================================================================
-- 0114 — Customer CSV import takes custom fields (comms P-9 / import-export,
-- 0087 / 0095).
--
-- Settings > Import & export writes one column per active customer custom
-- field into customers.csv, but import_customers accepted a fixed key list
-- and refused any other key ('unknown column(s)'), so a shop could not
-- restore its own export, move between shops or bring custom data from
-- another CRM.
--
-- import_customers (same signature, 0095 body) now accepts an optional
-- 'custom_data' key per row: {customer field key: value}, typed as the
-- field wants it (text / textarea / select / date strings, number, checkbox
-- boolean, multiselect array of options). The web maps CSV columns to the
-- shop's customer fields and converts the cell text; the RPC validates every
-- value with comms_validate_custom_data (unknown or archived field, wrong
-- type, not one of the options -> that row's error, in the dry run too) and
-- drops blank values.
--   * a new customer is created with the values;
--   * a matched customer only gets the fields it has no value for yet — a
--     value on file is never overwritten, like the other columns.
-- The result keys are unchanged.
-- ============================================================================

create or replace function public.import_customers(
  p_shop_id    uuid,
  p_rows       jsonb,
  p_dry_run    boolean default true,
  p_batch_id   uuid default null,
  p_file_name  text default null,
  p_request_nonce  text default null
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_keys constant text[] := array['first_name', 'last_name', 'company', 'email', 'phone', 'address_line1',
                                  'address_line2', 'city', 'region', 'postal_code', 'country', 'notes', 'tags',
                                  'lifecycle', 'sms_opt_in', 'email_opt_in', 'vehicle', 'custom_data'];
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
  v_req      uuid;
  v_prior    jsonb;
  v_custom   jsonb;
begin
  v_shop := public.comms_import_begin(p_shop_id, 'customers', p_rows, p_dry_run, p_batch_id, p_file_name);
  -- a committed chunk retried with the same nonce (0095) returns the first
  -- call's result and imports nothing again (dry runs ignore the nonce)
  if p_request_nonce is not null and not p_dry_run then
    select c.request_id, c.result into v_req, v_prior
      from public.client_request_claim(p_shop_id, 'import_customers', p_request_nonce,
                                       md5(p_rows::text || '|' || coalesce(p_batch_id::text, '-') || '|'
                                           || coalesce(p_file_name, '-'))) c;
    if v_prior is not null then
      return v_prior || jsonb_build_object('replayed', true);
    end if;
  end if;

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

        -- custom fields (0114): {field key: value} of the shop's customer
        -- fields, validated / cleaned here (the dry run reports bad values)
        -- and again by customers_85_custom_data on the write; blank values
        -- are dropped
        v_custom := v_row -> 'custom_data';
        if v_custom is null or jsonb_typeof(v_custom) = 'null' then
          v_custom := '{}';
        elsif jsonb_typeof(v_custom) <> 'object' then
          raise exception 'custom_data must be an object' using errcode = '22023';
        end if;
        v_custom := public.comms_validate_custom_data(p_shop_id, 'customer', v_custom, null);

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
                                        source, sms_opt_in, email_opt_in, custom_data)
          values (p_shop_id, v_first, v_last, v_company, v_email::extensions.citext, v_phone, v_line1, v_line2, v_city,
                  v_region, v_postal, v_country, v_notes, v_tags,
                  coalesce(v_life, 'customer'::public.customer_lifecycle), 'import', v_sms_yes, v_mail_yes, v_custom)
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
                 email_opt_in = c.email_opt_in or (v_mail_yes and c.email_opted_out_at is null),
                 -- like the other fields: only fills values the customer
                 -- does not have yet (a value on file wins)
                 custom_data = v_custom || (select coalesce(jsonb_object_agg(e.key, e.value), '{}')
                                              from jsonb_each(c.custom_data) e
                                             where not (jsonb_typeof(e.value) = 'null'
                                                        or (jsonb_typeof(e.value) = 'string' and btrim(e.value #>> '{}') = '')
                                                        or (jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) = 0)))
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

  v_prior := jsonb_build_object(
    'batch_id', v_batch,
    'dry_run', p_dry_run,
    'counts', jsonb_build_object('created', v_created, 'updated', v_updated, 'skipped', v_skipped,
                                 'errors', jsonb_array_length(v_errors)),
    'rows', v_results);
  if v_req is not null then
    perform public.client_request_finish(v_req, v_prior);
  end if;
  return v_prior;
end
$$;
