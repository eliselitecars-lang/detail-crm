-- ============================================================================
-- 0014 — Public money RPCs (SPEC §4.9): public_get_quote, public_respond_quote,
-- public_get_invoice. Anonymous (or signed-in) visitors holding the
-- unguessable public_token get a curated JSON document: shop branding,
-- customer name, vehicle, lines and totals. Never exposed: internal notes,
-- ids other than quote line ids (needed to pick optional lines), Stripe ids,
-- notes on payments, who recorded what, or anything about staff pay.
--
-- Draft quotes and draft invoices are not published (not found). Time checks
-- use now() — public RPCs never accept a caller-supplied clock.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Internal JSON builders (not executable by API roles; called from the
-- SECURITY DEFINER entry points below).
-- ---------------------------------------------------------------------------
create function public.money_public_shop_json(p_shop_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'name', s.name,
    'slug', s.slug,
    'logo_path', s.logo_path,
    'brand_color', s.brand_color,
    'email', s.email::text,
    'phone', s.phone,
    'website', s.website,
    'address_line1', s.address_line1,
    'address_line2', s.address_line2,
    'city', s.city,
    'region', s.region,
    'postal_code', s.postal_code,
    'country', s.country,
    'timezone', s.timezone,
    'currency', s.currency,
    'review_url', s.review_url)
  from public.shops s
  where s.id = p_shop_id
$$;

create function public.money_public_vehicle_json(p_shop_id uuid, p_vehicle_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object('year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'color', v.color)
  from public.vehicles v
  where v.id = p_vehicle_id and v.shop_id = p_shop_id
$$;

create function public.money_vehicle_label(p_shop_id uuid, p_vehicle_id uuid) returns text
language sql stable
set search_path = ''
as $$
  select nullif(btrim(concat_ws(' ', v.year::text, v.make, v.model)), '')
  from public.vehicles v
  where v.id = p_vehicle_id and v.shop_id = p_shop_id
$$;

create function public.money_public_quote_json(p_quote_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', public.money_public_shop_json(q.shop_id),
    'quote', jsonb_build_object(
      'number', q.number,
      'status', q.status,
      'valid_until', q.valid_until,
      'expires_at', case when q.valid_until is not null then public.quote_validity_end(q.valid_until, s.timezone) end,
      'notes', q.notes,
      'terms', q.terms,
      'subtotal_cents', q.subtotal_cents,
      'discount_cents', q.discount_cents,
      'tax_rate_bps', q.tax_rate_bps,
      'tax_cents', q.tax_cents,
      'total_cents', q.total_cents,
      'sent_at', q.sent_at,
      'viewed_at', q.viewed_at,
      'approved_at', q.approved_at,
      'approved_by_name', q.approved_by_name,
      'declined_at', q.declined_at,
      'declined_reason', q.declined_reason,
      'expired_at', q.expired_at,
      'can_respond', q.status in ('sent', 'viewed')
                     and (q.valid_until is null or public.quote_validity_end(q.valid_until, s.timezone) > now())),
    'customer', jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'company', c.company),
    'vehicle', public.money_public_vehicle_json(q.shop_id, q.vehicle_id),
    'line_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', li.id,
               'name', li.name,
               'description', li.description,
               'vehicle_label', public.money_vehicle_label(li.shop_id, li.vehicle_id),
               'quantity', li.quantity,
               'unit_price_cents', li.unit_price_cents,
               'discount_cents', li.discount_cents,
               'taxable', li.taxable,
               'total_cents', li.total_cents,
               'optional', li.optional,
               'selected', li.selected)
             order by li.sort, li.created_at, li.id)
      from public.quote_line_items li
      where li.quote_id = q.id and li.shop_id = q.shop_id), '[]'::jsonb))
  from public.quotes q
  join public.shops s on s.id = q.shop_id
  join public.customers c on c.id = q.customer_id and c.shop_id = q.shop_id
  where q.id = p_quote_id
$$;

create function public.money_public_invoice_json(p_invoice_id uuid) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'shop', public.money_public_shop_json(i.shop_id),
    'invoice', jsonb_build_object(
      'number', i.number,
      'status', i.status,
      'issued_at', i.issued_at,
      'due_at', i.due_at,
      'paid_at', i.paid_at,
      'voided_at', i.voided_at,
      'notes', i.notes,
      'terms', i.terms,
      'subtotal_cents', i.subtotal_cents,
      'discount_cents', i.discount_cents,
      'tax_rate_bps', i.tax_rate_bps,
      'tax_cents', i.tax_cents,
      'total_cents', i.total_cents,
      'amount_paid_cents', i.amount_paid_cents,
      'balance_cents', i.balance_cents,
      'tip_cents', i.tip_cents,
      'payable', i.status in ('open', 'partially_paid') and i.balance_cents > 0,
      'card_payments_enabled', coalesce((select a.charges_enabled from public.shop_stripe_accounts a
                                         where a.shop_id = i.shop_id), false)),
    'customer', jsonb_build_object('first_name', c.first_name, 'last_name', c.last_name, 'company', c.company),
    'job', (select jsonb_build_object('number', j.number, 'scheduled_start', j.scheduled_start,
                                      'scheduled_end', j.scheduled_end)
              from public.jobs j where j.id = i.job_id and j.shop_id = i.shop_id),
    'vehicle', (select public.money_public_vehicle_json(j.shop_id, j.vehicle_id)
                  from public.jobs j where j.id = i.job_id and j.shop_id = i.shop_id),
    'line_items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', li.name,
               'description', li.description,
               'vehicle_label', public.money_vehicle_label(li.shop_id, li.vehicle_id),
               'quantity', li.quantity,
               'unit_price_cents', li.unit_price_cents,
               'discount_cents', li.discount_cents,
               'taxable', li.taxable,
               'total_cents', li.total_cents)
             order by li.sort, li.created_at, li.id)
      from public.invoice_line_items li
      where li.invoice_id = i.id and li.shop_id = i.shop_id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', p.kind,
               'method', p.method,
               'status', p.status,
               'amount_cents', p.amount_cents,
               'tip_cents', p.tip_cents,
               'refunded_cents', p.refunded_cents,
               'card_brand', p.card_brand,
               'card_last4', p.card_last4,
               'paid_at', p.paid_at)
             order by p.paid_at, p.created_at, p.id)
      from public.payments p
      where p.invoice_id = i.id and p.shop_id = i.shop_id
        and p.status in ('succeeded', 'partially_refunded', 'refunded')), '[]'::jsonb))
  from public.invoices i
  join public.customers c on c.id = i.customer_id and c.shop_id = i.shop_id
  where i.id = p_invoice_id
