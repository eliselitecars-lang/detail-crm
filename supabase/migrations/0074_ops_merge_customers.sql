-- ============================================================================
-- 0074 — Merge duplicate customers (P-20).
--
--   merge_customers_preview(source, target)  owner/admin: what would move
--                                            and what blocks the merge.
--   merge_customers(source, target)          owner/admin (a delete-class
--                                            action, SPEC §3): moves every
--                                            record of the duplicate
--                                            (source) to the surviving
--                                            customer (target), fills the
--                                            target's empty fields, archives
--                                            the source and points it at the
--                                            target (merged_into_id). One
--                                            transaction.
--
-- MERGE CONTRACT: merge_customers sets detailcrm.customer_merge = 'on'
-- (transaction-local) while it moves rows; every guard that refuses a
-- customer_id change skips ONLY that check when the setting is 'on' and the
-- caller is not client context (direct API writes never get the bypass):
-- vehicles_keep_owner_history and jobs_customer_records_guard (here),
-- jobs_money_guard / jobs_quote_validate / jobs_customer_change /
-- invoice_jobs' guard / the coupon rules (money 0062-0063), and
-- job_series_validate (sched 0051). Rows of later ranges move from their own
-- AFTER UPDATE OF merged_into_id ON customers triggers. Likewise the
-- customer-change revocation of a job's live report (jobs_ops_report_
-- customer_change, 0072) keeps the report link during a merge. New inbound
-- texts from the duplicate's number follow merged_into_id to the survivor
-- (comms_inbound_sms_customer + record_inbound_sms, defined below).
--
-- The merged records are the same person's, so a merge never costs the
-- customer a working link or a queued message: booking links (jobs, money
-- 0063), quote links and statuses, unsigned form links and the appointment
-- stamps that drive reminders are kept, and so are job report links (0072).
-- Queued messages move to the survivor and are re-addressed to the
-- survivor's address on their channel when they were addressed to the
-- duplicate's current one (the survivor keeps its own phone / email, and a
-- message to any other address is withdrawn at claim time while its
-- automation / follow-up log still says it was queued, so nothing would
-- replace it); a marketing email's unsubscribe credential follows its
-- address. Promotions (campaigns, marketing keys) are re-addressed only
-- when the survivor has the channel's marketing opt-in for its address, and
-- a marketing email that already had a send attempt keeps its address (its
-- link may have reached that inbox); those are withdrawn at claim time as
-- before. Consent is re-checked at claim time against the survivor as
-- usual. A queued message that would duplicate one the survivor already has
-- is cancelled instead: the duplicate's message for a campaign the survivor
-- is also a recipient of, and the messages of a reminder log row dropped
-- because the survivor has the same one (same job, start and offset).
-- Order (each step's guards read the
-- rows the previous steps moved):
--   campaign recipients (duplicates of the source per campaign are dropped)
--   -> messages -> automation log (both before the jobs, so moving a job
--   neither cancels its queued reminders nor forgets which were sent)
--   -> vehicles -> jobs (+ documents follow, 0075) -> job series ->
--   calendar events -> quotes -> invoices -> memberships -> payments (a
--   payment follows its invoice / job / membership) -> saved cards (the
--   source's default is dropped when the target has one; each card keeps
--   its stripe_customer_id) -> form submissions -> coupon redemptions
--   (once-per-customer: the target's marker wins) -> coupons (customer /
--   referrer) -> gift cards (purchaser / owner) -> referral credits ->
--   notifications -> documents -> customer fields -> the source.
-- Customer fields: tags union (max 50), notes appended ("Merged from <name>
-- on <date>: ..."), empty target fields filled from the source (the address
-- as a whole, lat/lng as a pair), lifecycle 'customer' if either is,
-- opt-outs OR-ed (the earlier timestamp), opt-ins follow their address
-- (consent is never inferred, TCPA / CAN-SPAM: consent belongs to the number
-- or inbox it was given with): when the survivor's phone / email is filled
-- from the duplicate, the channel's opt-in is the duplicate's; when the
-- survivor keeps its own, it is the survivor's (or-ed with the duplicate's
-- only when both have that same address); with no address on either, the
-- survivor's; never on while the merged opt-out stamp is set.
-- portal_user_id / stripe_customer_id /
-- referral_code: the target's, else the source's (cleared on the source
-- first to satisfy the unique indexes).
--
-- A merged duplicate cannot be un-archived from client context (42501).
-- Refused (22023): source = target; the source was already merged; the
-- target is archived or itself merged; the two are linked to different
-- client portal accounts; both have an open membership of the same plan for
-- the same vehicle (or both vehicle-less). Unknown customer, another shop's
-- customer or a caller outside the shop: P0002. Managers/technicians: 42501.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- merged_into_id is server-set (merge_customers), and a merged duplicate
-- stays archived: restoring it from client context would bring back a live
-- customer that still points at the survivor (inbound texts keep following
-- the merge, lead-source reports leave it out, and it could never be merged
-- again). Its other fields stay editable.
-- ---------------------------------------------------------------------------
create function public.customers_ops_merge_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context()
     and ((tg_op = 'INSERT' and new.merged_into_id is not null)
          or (tg_op = 'UPDATE' and new.merged_into_id is distinct from old.merged_into_id)) then
    raise exception 'customers are merged with merge_customers' using errcode = '42501';
  end if;
  if public.is_client_context() and tg_op = 'UPDATE'
     and old.merged_into_id is not null and new.archived_at is null then
    raise exception 'this customer was merged into another customer and cannot be restored'
      using errcode = '42501';
  end if;
  return new;
