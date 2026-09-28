-- ============================================================================
-- 0103 — Shop subscription billing: a lapsed shop takes no new business
-- through its other public pages either (read 0102's header).
--
-- 0102 paused online booking and quote self-scheduling of a lapsed shop and
-- guarded the staff's own inserts (PT402). The other surfaces that sign up
-- new customers stayed open, so a shop that stopped paying the platform
-- kept taking leads (with the lead auto-reply), online membership sign-ups
-- (new recurring charges on its Connect account) and gift card sales
-- (new liability), and its staff could still sell memberships and issue
-- gift cards. Billing OFF still changes nothing (shop_can_write is true).
--
--   * Lead forms (0088): comms_live_lead_form answers the existing PT404
--     'form not found' for a lapsed shop's form, exactly as for a form the
--     shop turned off — so public_get_lead_form and public_submit_lead (and
--     with it the new customer, the lead_submissions row, the staff
--     notification and the lead_received auto-reply) stop.
--   * Online membership join (0069 / 0095): public_membership_plans lists no
--     plans; membership_join_prepare (service_role, payments
--     membership_join_checkout) answers its existing 55000 'this membership
--     plan is not available online' before creating any customer, vehicle
--     or membership. 0095's body is unchanged as membership_join_prepare_core
--     (internal, service_role) behind a wrapper with the same signature.
--   * Online gift card sales (0066 / 0095): public_gift_card_offer reads
--     enabled false; gift_card_order_prepare (service_role, payments
--     gift_card_checkout) answers its existing 55000 'online gift card sales
--     are not enabled for this shop' before creating the order. 0095's body
--     is unchanged as gift_card_order_prepare_core (same pattern).
--     An order prepared before the lapse and paid afterwards still becomes
--     its card (gift_card_order_paid): that money was already taken.
--   * Staff (PT402, 0102's billing_guard_new_record, only for an end user
--     who is an active member of the row's shop): new memberships
--     (create_membership; memberships_01_billing_guard) and gift cards issued
--     by staff (issue_gift_card, issued_via 'staff';
--     gift_cards_01_billing_guard). Store credit a referral earns when a job
--     is completed (issued_via 'referral') and refunds back onto a card are
--     not new sales and keep working (finishing existing jobs).
--   Customers see the shop's usual "not available" answers (never PT402 and
--   never the word subscription): the payments function already maps each
--   55000 above to its 409.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Lead forms: comms_live_lead_form (0088) + lapsed shops.
-- ---------------------------------------------------------------------------
create or replace function public.comms_live_lead_form(p_token uuid) returns public.lead_forms
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_form public.lead_forms;
begin
  if p_token is not null then
    select * into v_form from public.lead_forms f where f.token = p_token;
  end if;
  if v_form.id is null or not v_form.active or v_form.archived_at is not null
     or not public.shop_can_write(v_form.shop_id) then
    raise exception 'form not found' using errcode = 'PT404';
  end if;
  return v_form;
end
$$;

comment on function public.comms_live_lead_form(uuid) is
  'Internal (0088): the active lead form behind a token, else PT404 (unknown, inactive, archived; 0103: the shop is lapsed).';

-- ---------------------------------------------------------------------------
-- public_membership_plans (0069) — a lapsed shop offers no plans online.
-- ---------------------------------------------------------------------------
create or replace function public.public_membership_plans(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_open boolean;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  v_open := public.shop_can_write(v_shop.id);
  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'logo_path', v_shop.logo_path, 'brand_color', v_shop.brand_color),
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id,
               'name', p.name,
               'description', p.description,
               'price_cents', p.price_cents,
               'interval', p.interval,
               'interval_count', p.interval_count,
               'included_services', coalesce((select jsonb_agg(s.name order by s.sort, s.name)
                                                from public.services s
                                               where s.shop_id = p.shop_id and s.id = any (p.included_service_ids)
                                                 and s.archived_at is null), '[]'::jsonb),
               'discount_bps', p.discount_bps,
               'uses_per_period', p.included_uses_per_period,
               'vehicle_scoped', false,
               'terms', p.terms)
             order by p.sort, p.name, p.id)
      from public.membership_plans p
      where v_open and p.shop_id = v_shop.id and p.active and p.archived_at is null and p.online_joinable), '[]'::jsonb),
    'currency', v_shop.currency);
end
$$;

comment on function public.public_membership_plans(text) is
  'anon: the membership plans a shop offers on its public join page (0069). 0103: none while the shop is lapsed.';