$$;

-- ---------------------------------------------------------------------------
-- public_get_quote(token) — marks a sent quote viewed on the first open by
-- someone who is not staff of the shop (staff previews don't count), and
-- expires a sent/viewed quote whose validity has ended.
-- ---------------------------------------------------------------------------
create function public.public_get_quote(p_token uuid) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_q   public.quotes;
  v_tz  text;
begin
  select * into v_q from public.quotes q where q.public_token = p_token for update;
  if not found or v_q.status = 'draft' then
    raise exception 'quote not found' using errcode = 'PT404';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.status in ('sent', 'viewed') and v_q.valid_until is not null
     and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    update public.quotes set status = 'expired' where id = v_q.id;
  elsif v_q.status = 'sent' and not public.is_shop_member(v_q.shop_id) then
    update public.quotes set status = 'viewed' where id = v_q.id;
  end if;
  return public.money_public_quote_json(v_q.id);
end
$$;

-- ---------------------------------------------------------------------------
-- public_respond_quote(token, action, signer_name, selected optional line
-- ids, declined_reason). Only sent/viewed, unexpired quotes. 'approve'
-- requires a typed signer name and sets exactly the chosen optional lines as
-- selected (totals recompute server-side); 'decline' records the reason.
-- ---------------------------------------------------------------------------
create function public.public_respond_quote(
  p_token                      uuid,
  p_action                     text,
  p_signer_name                text default null,
  p_selected_optional_line_ids uuid[] default '{}',
  p_declined_reason            text default null
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_q       public.quotes;
  v_tz      text;
  v_action  text := lower(btrim(p_action));
  v_signer  text := nullif(btrim(p_signer_name), '');
  v_reason  text := nullif(btrim(p_declined_reason), '');
  v_ids     uuid[];
begin
  select * into v_q from public.quotes q where q.public_token = p_token for update;
  if not found or v_q.status = 'draft' then
    raise exception 'quote not found' using errcode = 'PT404';
  end if;
  if v_action is null or v_action not in ('approve', 'decline') then
    raise exception 'action must be approve or decline' using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.status not in ('sent', 'viewed') then
    raise exception 'this quote can no longer be answered (it is %)', v_q.status using errcode = '22023';
  end if;
  if v_q.valid_until is not null and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    raise exception 'this quote has expired' using errcode = '22023';
  end if;

  if v_action = 'approve' then
    if v_signer is null or char_length(v_signer) > 200 then
      raise exception 'type your full name (up to 200 characters) to approve' using errcode = '22023';
    end if;
    v_ids := array(select distinct x from unnest(coalesce(p_selected_optional_line_ids, '{}'::uuid[])) as x
                   where x is not null);
    if exists (select 1 from unnest(v_ids) as x
               where not exists (select 1 from public.quote_line_items li
                                 where li.id = x and li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional)) then
      raise exception 'selected items must be optional items of this quote' using errcode = '22023';
    end if;
    update public.quote_line_items li
       set selected = (li.id = any (v_ids))
     where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional
       and li.selected is distinct from (li.id = any (v_ids));
    update public.quotes set status = 'approved', approved_by_name = v_signer where id = v_q.id;
  else
    if char_length(v_reason) > 1000 then
      raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
    end if;
    update public.quotes set status = 'declined', declined_reason = v_reason where id = v_q.id;
  end if;
  return public.money_public_quote_json(v_q.id);
end
$$;

-- ---------------------------------------------------------------------------
-- public_get_invoice(token) — issued invoices (including paid and void) with
-- balance, payments received and whether it can be paid online now.
-- ---------------------------------------------------------------------------
create function public.public_get_invoice(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
begin
  select * into v_inv from public.invoices i where i.public_token = p_token;
  if not found or v_inv.status = 'draft' then
    raise exception 'invoice not found' using errcode = 'PT404';
  end if;
  return public.money_public_invoice_json(v_inv.id);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.money_public_shop_json(uuid),
  public.money_public_vehicle_json(uuid, uuid),
  public.money_vehicle_label(uuid, uuid),
  public.money_public_quote_json(uuid),
  public.money_public_invoice_json(uuid)
from public, anon, authenticated;

revoke execute on function
  public.public_get_quote(uuid),
  public.public_respond_quote(uuid, text, text, uuid[], text),
  public.public_get_invoice(uuid)
from public;
grant execute on function
  public.public_get_quote(uuid),
  public.public_respond_quote(uuid, text, text, uuid[], text),
  public.public_get_invoice(uuid)
to anon, authenticated, service_role;