end
$$;

create trigger customers_70_merge_guard before insert or update on public.customers
  for each row execute function public.customers_ops_merge_guard();

-- The merge setting is honoured only for trusted code. Inside a SECURITY
-- DEFINER guard is_client_context() is always false (current_user is the
-- owner), so a direct API write clears the setting first: a statement-level
-- BEFORE trigger runs before every row trigger of the statement, the money
-- and ops guards included. (API roles cannot set it through PostgREST in
-- the first place; this is defence in depth.)
create function public.ops_customer_merge_scrub() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.is_client_context() then
    perform set_config('detailcrm.customer_merge', '', true);
  end if;
  return null;
end
$$;

create trigger vehicles_70_merge_scrub before update of customer_id on public.vehicles
  for each statement execute function public.ops_customer_merge_scrub();
create trigger jobs_71_merge_scrub before update of customer_id on public.jobs
  for each statement execute function public.ops_customer_merge_scrub();

-- A saved card remembers the Stripe customer it is attached to.
create function public.customer_payment_methods_ops_stripe_customer() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.stripe_customer_id is null then
    select c.stripe_customer_id into new.stripe_customer_id
      from public.customers c where c.id = new.customer_id and c.shop_id = new.shop_id;
  end if;
  return new;
end
$$;

create trigger customer_payment_methods_70_stripe_customer before insert on public.customer_payment_methods
  for each row execute function public.customer_payment_methods_ops_stripe_customer();

-- ---------------------------------------------------------------------------
-- vehicles_keep_owner_history (0004) — merge bypass.
-- ---------------------------------------------------------------------------
create or replace function public.vehicles_keep_owner_history() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  r        record;
  v_found  boolean;
begin
  -- merge_customers moves a duplicate's vehicles with all their records
  if coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context() then
    return null;
  end if;
  for r in
    select format('%I.%I', n.nspname, cl.relname) as tbl,
           cl.relname::text as label,
           string_agg(format('t.%I = ($1).%I', a.attname, fa.attname), ' and ' order by k.ord) as cond
    from pg_catalog.pg_constraint c
    join pg_catalog.pg_class cl on cl.oid = c.conrelid
    join pg_catalog.pg_namespace n on n.oid = cl.relnamespace
    cross join lateral unnest(c.conkey, c.confkey) with ordinality as k(att, fatt, ord)
    join pg_catalog.pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.att
    join pg_catalog.pg_attribute fa on fa.attrelid = c.confrelid and fa.attnum = k.fatt
    where c.contype = 'f' and c.confrelid = 'public.vehicles'::regclass
    group by c.oid, n.nspname, cl.relname
    order by n.nspname, cl.relname, c.oid
  loop
    execute format('select exists (select 1 from %s t where %s)', r.tbl, r.cond) into v_found using old;
    if v_found then
      raise exception 'this vehicle is referenced by % of its current customer and cannot be moved to another customer; add it as a new vehicle for the new owner',
                      replace(r.label, '_', ' ')
        using errcode = '23514';
    end if;
  end loop;
  return null;
end
$$;

