-- ============================================================================
-- 0088 — Custom fields and booking questions, lead-capture forms, the
-- customer-merge follow-up for comms rows, and booking page tracking ids
-- (P-9, P-10).
--
-- Custom fields (custom_fields, 0081): values live in customers.custom_data
-- / jobs.custom_data as {key: value}, validated on every write by
-- customers_85_custom_data / jobs_85_custom_data (definer, so the field
-- definitions are read whoever writes):
--   * the value must be an object (a non-object is left to the table's
--     CHECK, 23514); null / blank values are dropped;
--   * every key must be a field of the shop for that entity (22023); a key
--     whose field is archived is only kept with its unchanged value;
--   * a changed value must match the field type (22023, naming the label):
--       text ≤ 2000 characters, textarea ≤ 10000, number = a JSON number,
--       select = one of the options, multiselect = a list of distinct
--       options, checkbox = true / false, date = 'YYYY-MM-DD';
--     unchanged values are kept even if the field changed since;
--   * an ONLINE BOOKING (jobs inserted with source 'online_booking', i.e.
--     create_online_booking's answers) may only answer the shop's booking
--     questions (show_in_booking job fields whose location_scope is empty or
--     the booking's location type), and must answer every required one.
-- A field with saved values cannot be deleted (archive it instead: 23514),
-- nor can its key, entity or type change. A customer field's saved values
-- include the answers kept on lead submissions (lead_submissions.answers).
--
-- Public surfaces (anon + authenticated; unknown / inactive: PT404):
--   public_booking_questions(slug)          the booking page's questions
--   public_get_lead_form(token)             a lead form (/lead/<token>)
--   public_submit_lead(token, payload)      submit it
-- Lead submissions: matching like online booking (same email — skipping a
-- record whose phone is unverified and differs from the submitted one —
-- else same phone among customers without an email). A matched customer is NEVER
-- modified by a public form — the answers, message and vehicle are kept on
-- the submission only. A new customer is created as a lead (source = the
-- form's default_source) with exactly what was entered: consent only as
-- ticked (never on by default), answers as its custom data, the vehicle as
-- its first vehicle; its phone counts as unverified (0042). Required
-- questions are enforced (22023). Abuse limits (PT429): 3 submissions per
-- email / phone per form, 200 per form, in any rolling 24 hours; a filled-in
-- honeypot ('website') is answered as a success and writes nothing.
-- Managers are notified ('new_lead', deep link to the customer) when the
-- form says so; the 'lead_received' auto-reply (transactional) goes out
-- when the form enables it.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Value validation
-- ---------------------------------------------------------------------------

-- Why p_value is not a valid value for the field (null = valid).
create function public.comms_custom_value_error(
  p_type     public.custom_field_type,
  p_options  text[],
  p_value    jsonb
) returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_date date;
begin
  case p_type
    when 'text' then
      if jsonb_typeof(p_value) <> 'string' then return 'must be text'; end if;
      if char_length(p_value #>> '{}') > 2000 then return 'is too long (max 2000 characters)'; end if;
    when 'textarea' then
      if jsonb_typeof(p_value) <> 'string' then return 'must be text'; end if;
      if char_length(p_value #>> '{}') > 10000 then return 'is too long (max 10000 characters)'; end if;
    when 'number' then
      if jsonb_typeof(p_value) <> 'number' then return 'must be a number'; end if;
    when 'select' then
      if jsonb_typeof(p_value) <> 'string' or not ((p_value #>> '{}') = any (p_options)) then
        return 'must be one of the options';
      end if;
    when 'multiselect' then
      if jsonb_typeof(p_value) <> 'array'
         or exists (select 1 from jsonb_array_elements(p_value) e
                     where jsonb_typeof(e) <> 'string' or not ((e #>> '{}') = any (p_options)))
         or (select count(distinct e) <> count(*) from jsonb_array_elements(p_value) e) then
        return 'must be a list of the options';
      end if;
    when 'checkbox' then
      if jsonb_typeof(p_value) <> 'boolean' then return 'must be true or false'; end if;
    when 'date' then
      if jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        return 'must be a date (YYYY-MM-DD)';
      end if;
      begin
        v_date := (p_value #>> '{}')::date;
        if to_char(v_date, 'YYYY-MM-DD') <> (p_value #>> '{}') then
          return 'must be a date (YYYY-MM-DD)';
        end if;
      exception when others then
        return 'must be a date (YYYY-MM-DD)';
      end;
  end case;
  return null;
end
$$;

-- Validates / cleans custom data of a customer or job of p_shop_id (see the
-- header). p_old: the previous value (updates), whose unchanged keys are
-- kept as they are. Raises 22023.
create function public.comms_validate_custom_data(
  p_shop_id  uuid,
  p_entity   public.custom_field_entity,
  p_new      jsonb,
  p_old      jsonb
) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_out   jsonb := '{}';
  v_key   text;
  v_val   jsonb;
  v_field public.custom_fields;
  v_err   text;
begin
  if jsonb_typeof(p_new) is distinct from 'object' then
    return p_new;                            -- left to the table's CHECK
  end if;
  for v_key, v_val in select k, v from jsonb_each(p_new) as e(k, v) order by k loop
    continue when jsonb_typeof(v_val) = 'null'
               or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '')
               or (jsonb_typeof(v_val) = 'array' and jsonb_array_length(v_val) = 0);
    if jsonb_typeof(p_old) = 'object' and p_old -> v_key = v_val then
      v_out := v_out || jsonb_build_object(v_key, v_val);   -- unchanged: kept as it was
      continue;
    end if;
    select * into v_field from public.custom_fields f
     where f.shop_id = p_shop_id and f.entity = p_entity and f.key = v_key;
    if v_field.id is null then
      raise exception 'unknown % field "%"', p_entity, left(v_key, 40) using errcode = '22023';
    end if;
    if v_field.archived_at is not null then
      raise exception 'the field "%" is archived', v_field.label using errcode = '22023';
    end if;
    if jsonb_typeof(v_val) = 'string' and v_field.type in ('text', 'textarea', 'select', 'date') then
      v_val := to_jsonb(btrim(v_val #>> '{}', E' \t\r\n'));
    end if;
    v_err := public.comms_custom_value_error(v_field.type, v_field.options, v_val);
    if v_err is not null then
      raise exception '% %', v_field.label, v_err using errcode = '22023';
    end if;
    v_out := v_out || jsonb_build_object(v_key, v_val);
    v_field := null;
  end loop;
  return v_out;
end
$$;

create function public.customers_comms_custom_data() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.custom_data := public.comms_validate_custom_data(new.shop_id, 'customer', new.custom_data,
                                                       case when tg_op = 'UPDATE' then old.custom_data end);
  return new;
end
$$;

create trigger customers_85_custom_data before insert or update of custom_data on public.customers
  for each row execute function public.customers_comms_custom_data();

create function public.jobs_comms_custom_data() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_key   text;
  v_label text;
begin
  new.custom_data := public.comms_validate_custom_data(new.shop_id, 'job', new.custom_data,
                                                       case when tg_op = 'UPDATE' then old.custom_data end);
  if tg_op = 'INSERT' and new.source = 'online_booking' and jsonb_typeof(new.custom_data) = 'object' then
    -- the booker may only answer the booking questions for this location type
    select k into v_key from jsonb_object_keys(new.custom_data) k
     where not exists (select 1 from public.custom_fields f
                        where f.shop_id = new.shop_id and f.entity = 'job' and f.key = k and f.show_in_booking
                          and (f.location_scope is null or f.location_scope = new.location_type))
     order by k limit 1;
    if v_key is not null then
      raise exception 'unknown booking question "%"', left(v_key, 40) using errcode = '22023';
    end if;
    -- … and must answer every required one
    select f.label into v_label from public.custom_fields f
     where f.shop_id = new.shop_id and f.entity = 'job' and f.show_in_booking and f.required
       and f.archived_at is null
       and (f.location_scope is null or f.location_scope = new.location_type)
       and not (new.custom_data ? f.key)
     order by f.sort, f.created_at, f.id limit 1;
    if v_label is not null then
      raise exception '% is required', v_label using errcode = '22023';
    end if;
  end if;
  return new;
end
$$;

create trigger jobs_85_custom_data before insert or update of custom_data on public.jobs
  for each row execute function public.jobs_comms_custom_data();

-- Definitions with saved values (customers.custom_data / jobs.custom_data,
-- and for customer fields lead_submissions.answers) keep their identity: no
-- delete (archive instead), no key / entity / type change. A deleted field leaves the lead
-- forms that asked it.
create function public.custom_fields_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_has_values boolean;
begin
  -- the whole shop is being deleted (cascade)
  if tg_op = 'DELETE' and not exists (select 1 from public.shops s where s.id = old.shop_id) then
    return old;
  end if;
  if tg_op = 'UPDATE' then
    new.label := btrim(new.label);
    new.help_text := nullif(btrim(coalesce(new.help_text, '')), '');
    if (new.key, new.entity, new.type) is not distinct from (old.key, old.entity, old.type) then
      return new;
    end if;
  end if;
  -- A customer field's values also live in lead_submissions.answers: a
  -- submission matched to an existing customer keeps its answers ONLY there
  -- (public_submit_lead never changes that customer), and they are read
  -- back against the field with that key.
  v_has_values := case old.entity
    when 'customer' then exists (select 1 from public.customers c where c.shop_id = old.shop_id and c.custom_data ? old.key)
                         or exists (select 1 from public.lead_submissions ls
                                     where ls.shop_id = old.shop_id and ls.answers ? old.key)
    else exists (select 1 from public.jobs j where j.shop_id = old.shop_id and j.custom_data ? old.key) end;
  if v_has_values then
    raise exception 'the field "%" has saved values; archive it instead', old.label
      using errcode = '23514';
  end if;
  if tg_op = 'DELETE' then
    update public.lead_forms lf set field_ids = array_remove(lf.field_ids, old.id)
     where lf.shop_id = old.shop_id and old.id = any (lf.field_ids);
    return old;
  end if;
  return new;
end
$$;

create trigger custom_fields_80_guard before update or delete on public.custom_fields
  for each row execute function public.custom_fields_guard();

create function public.custom_fields_normalize() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.label := btrim(new.label);
  new.help_text := nullif(btrim(coalesce(new.help_text, '')), '');
  return new;
end
$$;

create trigger custom_fields_80_normalize before insert on public.custom_fields
  for each row execute function public.custom_fields_normalize();

-- ---------------------------------------------------------------------------
-- lead_forms: field_ids are the shop's CUSTOMER fields (distinct, in order).
-- ---------------------------------------------------------------------------
create function public.lead_forms_validate() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  new.headline := nullif(btrim(coalesce(new.headline, '')), '');
  new.intro := nullif(btrim(coalesce(new.intro, '')), '');
  new.success_message := nullif(btrim(coalesce(new.success_message, '')), '');
  new.field_ids := coalesce((select array_agg(f order by o)
                               from (select f, min(o) as o from unnest(new.field_ids) with ordinality as u(f, o)
                                      group by f) d), '{}');
  if exists (select 1 from unnest(new.field_ids) as f
              where not exists (select 1 from public.custom_fields cf
                                 where cf.id = f and cf.shop_id = new.shop_id and cf.entity = 'customer')) then
    raise exception 'a lead form can only ask the shop''s customer fields' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.token <> old.token then
    raise exception 'the form link cannot be changed' using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger lead_forms_80_validate before insert or update on public.lead_forms
  for each row execute function public.lead_forms_validate();

-- ---------------------------------------------------------------------------
-- public_booking_questions(slug) — the shop's booking questions (job fields
-- shown in online booking), in order. Unknown shop: PT404.
-- ---------------------------------------------------------------------------
create function public.public_booking_questions(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(coalesce(p_slug, '')));
  if v_shop is null then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'key', f.key, 'label', f.label, 'type', f.type, 'options', to_jsonb(f.options),
             'help_text', f.help_text, 'required', f.required, 'location_scope', f.location_scope)
           order by f.sort, f.created_at, f.id)
      from public.custom_fields f
     where f.shop_id = v_shop and f.entity = 'job' and f.show_in_booking and f.archived_at is null), '[]'::jsonb);
end
$$;

-- ---------------------------------------------------------------------------
-- Lead forms (public)
-- ---------------------------------------------------------------------------

-- The active form behind a token (PT404 otherwise).
create function public.comms_live_lead_form(p_token uuid) returns public.lead_forms
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_form public.lead_forms;
begin
  if p_token is not null then
    select * into v_form from public.lead_forms f where f.token = p_token;
  end if;
  if v_form.id is null or not v_form.active or v_form.archived_at is not null then
    raise exception 'form not found' using errcode = 'PT404';
  end if;
  return v_form;
end
$$;

-- The form's live (non-archived) customer fields, in the form's order.
create function public.comms_lead_form_fields(p_form public.lead_forms) returns setof public.custom_fields
language sql stable
set search_path = ''
as $$
  select f.*
    from unnest(p_form.field_ids) with ordinality as u(fid, o)
    join public.custom_fields f on f.id = u.fid and f.shop_id = p_form.shop_id
   where f.entity = 'customer' and f.archived_at is null
   order by u.o
$$;

create function public.public_get_lead_form(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_form public.lead_forms;
  v_shop public.shops;
begin
  v_form := public.comms_live_lead_form(p_token);
  select * into v_shop from public.shops s where s.id = v_form.shop_id;
  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'logo_path', v_shop.logo_path, 'brand_color', v_shop.brand_color),
    'form', jsonb_build_object('name', v_form.name, 'headline', v_form.headline, 'intro', v_form.intro,
                               'ask_vehicle', v_form.ask_vehicle, 'ask_message', v_form.ask_message,
                               'success_message', v_form.success_message),
    'fields', coalesce((select jsonb_agg(jsonb_build_object('key', f.key, 'label', f.label, 'type', f.type,
                                                            'options', to_jsonb(f.options), 'help_text', f.help_text,
                                                            'required', f.required))
                          from public.comms_lead_form_fields(v_form) f), '[]'::jsonb));
end
$$;

create function public.public_submit_lead(
  p_token    uuid,
  p_payload  jsonb,
  p_now      timestamptz default now()
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  c_default_message constant text := 'Thanks! We received your request and will be in touch soon.';
  v_now      timestamptz := public.effective_now(p_now);
  v_form     public.lead_forms;
  v_shop     public.shops;
  v_first    text;
  v_last     text;
  v_email    text;
  v_raw      text;
  v_phone    text;
  v_sms      boolean;
  v_mail     boolean;
  v_veh_in   jsonb;
  v_year     integer;
  v_make     text;
  v_model    text;
  v_vinfo    jsonb;
  v_message  text;
  v_answers  jsonb := '{}';
  v_field    public.custom_fields;
  v_val      jsonb;
  v_err      text;
  v_key      text;
  v_recent   integer;
  v_cust     public.customers;
  v_matched  boolean := false;
  v_vehicle  uuid;
  v_who      text;
begin
  v_form := public.comms_live_lead_form(p_token);
  if jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'the submission must be an object' using errcode = '22023';
  end if;
  -- honeypot: bots fill every field; people never see this one
  if nullif(btrim(coalesce(p_payload ->> 'website', '')), '') is not null then
    return jsonb_build_object('ok', true, 'message', coalesce(v_form.success_message, c_default_message));
  end if;
  select * into v_shop from public.shops s where s.id = v_form.shop_id;

  v_first := public.payload_text(p_payload, 'first_name', 100, 'first name', true);
  v_last := public.payload_text(p_payload, 'last_name', 100, 'last name');
  v_email := lower(public.payload_text(p_payload, 'email', 320, 'email'));
  if v_email is not null and not public.is_valid_email(v_email) then
    raise exception 'please enter a valid email address' using errcode = '22023';
  end if;
  v_raw := public.payload_text(p_payload, 'phone', 40, 'phone');
  v_phone := public.normalize_phone_e164(v_raw, v_shop.country);
  if v_raw is not null and v_phone is null then
    raise exception 'please enter a valid phone number' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'an email address or phone number is required' using errcode = '22023';
  end if;
  v_sms := public.payload_bool(p_payload, 'sms_opt_in', 'text message consent') and v_phone is not null;
  v_mail := public.payload_bool(p_payload, 'email_opt_in', 'email consent') and v_email is not null;

  if v_form.ask_vehicle then
    v_veh_in := p_payload -> 'vehicle';
    if v_veh_in is not null and jsonb_typeof(v_veh_in) not in ('object', 'null') then
      raise exception 'vehicle must be an object' using errcode = '22023';
    end if;
    v_year := public.payload_int(v_veh_in, 'year', 'vehicle year', 1886, 2100);
    v_make := public.payload_text(v_veh_in, 'make', 60, 'vehicle make');
    v_model := public.payload_text(v_veh_in, 'model', 60, 'vehicle model');
    if coalesce(v_year::text, v_make, v_model) is not null then
      v_vinfo := jsonb_strip_nulls(jsonb_build_object('year', v_year, 'make', v_make, 'model', v_model));
    end if;
  end if;
  if v_form.ask_message then
    v_message := public.payload_text(p_payload, 'message', 5000, 'message');
  end if;

  -- answers: only the form's (live) questions, each valid; required ones answered
  if p_payload -> 'answers' is not null and jsonb_typeof(p_payload -> 'answers') <> 'null' then
    if jsonb_typeof(p_payload -> 'answers') <> 'object' then
      raise exception 'answers must be an object' using errcode = '22023';
    end if;
    select k into v_key from jsonb_object_keys(p_payload -> 'answers') k
     where k not in (select f.key from public.comms_lead_form_fields(v_form) f)
     order by k limit 1;
    if v_key is not null then
      raise exception 'unknown question "%"', left(v_key, 40) using errcode = '22023';
    end if;
  end if;
  for v_field in select * from public.comms_lead_form_fields(v_form) loop
    v_val := p_payload -> 'answers' -> v_field.key;
    if v_val is null or jsonb_typeof(v_val) = 'null'
       or (jsonb_typeof(v_val) = 'string' and btrim(v_val #>> '{}') = '')
       or (jsonb_typeof(v_val) = 'array' and jsonb_array_length(v_val) = 0) then
      if v_field.required then
        raise exception '% is required', v_field.label using errcode = '22023';
      end if;
      continue;
    end if;
    if jsonb_typeof(v_val) = 'string' and v_field.type in ('text', 'textarea', 'select', 'date') then
      v_val := to_jsonb(btrim(v_val #>> '{}', E' \t\r\n'));
    end if;
    v_err := public.comms_custom_value_error(v_field.type, v_field.options, v_val);
    if v_err is not null then
      raise exception '% %', v_field.label, v_err using errcode = '22023';
    end if;
    v_answers := v_answers || jsonb_build_object(v_field.key, v_val);
  end loop;

  -- abuse limits (per form, serialised)
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('public.lead_form:' || v_form.id::text, 0));
  select count(*) into v_recent from public.lead_submissions ls
   where ls.shop_id = v_form.shop_id and ls.lead_form_id = v_form.id and ls.created_at > v_now - interval '24 hours';
  if v_recent >= 200 then
    raise exception 'this form is receiving too many requests; please try again later or call the shop'
      using errcode = 'PT429';
  end if;
  select count(*) into v_recent
    from public.lead_submissions ls
    join public.customers c on c.id = ls.customer_id and c.shop_id = ls.shop_id
   where ls.shop_id = v_form.shop_id and ls.lead_form_id = v_form.id and ls.created_at > v_now - interval '24 hours'
     and ((v_email is not null and lower(c.email::text) = v_email) or (v_phone is not null and c.phone = v_phone));
  if v_recent >= 3 then
    raise exception 'we already received your request; please call the shop if you need anything else'
      using errcode = 'PT429';
  end if;

  -- customer: match (never modified) or create a lead
  if v_email is not null then
    -- as online booking (0042 / 0054): never a record whose phone came from
    -- someone else's unverified public form, unless this lead gives that
    -- same phone. A form proves neither the email nor the phone, and the
    -- auto-reply (and staff's follow-up) would reach that stranger's phone.
    select * into v_cust from public.customers c
     where c.shop_id = v_form.shop_id and c.archived_at is null and c.email is not null
       and lower(c.email::text) = v_email
       and (not c.phone_unverified or c.phone is null or c.phone = v_phone)
     order by coalesce(c.phone = v_phone, false) desc, c.created_at desc, c.id limit 1;
  end if;
  if v_cust.id is null and v_phone is not null then
    select * into v_cust from public.customers c
     where c.shop_id = v_form.shop_id and c.archived_at is null and c.email is null and c.phone = v_phone
     order by c.created_at desc, c.id limit 1;
  end if;
  if v_cust.id is not null then
    v_matched := true;
  else
    insert into public.customers (shop_id, first_name, last_name, email, phone, sms_opt_in, email_opt_in, lifecycle,
                                  source, custom_data, phone_unverified)
    values (v_form.shop_id, v_first, v_last, v_email::extensions.citext, v_phone, v_sms, v_mail, 'lead',
            v_form.default_source, v_answers, v_phone is not null)
    returning * into v_cust;
    if coalesce(v_make, v_model) is not null then
      insert into public.vehicles (shop_id, customer_id, year, make, model)
      values (v_form.shop_id, v_cust.id, v_year, v_make, v_model)
      returning id into v_vehicle;
    end if;
  end if;

  insert into public.lead_submissions (shop_id, lead_form_id, customer_id, vehicle_id, vehicle_info, answers, message,
                                       matched_existing, signer_ip, created_at)
  values (v_form.shop_id, v_form.id, v_cust.id, v_vehicle, v_vinfo, v_answers, v_message, v_matched,
          public.form_signer_ip(), v_now);

  begin
    if v_form.notify_staff then
      v_who := coalesce(nullif(btrim(concat_ws(' ', v_first, v_last)), ''), 'a new contact');
      perform public.notify_shop_staff(
        v_form.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'new_lead',
        'New lead: ' || v_who,
        concat_ws(' · ', v_form.name, left(v_message, 200)),
        null, null, p_customer_id => v_cust.id);
    end if;
    if v_form.auto_reply then
      perform public.integration_send_customer_template(v_form.shop_id, v_cust.id, 'lead_received', null, null, false);
    end if;
  exception when others then
    raise warning 'lead side effects failed for form %: % (%)', v_form.id, sqlerrm, sqlstate;
  end;

  return jsonb_build_object('ok', true, 'message', coalesce(v_form.success_message, c_default_message));
end
$$;

-- ---------------------------------------------------------------------------
-- Customer merge (ops 0074 sets customers.merged_into_id on the duplicate
-- after moving its records): the comms rows follow — lead submissions and
-- tasks move to the surviving customer, and custom data the survivor lacks
-- is copied from the duplicate (only keys of live customer fields whose
-- value is still valid; the survivor's own values always win).
-- ---------------------------------------------------------------------------
create function public.customers_comms_merge_follow() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_fill jsonb;
begin
  update public.lead_submissions ls set customer_id = new.merged_into_id
   where ls.shop_id = new.shop_id and ls.customer_id = new.id;
  update public.tasks t set customer_id = new.merged_into_id
   where t.shop_id = new.shop_id and t.customer_id = new.id;
  select coalesce(jsonb_object_agg(e.key, e.value), '{}') into v_fill
    from jsonb_each(new.custom_data) e
    join public.custom_fields f on f.shop_id = new.shop_id and f.entity = 'customer' and f.key = e.key
                               and f.archived_at is null
    join public.customers t on t.id = new.merged_into_id and t.shop_id = new.shop_id
   where not (t.custom_data ? e.key)
     and public.comms_custom_value_error(f.type, f.options, e.value) is null;
  if v_fill <> '{}'::jsonb then
    update public.customers c set custom_data = v_fill || c.custom_data
     where c.id = new.merged_into_id and c.shop_id = new.shop_id;
  end if;
  return null;
end
$$;

create trigger customers_zz_comms_merge_follow after update of merged_into_id on public.customers
  for each row when (old.merged_into_id is null and new.merged_into_id is not null)
  execute function public.customers_comms_merge_follow();

-- ---------------------------------------------------------------------------
-- public_shop_profile (replaced; same signature): + 'tracking' {meta_pixel_id,
-- ga4_measurement_id} — the shop's ids while online booking is on, else
-- both null. No personal data.
-- ---------------------------------------------------------------------------
create or replace function public.public_shop_profile(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_bs   public.booking_settings;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_bs from public.booking_settings b where b.shop_id = v_shop.id;
  return jsonb_build_object(
    'name', v_shop.name,
    'slug', v_shop.slug,
    'logo_path', v_shop.logo_path,
    'brand_color', v_shop.brand_color,
    'phone', v_shop.phone,
    'website', v_shop.website,
    'city', v_shop.city,
    'region', v_shop.region,
    'country', v_shop.country,
    'timezone', v_shop.timezone,
    'currency', v_shop.currency,
    'business_type', v_shop.business_type,
    'tax_rate_bps', v_shop.tax_rate_bps,
    'booking', jsonb_build_object(
      'enabled', coalesce(v_bs.enabled, false),
      'auto_confirm', coalesce(v_bs.auto_confirm, false),
      'lead_time_minutes', v_bs.lead_time_minutes,
      'max_days_ahead', v_bs.max_days_ahead,
      'slot_interval_minutes', v_bs.slot_interval_minutes,
      'require_deposit', coalesce(v_bs.require_deposit, false),
      'deposit_type', case when v_bs.require_deposit then v_bs.deposit_type end,
      'deposit_value', case when v_bs.require_deposit then v_bs.deposit_value end,
      'service_area_limited', coalesce(cardinality(v_bs.service_area_postal_codes), 0) > 0,
      'booking_message', v_bs.booking_message,
      'cancellation_policy', v_bs.cancellation_policy,
      'allow_client_cancel_hours', v_bs.allow_client_cancel_hours),
    'tracking', jsonb_build_object(
      'meta_pixel_id', case when coalesce(v_bs.enabled, false) then v_bs.meta_pixel_id end,
      'ga4_measurement_id', case when coalesce(v_bs.enabled, false) then v_bs.ga4_measurement_id end));
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.customers_comms_custom_data(),
  public.jobs_comms_custom_data(),
  public.custom_fields_guard(),
  public.custom_fields_normalize(),
  public.lead_forms_validate(),
  public.customers_comms_merge_follow()
from public, anon, authenticated;

revoke execute on function public.comms_custom_value_error(public.custom_field_type, text[], jsonb) from public, anon;
grant execute on function public.comms_custom_value_error(public.custom_field_type, text[], jsonb)
  to authenticated, service_role;

revoke execute on function
  public.comms_validate_custom_data(uuid, public.custom_field_entity, jsonb, jsonb),
  public.comms_live_lead_form(uuid),
  public.comms_lead_form_fields(public.lead_forms)
from public, anon, authenticated;
grant execute on function
  public.comms_validate_custom_data(uuid, public.custom_field_entity, jsonb, jsonb),
  public.comms_live_lead_form(uuid),
  public.comms_lead_form_fields(public.lead_forms)
to service_role;

revoke execute on function
  public.public_booking_questions(text),
  public.public_get_lead_form(uuid),
  public.public_submit_lead(uuid, jsonb, timestamptz)
from public;
grant execute on function
  public.public_booking_questions(text),
  public.public_get_lead_form(uuid),
  public.public_submit_lead(uuid, jsonb, timestamptz)
to anon, authenticated, service_role;
