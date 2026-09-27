-- ============================================================================
-- 0049 — Global staff search (SPEC §4.9 search_shop): customers, vehicles,
-- jobs, quotes, invoices of ONE shop.
--
-- Matching (query is trimmed and lower-cased, max 200 characters; a blank
-- query returns nothing):
--   customers  search_text (name, company, email, phone) contains the query
--              as a literal substring (LIKE wildcards % _ \ in the input are
--              escaped), or trigram word-similarity (pg_trgm `<%`, catches
--              typos; only for input containing letters, so numbers never
--              fuzzy-match phone numbers), or — for phone-like input with
--              ≥ 4 digits — the phone contains those digits
--              ("(205) 555-0101" finds +12055550101)
--   vehicles   search_text (year, make, model, trim, color, plate, VIN)
--              substring or trigram word-similarity (input with letters)
--   jobs / quotes / invoices   document number prefix, for numeric input
--              optionally prefixed with '#' ("#1004", "100")
-- Up to p_limit (1-100, default 20) results PER KIND, best first
-- (score = 2 exact number / 1 substring match + trigram similarity).
--
-- Visibility follows the SPEC §3 matrix:
--   owner/admin/manager  everything in the shop
--   technician           customers / vehicles on their assigned jobs, their
--                        assigned jobs, no quotes, and invoices only of
--                        assigned jobs when shops.techs_can_collect_payments
--   anyone else          42501
-- ============================================================================

-- Number prefix search on the per-shop document numbers.
create index jobs_shop_number_text_idx on public.jobs (shop_id, (number::text) text_pattern_ops);
create index quotes_shop_number_text_idx on public.quotes (shop_id, (number::text) text_pattern_ops);
create index invoices_shop_number_text_idx on public.invoices (shop_id, (number::text) text_pattern_ops);