-- ---------------------------------------------------------------------------
-- jobs_customer_records_guard (0023) — merge bypass.
-- ---------------------------------------------------------------------------
create or replace function public.jobs_customer_records_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.customer_id is distinct from old.customer_id
     and not (coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on' and not public.is_client_context()) then
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

-- ---------------------------------------------------------------------------
-- comms_inbound_sms_customer (new here; service_role only, see Grants) —
-- the customer an inbound text belongs to, following merges. The duplicate keeps its phone when the survivor has its
-- own, so a text from the duplicate's number is matched to the duplicate and
-- then followed along merged_into_id to the customer that survived (a
-- survivor may itself have been merged later). Order: a customer who holds
-- the number and is active, then the active survivor of a merged holder,
-- then the rest (archived), newest holder first. The survivor of a merge is
-- the same person, so the message, its thread (inbox_threads), the reply and
-- the staff notification all land on the live record.
-- ---------------------------------------------------------------------------
create or replace function public.comms_inbound_sms_customer(p_shop_id uuid, p_phone text) returns public.customers
language sql stable security definer
set search_path = ''
as $$
  with recursive chain (holder_id, holder_created_at, id, merged_into_id, depth) as (
    select c.id, c.created_at, c.id, c.merged_into_id, 0
      from public.customers c
     where c.shop_id = p_shop_id and c.phone = p_phone
    union all
    select ch.holder_id, ch.holder_created_at, n.id, n.merged_into_id, ch.depth + 1
      from chain ch
      join public.customers n on n.shop_id = p_shop_id and n.id = ch.merged_into_id
     where ch.depth < 32
  )
  select s.*
    from chain ch
    join public.customers s on s.shop_id = p_shop_id and s.id = ch.id
   where ch.merged_into_id is null
   order by (s.archived_at is null) desc, (ch.depth = 0) desc, ch.holder_created_at desc, ch.holder_id
   limit 1
$$;

-- ---------------------------------------------------------------------------
-- record_inbound_sms (comms 0033; re-defined here, once, for P-20). The body
-- is 0033's unchanged except the From-number lookup, which now goes through
-- comms_inbound_sms_customer so a text from a merged duplicate's number lands
-- on the surviving customer. Defined in this new migration (never by editing
-- the committed 0033) so a database that already applied 0033 picks it up.
-- Any later change to record_inbound_sms must start from this version.
-- ---------------------------------------------------------------------------
create or replace function public.record_inbound_sms(
  p_to           text,
  p_from         text,
  p_body         text,
  p_provider_id  text default null
) returns table (message_id uuid, shop_id uuid, customer_id uuid, opt_action text)
language plpgsql security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_to      text := btrim(coalesce(p_to, ''));
  v_from    text := btrim(coalesce(p_from, ''));
  v_body    text := left(coalesce(p_body, ''), 1600);
  v_pid     text := nullif(btrim(coalesce(p_provider_id, '')), '');
  v_shop    public.shops;
  v_cust    public.customers;
  v_kw      text;
  v_action  text;
  v_existing public.messages;
  v_id      uuid;
  v_who     text;
begin
  if not public.is_valid_e164(v_to) or not public.is_valid_e164(v_from) then
    raise exception 'to and from must be E.164 phone numbers' using errcode = '22023';
  end if;
  select s.* into v_shop
    from public.shop_sms_numbers n join public.shops s on s.id = n.shop_id
   where n.phone_number = v_to;
  if not found then
    return;
  end if;

  if v_pid is not null then
    select * into v_existing from public.messages m where m.provider_message_id = v_pid;
    if found then
      return query select v_existing.id, v_existing.shop_id, v_existing.customer_id, null::text;
      return;
    end if;
  end if;

  v_cust := public.comms_inbound_sms_customer(v_shop.id, v_from);

  v_kw := upper(regexp_replace(btrim(v_body), '[[:space:][:punct:]]+$', ''));
  if v_kw in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'OPTOUT', 'REVOKE') then
    v_action := 'opt_out';
    -- the number is suppressed even when no customer has it yet
    perform public.comms_suppress(v_shop.id, 'sms', v_from, now());
  elsif v_kw in ('START', 'UNSTOP', 'YES') then
    v_action := 'opt_in';
    perform public.comms_unsuppress(v_shop.id, 'sms', v_from);
  end if;

  begin
    insert into public.messages (shop_id, customer_id, direction, channel, to_address, from_address, body,
                                 status, provider_message_id, send_after)
    values (v_shop.id, v_cust.id, 'inbound', 'sms', v_to, v_from, v_body, 'received', v_pid, now())
    returning id into v_id;
  exception when unique_violation then
    -- a concurrent delivery of the same webhook won the race
    select * into v_existing from public.messages m where m.provider_message_id = v_pid;
    return query select v_existing.id, v_existing.shop_id, v_existing.customer_id, null::text;
    return;
  end;

  v_who := coalesce(nullif(btrim(concat_ws(' ', nullif(btrim(v_cust.first_name), ''),
                                                nullif(btrim(v_cust.last_name), ''))), ''),
                    nullif(btrim(v_cust.company), ''), public.format_phone(v_from));
  perform public.notify_shop_staff(
    v_shop.id, array['owner', 'admin', 'manager']::public.shop_role[], 'inbound_message',
    case v_action
      when 'opt_out' then v_who || ' opted out of text messages'
      when 'opt_in'  then v_who || ' opted back in to text messages'
      else 'New text from ' || v_who
    end,
    nullif(left(v_body, 280), ''),
    p_customer_id => v_cust.id);

  return query select v_id, v_shop.id, v_cust.id, v_action;
end
$$;