-- ---------------------------------------------------------------------------
-- membership_join_prepare: 0095's function, unchanged, becomes internal.
-- ---------------------------------------------------------------------------
alter function public.membership_join_prepare(text, uuid, jsonb, timestamptz) rename to membership_join_prepare_core;
comment on function public.membership_join_prepare_core(text, uuid, jsonb, timestamptz) is
  'Internal (0103): the online membership join of 0069 / 0095. Called only by membership_join_prepare, which refuses lapsed shops first.';
revoke execute on function public.membership_join_prepare_core(text, uuid, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.membership_join_prepare_core(text, uuid, jsonb, timestamptz) to service_role;

create function public.membership_join_prepare(
  p_slug     text,
  p_plan_id  uuid,
  p_payload  jsonb,
  p_now      timestamptz default now()
) returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'this membership plan is not available online' using errcode = '55000';
  end if;
  return public.membership_join_prepare_core(p_slug, p_plan_id, p_payload, p_now);
end
$$;

comment on function public.membership_join_prepare(text, uuid, jsonb, timestamptz) is
  'service_role (payments membership_join_checkout): customer, vehicle and incomplete membership of an online join (0069 rules; 0095 HINT already_member; 0103: a lapsed shop answers 55000 before creating anything). {membership_id, customer_id, shop_id, email}.';
revoke execute on function public.membership_join_prepare(text, uuid, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.membership_join_prepare(text, uuid, jsonb, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- public_gift_card_offer (0066) — a lapsed shop is not selling online.
-- ---------------------------------------------------------------------------
create or replace function public.public_gift_card_offer(p_slug text) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop public.shops;
  v_gs   public.gift_card_settings;
begin
  select * into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if not found then
    raise exception 'shop not found' using errcode = 'PT404';
  end if;
  select * into v_gs from public.gift_card_settings g where g.shop_id = v_shop.id;
  return jsonb_build_object(
    'shop', jsonb_build_object('name', v_shop.name, 'logo_path', v_shop.logo_path, 'brand_color', v_shop.brand_color),
    'enabled', coalesce(v_gs.online_enabled, false)
               and (jsonb_array_length(coalesce(v_gs.offers, '[]'::jsonb)) > 0 or coalesce(v_gs.allow_custom_amount, false))
               and public.shop_can_write(v_shop.id),
    'offers', coalesce(v_gs.offers, '[]'::jsonb),
    'allow_custom_amount', coalesce(v_gs.allow_custom_amount, false),
    'min_custom_cents', v_gs.min_custom_cents,
    'max_custom_cents', v_gs.max_custom_cents,
    'expires_months', v_gs.expires_months,
    'terms', v_gs.terms,
    'currency', v_shop.currency);
end
$$;

comment on function public.public_gift_card_offer(text) is
  'anon: what a shop sells as gift cards online (0066). 0103: enabled false while the shop is lapsed.';

-- ---------------------------------------------------------------------------
-- gift_card_order_prepare: 0095's function, unchanged, becomes internal.
-- ---------------------------------------------------------------------------
alter function public.gift_card_order_prepare(text, jsonb, timestamptz) rename to gift_card_order_prepare_core;
comment on function public.gift_card_order_prepare_core(text, jsonb, timestamptz) is
  'Internal (0103): the online gift card order of 0066 / 0095. Called only by gift_card_order_prepare, which refuses lapsed shops first.';
revoke execute on function public.gift_card_order_prepare_core(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.gift_card_order_prepare_core(text, jsonb, timestamptz) to service_role;

create function public.gift_card_order_prepare(p_slug text, p_payload jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_shop uuid;
begin
  select s.id into v_shop from public.shops s where s.slug = lower(btrim(p_slug));
  if v_shop is not null and not public.shop_can_write(v_shop) then
    raise exception 'online gift card sales are not enabled for this shop' using errcode = '55000';
  end if;
  return public.gift_card_order_prepare_core(p_slug, p_payload, p_now);
end
$$;

comment on function public.gift_card_order_prepare(text, jsonb, timestamptz) is
  'service_role (payments gift_card_checkout): the pending order of an online gift card sale (0066 rules; 0095 HINT amount_out_of_range; 0103: a lapsed shop answers 55000 before creating it). {order_id, token, shop_id, value_cents, price_cents, currency, purchaser_email}.';
revoke execute on function public.gift_card_order_prepare(text, jsonb, timestamptz) from public, anon, authenticated;
grant execute on function public.gift_card_order_prepare(text, jsonb, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- Staff: new memberships and staff-issued gift cards (PT402, 0102's guard).
-- ---------------------------------------------------------------------------
create trigger memberships_01_billing_guard before insert on public.memberships
  for each row execute function public.billing_guard_new_record();
create trigger gift_cards_01_billing_guard before insert on public.gift_cards
  for each row when (new.issued_via = 'staff')
  execute function public.billing_guard_new_record();