create function public.search_shop(p_shop_id uuid, p_query text, p_limit integer default 20)
returns table (
  kind         text,
  id           uuid,
  title        text,
  subtitle     text,
  number       bigint,
  status       text,
  customer_id  uuid,
  job_id       uuid,
  archived     boolean,
  score        real
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_role    public.shop_role := public.report_caller_role(p_shop_id, true);
  v_full    boolean := v_role in ('owner', 'admin', 'manager');
  v_q       text := lower(btrim(coalesce(p_query, '')));
  v_like    text;
  v_digits  text;
  v_phone   text;
  v_num     text;
  v_fuzzy   boolean;
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'limit must be between 1 and 100' using errcode = '22023';
  end if;
  if char_length(v_q) > 200 then
    raise exception 'search text is limited to 200 characters' using errcode = '22023';
  end if;
  if v_q = '' then
    return;
  end if;

  v_like := '%' || public.like_escape(v_q) || '%';
  v_fuzzy := v_q ~ '[[:alpha:]]';
  v_digits := regexp_replace(v_q, '[^0-9]', '', 'g');
  if v_q ~ '^[0-9()+. -]+$' and char_length(v_digits) >= 4 then
    v_phone := v_digits;
  end if;
  if v_q ~ '^#?[0-9]{1,18}$' then
    v_num := ltrim(v_q, '#');
  end if;

  return query
  select results.k, results.rid, results.ttl, results.sub, results.num, results.st,
         results.cid, results.jid, results.arch, results.sc
  from (
    -- customers
    (select 'customer'::text as k, c.id as rid,
            public.report_customer_label(c.first_name, c.last_name, c.company) as ttl,
            nullif(concat_ws(' · ', case when nullif(btrim(concat_ws(' ', c.first_name, c.last_name)), '') is not null
                                         then c.company end,
                                    c.email::text, c.phone), '') as sub,
            null::bigint as num, c.lifecycle::text as st, c.id as cid, null::uuid as jid,
            c.archived_at is not null as arch,
            ((case when c.search_text like v_like escape '\'
                     or (v_phone is not null and c.phone like '%' || v_phone || '%') then 1 else 0 end)
             + extensions.word_similarity(v_q, c.search_text))::real as sc
     from public.customers c
     where c.shop_id = p_shop_id
       and (c.search_text like v_like escape '\'
            or (v_fuzzy and v_q operator(extensions.<%) c.search_text)
            or (v_phone is not null and c.phone like '%' || v_phone || '%'))
       and (v_full or public.is_customer_on_assigned_job(c.id))
     order by sc desc, (c.archived_at is not null), 3, c.id
     limit p_limit)
    union all
    -- vehicles
    (select 'vehicle'::text, v.id,
            coalesce(public.report_vehicle_label(v.year, v.make, v.model), v.license_plate, v.vin, 'Vehicle'),
            nullif(concat_ws(' · ', v.license_plate, v.vin,
                             public.report_customer_label(c.first_name, c.last_name, c.company)), ''),
            null::bigint, null::text, v.customer_id, null::uuid, v.archived_at is not null,
            ((case when v.search_text like v_like escape '\' then 1 else 0 end)
             + extensions.word_similarity(v_q, v.search_text))::real as sc
     from public.vehicles v
     join public.customers c on c.shop_id = v.shop_id and c.id = v.customer_id
     where v.shop_id = p_shop_id
       and (v.search_text like v_like escape '\'
            or (v_fuzzy and v_q operator(extensions.<%) v.search_text))
       and (v_full or public.is_vehicle_on_assigned_job(v.id))
     order by sc desc, (v.archived_at is not null), 3, v.id
     limit p_limit)
    union all
    -- jobs
    (select 'job'::text, j.id,
            'Job #' || j.number,
            public.report_customer_label(c.first_name, c.last_name, c.company),
            j.number, j.status::text, j.customer_id, j.id, false,
            (case when j.number::text = v_num then 2 else 1 end)::real as sc
     from public.jobs j
     join public.customers c on c.shop_id = j.shop_id and c.id = j.customer_id
     where v_num is not null
       and j.shop_id = p_shop_id
       and j.number::text like v_num || '%'
       and (v_full or public.is_assigned_to_job(j.id))
     order by sc desc, j.number
     limit p_limit)
    union all
    -- quotes (managers+ only)
    (select 'quote'::text, q.id,
            'Quote #' || q.number,
            public.report_customer_label(c.first_name, c.last_name, c.company),
            q.number, q.status::text, q.customer_id, q.converted_job_id, false,
            (case when q.number::text = v_num then 2 else 1 end)::real as sc
     from public.quotes q
     join public.customers c on c.shop_id = q.shop_id and c.id = q.customer_id
     where v_num is not null and v_full
       and q.shop_id = p_shop_id
       and q.number::text like v_num || '%'
     order by sc desc, q.number
     limit p_limit)
    union all
    -- invoices (managers+, or collecting technicians for assigned jobs)
    (select 'invoice'::text, i.id,
            'Invoice #' || i.number,
            public.report_customer_label(c.first_name, c.last_name, c.company),
            i.number, i.status::text, i.customer_id, i.job_id, false,
            (case when i.number::text = v_num then 2 else 1 end)::real as sc
     from public.invoices i
     join public.customers c on c.shop_id = i.shop_id and c.id = i.customer_id
     where v_num is not null
       and i.shop_id = p_shop_id
       and i.number::text like v_num || '%'
       and (v_full or (i.job_id is not null and public.can_collect_for_job(p_shop_id, i.job_id)))
     order by sc desc, i.number
     limit p_limit)
  ) as results
  order by case results.k when 'customer' then 1 when 'vehicle' then 2 when 'job' then 3
                          when 'quote' then 4 else 5 end,
           results.sc desc, results.arch, results.num, results.ttl, results.rid;
end
$$;

comment on function public.search_shop(uuid, text, integer) is
  'Staff global search (customers, vehicles, jobs, quotes, invoices) with LIKE-escaped input and role-based visibility; p_limit applies per kind. @nullable: subtitle, number, status, customer_id, job_id';

revoke execute on function public.search_shop(uuid, text, integer) from public, anon;
grant execute on function public.search_shop(uuid, text, integer) to authenticated, service_role;