comment on function public.record_inbound_sms(text, text, text, text) is '@nullable: customer_id, opt_action';

-- ---------------------------------------------------------------------------
-- Internals shared by the preview and the merge (no access checks).
-- ---------------------------------------------------------------------------
create function public.merge_customer_summary(p_c public.customers) returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_c.id,
    'name', public.report_customer_label(p_c.first_name, p_c.last_name, p_c.company),
    'email', p_c.email,
    'phone', p_c.phone,
    'lifecycle', p_c.lifecycle,
    'created_at', p_c.created_at,
    'archived_at', p_c.archived_at,
    'merged_into_id', p_c.merged_into_id,
    'portal_linked', p_c.portal_user_id is not null,
    'has_stripe_customer', p_c.stripe_customer_id is not null)
$$;

-- Rows of the source that a merge moves.
create function public.merge_customer_counts(p_shop_id uuid, p_customer_id uuid) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'vehicles',    (select count(*) from public.vehicles x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'jobs',        (select count(*) from public.jobs x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'series',      (select count(*) from public.job_series x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'events',      (select count(*) from public.blocked_times x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'quotes',      (select count(*) from public.quotes x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'invoices',    (select count(*) from public.invoices x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'payments',    (select count(*) from public.payments x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'memberships', (select count(*) from public.memberships x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'saved_cards', (select count(*) from public.customer_payment_methods x
                     where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'messages',    (select count(*) from public.messages x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'forms',       (select count(*) from public.form_submissions x
                     where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'documents',   (select count(*) from public.documents x where x.shop_id = p_shop_id and x.customer_id = p_customer_id),
    'gift_cards',  (select count(*) from public.gift_cards x
                     where x.shop_id = p_shop_id
                       and (x.purchaser_customer_id = p_customer_id or x.owner_customer_id = p_customer_id)),
    'coupons',     (select count(*) from public.coupons x
                     where x.shop_id = p_shop_id
                       and (x.customer_id = p_customer_id or x.referrer_customer_id = p_customer_id)))
$$;

-- Conflicts: [{code, blocking, message}] (blocking first).
create function public.merge_customer_conflicts(p_source public.customers, p_target public.customers) returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'blocking', c.blocking, 'message', c.message)
                            order by c.blocking desc, c.ord), '[]'::jsonb)
  from (
    select 1 as ord, 'same_customer' as code, true as blocking, 'a customer cannot be merged into itself' as message
     where p_source.id = p_target.id
    union all
    select 2, 'source_merged', true, 'this customer was already merged into another customer'
     where p_source.merged_into_id is not null
    union all
    select 3, 'target_merged', true, 'the surviving customer was itself merged into another customer'
     where p_target.merged_into_id is not null
    union all
    select 4, 'target_archived', true, 'the surviving customer is archived; restore it first'
     where p_target.archived_at is not null and p_target.merged_into_id is null
    union all
    select 5, 'portal_accounts', true,
           'both customers are linked to different client portal accounts; unlink one first'
     where p_source.portal_user_id is not null and p_target.portal_user_id is not null
       and p_source.portal_user_id <> p_target.portal_user_id
    union all
    select 6, 'open_memberships', true,
           format('both customers have an open %s membership for the same vehicle; cancel one first', mp.name)
      from public.memberships ms
      join public.memberships mt on mt.shop_id = ms.shop_id and mt.plan_id = ms.plan_id
                                and mt.vehicle_id is not distinct from ms.vehicle_id
      join public.membership_plans mp on mp.id = ms.plan_id and mp.shop_id = ms.shop_id
     where ms.shop_id = p_source.shop_id and ms.customer_id = p_source.id and ms.status <> 'cancelled'
       and mt.customer_id = p_target.id and mt.status <> 'cancelled'
    union all
    select 10, 'default_card', false, 'both customers have a default saved card; the surviving customer''s stays the default'
     where exists (select 1 from public.customer_payment_methods pm
                    where pm.shop_id = p_source.shop_id and pm.customer_id = p_source.id and pm.is_default)
       and exists (select 1 from public.customer_payment_methods pm
                    where pm.shop_id = p_target.shop_id and pm.customer_id = p_target.id and pm.is_default)
    union all
    select 11, 'stripe_customers', false,
           'both customers have a Stripe customer; the surviving customer''s is kept and moved cards keep charging on the Stripe customer they are attached to'
     where p_source.stripe_customer_id is not null and p_target.stripe_customer_id is not null
    union all
    select 12, 'campaign_duplicates', false,
           format('%s campaign(s) reached both customers; the duplicate recipient rows are removed', count(*))
      from public.campaign_recipients cs
     where cs.shop_id = p_source.shop_id and cs.customer_id = p_source.id
       and exists (select 1 from public.campaign_recipients ct
                    where ct.campaign_id = cs.campaign_id and ct.customer_id = p_target.id)
    having count(*) > 0
    union all
    select 13, 'coupon_once', false,
           format('%s once-per-customer coupon(s) were used by both customers', count(*))
      from public.coupon_redemptions rs
     where rs.shop_id = p_source.shop_id and rs.customer_id = p_source.id and rs.once_per_customer
       and exists (select 1 from public.coupon_redemptions rt
                    where rt.coupon_id = rs.coupon_id and rt.customer_id = p_target.id and rt.once_per_customer)
    having count(*) > 0
    union all
    select 14, 'referral_codes', false, 'both customers have a referral code; the surviving customer''s is kept (the other keeps working)'
     where p_source.referral_code is not null and p_target.referral_code is not null
  ) c
$$;

-- ---------------------------------------------------------------------------
-- merge_customers_preview — owner/admin.
--   {source, target, counts: {vehicles, jobs, series, events, quotes,
--    invoices, payments, memberships, saved_cards, messages, forms,
--    documents, gift_cards, coupons}, conflicts: [{code, blocking, message}],
--    can_merge}
-- ---------------------------------------------------------------------------
create function public.merge_customers_preview(p_source_id uuid, p_target_id uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_src public.customers;
  v_tgt public.customers;
  v_conflicts jsonb;
begin
  select * into v_src from public.customers c where c.id = p_source_id;
  if not found or not public.is_shop_member(v_src.shop_id) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_src.shop_id) then
    raise exception 'only owners and admins can merge customers' using errcode = '42501';
  end if;
  select * into v_tgt from public.customers c where c.id = p_target_id and c.shop_id = v_src.shop_id;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  v_conflicts := public.merge_customer_conflicts(v_src, v_tgt);
  return jsonb_build_object(
    'source', public.merge_customer_summary(v_src),
    'target', public.merge_customer_summary(v_tgt),
    'counts', public.merge_customer_counts(v_src.shop_id, v_src.id),
    'conflicts', v_conflicts,
    'can_merge', not exists (select 1 from jsonb_array_elements(v_conflicts) e where (e ->> 'blocking')::boolean));
end
$$;

-- ---------------------------------------------------------------------------
-- merge_customers — owner/admin. Returns {target_id, moved: {counts}}.
-- ---------------------------------------------------------------------------
create function public.merge_customers(p_source_id uuid, p_target_id uuid) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_shop       uuid;
  v_src        public.customers;
  v_tgt        public.customers;
  v_block      jsonb;
  v_moved      jsonb;
  v_tz         text;
  v_label      text;
  v_forms      jsonb;
  v_jobs       jsonb;
  v_quotes     jsonb;
  v_msgs       uuid[];
  v_phone      text;
  v_email      text;
begin
  if p_source_id is null or p_target_id is null then
    raise exception 'source and target customers are required' using errcode = '22023';
  end if;
  select c.shop_id into v_shop from public.customers c where c.id = p_source_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_admin(v_shop) then
    raise exception 'only owners and admins can merge customers' using errcode = '42501';
  end if;
  if p_source_id = p_target_id then
    raise exception 'a customer cannot be merged into itself' using errcode = '22023';
  end if;
  if not exists (select 1 from public.customers c where c.id = p_target_id and c.shop_id = v_shop) then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;
  -- both rows locked in id order (no deadlock between opposite merges); new
  -- records for either wait until the merge commits
  perform 1 from public.customers c
   where c.shop_id = v_shop and c.id in (p_source_id, p_target_id)
   order by c.id
   for update;
  select * into v_src from public.customers c where c.id = p_source_id;
  select * into v_tgt from public.customers c where c.id = p_target_id;

  select e into v_block
    from jsonb_array_elements(public.merge_customer_conflicts(v_src, v_tgt)) e
   where (e ->> 'blocking')::boolean
   limit 1;
  if v_block is not null then
    raise exception '%', v_block ->> 'message' using errcode = '22023';
  end if;

  -- what moves: the preview's counts, taken before anything moves
  v_moved := public.merge_customer_counts(v_shop, v_src.id);
  perform set_config('detailcrm.customer_merge', 'on', true);

  -- the duplicate's queued messages addressed to its current phone / email:
  -- re-addressed to the survivor's below (see the header)
  select coalesce(array_agg(m.id), '{}') into v_msgs
    from public.messages m
   where m.shop_id = v_shop and m.customer_id = v_src.id and m.direction = 'outbound' and m.status = 'queued'
     and public.comms_address_key(m.channel, m.to_address)
         = public.comms_address_key(m.channel, case m.channel when 'sms' then v_src.phone else v_src.email::text end);

  -- campaign recipients: one row per campaign and customer; the duplicate's
  -- still-queued message for a campaign the survivor also gets is cancelled
  update public.messages m
     set status = 'cancelled', error = 'a duplicate of the surviving customer''s message (customers merged)'
    from public.campaign_recipients cs
   where cs.shop_id = v_shop and cs.customer_id = v_src.id and m.shop_id = v_shop and m.id = cs.message_id
     and m.status = 'queued'
     and exists (select 1 from public.campaign_recipients ct
                  where ct.campaign_id = cs.campaign_id and ct.customer_id = v_tgt.id);
  delete from public.campaign_recipients cs
   where cs.shop_id = v_shop and cs.customer_id = v_src.id
     and exists (select 1 from public.campaign_recipients ct
                  where ct.campaign_id = cs.campaign_id and ct.customer_id = v_tgt.id);
  update public.campaign_recipients x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  -- messages and the automation log before the jobs (see the header)
  update public.messages x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  -- a reminder the survivor already has (same job, start and offset): the
  -- duplicate's log row is dropped and its still-queued messages cancelled
  with dropped as (
    delete from public.job_automation_log l
     where l.shop_id = v_shop and l.customer_id = v_src.id and l.key = 'appointment_reminder'
       and exists (select 1 from public.job_automation_log t
                    where t.job_id = l.job_id and t.key = 'appointment_reminder'
                      and t.scheduled_for is not distinct from l.scheduled_for
                      and t.reminder_offset_minutes is not distinct from l.reminder_offset_minutes
                      and t.customer_id = v_tgt.id)
    returning l.message_ids
  )
  update public.messages m
     set status = 'cancelled', error = 'a duplicate of the surviving customer''s message (customers merged)'
   where m.shop_id = v_shop and m.status = 'queued'
     and m.id in (select unnest(d.message_ids) from dropped d)
     and not exists (select 1 from public.job_automation_log t
                      where t.shop_id = v_shop and t.customer_id = v_tgt.id and m.id = any (t.message_ids));
  update public.job_automation_log x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  update public.vehicles x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  -- jobs: unsigned form links and appointment stamps survive the move
  select coalesce(jsonb_agg(jsonb_build_object('id', fs.id, 'token', fs.public_token)), '[]'::jsonb) into v_forms
    from public.form_submissions fs
    join public.jobs j on j.id = fs.job_id and j.shop_id = fs.shop_id
   where j.shop_id = v_shop and j.customer_id = v_src.id and fs.signed_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'set_at', j.appointment_set_at)), '[]'::jsonb) into v_jobs
    from public.jobs j where j.shop_id = v_shop and j.customer_id = v_src.id;
  update public.jobs x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.jobs j
     set appointment_set_at = (e ->> 'set_at')::timestamptz
    from jsonb_array_elements(v_jobs) e
   where j.shop_id = v_shop and j.id = (e ->> 'id')::uuid
     and j.appointment_set_at is distinct from (e ->> 'set_at')::timestamptz;
  update public.form_submissions fs
     set public_token = (e ->> 'token')::uuid
    from jsonb_array_elements(v_forms) e
   where fs.shop_id = v_shop and fs.id = (e ->> 'id')::uuid and fs.public_token <> (e ->> 'token')::uuid;
  delete from public.storage_purge_requests q
   where q.shop_id = v_shop and q.bucket_id = 'signatures' and q.is_prefix and q.reason = 'form_token_rotated'
     and q.path in (select v_shop::text || '/forms/' || (e ->> 'token') || '/' from jsonb_array_elements(v_forms) e);

  update public.job_series x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.blocked_times x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  -- quotes: a new customer normally gets a new link and a sent quote goes
  -- back to draft (quotes_integrity); a merge restores both
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'token', q.public_token, 'status', q.status,
                                               'sent_at', q.sent_at, 'viewed_at', q.viewed_at)), '[]'::jsonb)
    into v_quotes
    from public.quotes q where q.shop_id = v_shop and q.customer_id = v_src.id;
  update public.quotes x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.quotes q
     set public_token = (e ->> 'token')::uuid,
         status = case when e ->> 'status' in ('sent', 'viewed') then 'sent'::public.quote_status else q.status end,
         sent_at = case when e ->> 'status' in ('sent', 'viewed') then (e ->> 'sent_at')::timestamptz else q.sent_at end
    from jsonb_array_elements(v_quotes) e
   where q.shop_id = v_shop and q.id = (e ->> 'id')::uuid;
  update public.quotes q
     set status = 'viewed', viewed_at = (e ->> 'viewed_at')::timestamptz
    from jsonb_array_elements(v_quotes) e
   where q.shop_id = v_shop and q.id = (e ->> 'id')::uuid and e ->> 'status' = 'viewed';

  update public.invoices x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.memberships x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.payments x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  if exists (select 1 from public.customer_payment_methods pm
              where pm.shop_id = v_shop and pm.customer_id = v_tgt.id and pm.is_default) then
    update public.customer_payment_methods pm set is_default = false
     where pm.shop_id = v_shop and pm.customer_id = v_src.id and pm.is_default;
  end if;
  update public.customer_payment_methods x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  update public.form_submissions x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  update public.coupon_redemptions rs set once_per_customer = false
   where rs.shop_id = v_shop and rs.customer_id = v_src.id and rs.once_per_customer
     and exists (select 1 from public.coupon_redemptions rt
                  where rt.coupon_id = rs.coupon_id and rt.customer_id = v_tgt.id and rt.once_per_customer);
  update public.coupon_redemptions x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.coupons x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.coupons x set referrer_customer_id = v_tgt.id
   where x.shop_id = v_shop and x.referrer_customer_id = v_src.id;
  update public.gift_cards x set purchaser_customer_id = v_tgt.id
   where x.shop_id = v_shop and x.purchaser_customer_id = v_src.id;
  update public.gift_cards x set owner_customer_id = v_tgt.id
   where x.shop_id = v_shop and x.owner_customer_id = v_src.id;
  update public.referral_credits x set referrer_customer_id = v_tgt.id
   where x.shop_id = v_shop and x.referrer_customer_id = v_src.id;
  update public.referral_credits x set referee_customer_id = v_tgt.id
   where x.shop_id = v_shop and x.referee_customer_id = v_src.id;
  update public.notifications x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;
  update public.documents x set customer_id = v_tgt.id where x.shop_id = v_shop and x.customer_id = v_src.id;

  -- queued messages follow the survivor's address. Done before the fields
  -- are filled: customers_comms_readdress then finds them addressed to the
  -- survivor's final phone / email and leaves them queued.
  select * into v_tgt from public.customers c where c.id = v_tgt.id;
  v_phone := coalesce(v_tgt.phone, v_src.phone);
  v_email := coalesce(v_tgt.email::text, v_src.email::text);
  update public.messages m
     set to_address = case m.channel when 'sms' then v_phone else v_email end
   where m.shop_id = v_shop and m.id = any (v_msgs) and m.status = 'queued'
     and case m.channel when 'sms' then v_phone else v_email end is not null
     and public.comms_address_key(m.channel, m.to_address)
         is distinct from public.comms_address_key(m.channel, case m.channel when 'sms' then v_phone else v_email end)
     -- promotions only to an address with marketing consent (the survivor's
     -- own opt-in for it, see below; re-checked at claim time as usual)
     and (not (m.campaign_id is not null or public.comms_is_marketing_key(m.template_key))
          or case m.channel
               when 'sms' then v_tgt.sms_opt_in and v_tgt.sms_opted_out_at is null and v_src.sms_opted_out_at is null
               else v_tgt.email_opt_in and v_tgt.email_opted_out_at is null and v_src.email_opted_out_at is null
             end)
     -- an unsubscribe link may already have reached the old inbox when a
     -- send attempt was made: its credential stays with that inbox
     and (m.unsubscribe_token is null or m.attempts = 0);
  update public.comms_unsubscribe_tokens u
     set address = public.comms_address_key('email', m.to_address)
    from public.messages m
   where u.shop_id = v_shop and u.message_id = m.id and u.token = m.unsubscribe_token
     and m.shop_id = v_shop and m.id = any (v_msgs) and m.channel = 'email' and m.status = 'queued'
     and u.address is distinct from public.comms_address_key('email', m.to_address);

  -- customer fields
  select s.timezone into v_tz from public.shops s where s.id = v_shop;
  v_label := coalesce(public.report_customer_label(v_src.first_name, v_src.last_name, v_src.company), 'a duplicate');
  update public.customers c
     set stripe_customer_id = case when v_tgt.stripe_customer_id is null then null else c.stripe_customer_id end,
         referral_code = case when v_tgt.referral_code is null then null else c.referral_code end,
         portal_user_id = case when v_tgt.portal_user_id is null then null else c.portal_user_id end
   where c.id = v_src.id
     and ((v_tgt.stripe_customer_id is null and c.stripe_customer_id is not null)
          or (v_tgt.referral_code is null and c.referral_code is not null)
          or (v_tgt.portal_user_id is null and c.portal_user_id is not null));

  update public.customers t
     set first_name = coalesce(nullif(btrim(t.first_name), ''), v_src.first_name),
         last_name = coalesce(nullif(btrim(t.last_name), ''), v_src.last_name),
         company = coalesce(nullif(btrim(t.company), ''), v_src.company),
         email = coalesce(t.email, v_src.email),
         phone = coalesce(t.phone, v_src.phone),
         phone_unverified = case when t.phone is null and v_src.phone is not null
                                 then v_src.phone_unverified else t.phone_unverified end,
         address_line1 = case when t.address_line1 is null and t.city is null and t.postal_code is null
                              then v_src.address_line1 else t.address_line1 end,
         address_line2 = case when t.address_line1 is null and t.city is null and t.postal_code is null
                              then v_src.address_line2 else t.address_line2 end,
         city = case when t.address_line1 is null and t.city is null and t.postal_code is null
                     then v_src.city else t.city end,
         region = case when t.address_line1 is null and t.city is null and t.postal_code is null
                       then v_src.region else t.region end,
         postal_code = case when t.address_line1 is null and t.city is null and t.postal_code is null
                            then v_src.postal_code else t.postal_code end,
         country = coalesce(t.country, v_src.country),
         lat = case when t.lat is null then v_src.lat else t.lat end,
         lng = case when t.lat is null then v_src.lng else t.lng end,
         notes = left(concat_ws(E'\n\n', nullif(btrim(t.notes), ''),
                                format('Merged from %s on %s%s', v_label, (now() at time zone v_tz)::date,
                                       case when nullif(btrim(v_src.notes), '') is not null
                                            then ': ' || btrim(v_src.notes) else '' end)), 20000),
         tags = array(select u.tag
                        from (select x.tag, min(x.ord) as ord
                                from unnest(t.tags || v_src.tags) with ordinality as x(tag, ord)
                               group by x.tag) u
                       order by u.ord
                       limit 50),
         lifecycle = case when t.lifecycle = 'customer' or v_src.lifecycle = 'customer'
                          then 'customer'::public.customer_lifecycle else t.lifecycle end,
         sms_opted_out_at = least(t.sms_opted_out_at, v_src.sms_opted_out_at),
         email_opted_out_at = least(t.email_opted_out_at, v_src.email_opted_out_at),
         -- consent follows its address (see the header)
         sms_opt_in = least(t.sms_opted_out_at, v_src.sms_opted_out_at) is null
                      and case when t.phone is null and v_src.phone is not null then v_src.sms_opt_in
                               when t.phone is not null then t.sms_opt_in
                                 or (v_src.sms_opt_in
                                     and public.comms_address_key('sms', v_src.phone) = public.comms_address_key('sms', t.phone))
                               else t.sms_opt_in end,
         email_opt_in = least(t.email_opted_out_at, v_src.email_opted_out_at) is null
                        and case when t.email is null and v_src.email is not null then v_src.email_opt_in
                                 when t.email is not null then t.email_opt_in
                                   or (v_src.email_opt_in
                                       and public.comms_address_key('email', v_src.email::text)
                                           = public.comms_address_key('email', t.email::text))
                                 else t.email_opt_in end,
         portal_user_id = coalesce(t.portal_user_id, v_src.portal_user_id),
         stripe_customer_id = coalesce(t.stripe_customer_id, v_src.stripe_customer_id),
         referral_code = coalesce(t.referral_code, v_src.referral_code)
   where t.id = v_tgt.id;

  -- the duplicate: archived, pointing at the survivor (fires later ranges'
  -- merge-follow triggers)
  update public.customers c
     set archived_at = coalesce(c.archived_at, now()),
         merged_into_id = v_tgt.id
   where c.id = v_src.id;

  perform set_config('detailcrm.customer_merge', '', true);
  return jsonb_build_object('target_id', v_tgt.id, 'moved', v_moved);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Both run for the Twilio webhook only. comms_inbound_sms_customer returns a
-- whole customers row, so it must never be callable by anon/authenticated
-- (a new function gets EXECUTE for PUBLIC by default).
revoke execute on function
  public.comms_inbound_sms_customer(uuid, text),
  public.record_inbound_sms(text, text, text, text)
from public, anon, authenticated;
grant execute on function
  public.comms_inbound_sms_customer(uuid, text),
  public.record_inbound_sms(text, text, text, text)
to service_role;

revoke execute on function
  public.ops_customer_merge_scrub(),
  public.customers_ops_merge_guard(),
  public.customer_payment_methods_ops_stripe_customer()
from public, anon, authenticated;

revoke execute on function
  public.merge_customer_summary(public.customers),
  public.merge_customer_counts(uuid, uuid),
  public.merge_customer_conflicts(public.customers, public.customers)
from public, anon, authenticated;
grant execute on function
  public.merge_customer_summary(public.customers),
  public.merge_customer_counts(uuid, uuid),
  public.merge_customer_conflicts(public.customers, public.customers)
to service_role;

revoke execute on function
  public.merge_customers_preview(uuid, uuid),
  public.merge_customers(uuid, uuid)
from public, anon;
grant execute on function
  public.merge_customers_preview(uuid, uuid),
  public.merge_customers(uuid, uuid)
to authenticated, service_role;
