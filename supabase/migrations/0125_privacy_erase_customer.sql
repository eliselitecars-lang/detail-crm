-- ============================================================================
-- 0125 — Customer deletion requests: erase a customer, anonymising the record
-- in place when the shop's accounting still needs it.
--
-- Before: jobs, invoices, payments, memberships and job series reference
-- customers ON DELETE RESTRICT (0006, 0011, 0012, 0050), so a customer who
-- ever had a job could not be deleted at all, and no erase / anonymise path
-- existed. The RLS policy customers_delete (0004) let any manager DELETE a
-- customer straight through PostgREST, which skipped the saved-card rule
-- (customer_payment_methods cascades, 0011: the cards stayed attached to the
-- shop's Stripe customer; only the web checked first).
--
-- Now a deletion request goes through the payments edge action
-- `erase_customer` (owner / admin): it detaches the saved cards in Stripe,
-- expires the customer's open pay links, deletes the Stripe Customer on the
-- shop's connected account and then calls
--
--   erase_customer(p_shop_id, p_customer_id, p_actor, p_dry_run default false)
--     service_role only; p_actor = the signed-in user the edge verified,
--     who must be an active owner or admin of the shop (else 42501).
--     Returns {mode: 'deleted' | 'anonymised'}.
--     p_dry_run: changes nothing and reports what would happen and what
--     is in the way: {dry_run: true, mode, membership_active,
--     payments_in_progress, open_checkouts, saved_cards, erased} (the edge
--     answers its preview from this, before touching Stripe).
--   Refused (55000) while
--     HINT membership_active    a membership is active, past_due or incomplete
--                               (cancel it first: it still bills the card)
--     HINT payment_in_progress  a payment is pending (under an hour old) or
--                               processing (payment_in_flight)
--     HINT checkout_open        a card pay page of one of the customer's jobs
--                               or invoices can still be paid (job /
--                               invoice_checkout_holds)
--     HINT saved_cards          customer_payment_methods rows exist (the edge
--                               detaches them in Stripe first)
--   Unknown customer / another shop's: P0002.
--
-- Scope: the customer AND every duplicate merged into them (merged_into_id,
-- recursively; merge_customers, 0074, keeps the duplicate's row archived
-- with its name and contact details — the same person's).
--
-- Mode per record:
--   * 'deleted' — nothing of accounting references it (no jobs, invoices,
--     payments or memberships): its job series (which then have no jobs),
--     form submissions and staff notifications about it are deleted, then
--     the row; the existing cascades remove vehicles, quotes, messages,
--     documents, lead submissions, campaign recipients, the automation log
--     and consent events, and queue the customer's file folder for the
--     storage purge (customers_zz_ops_queue_storage_purge).
--   * 'anonymised' — otherwise, in place:
--       customers   first_name 'Deleted', last_name 'customer'; company,
--                   email, phone, address, lat/lng, notes, referral_code,
--                   stripe_customer_id and portal_user_id null; tags '{}',
--                   custom_data '{}', sms_opt_in / email_opt_in false,
--                   phone_unverified false, archived_at (kept if set) and
--                   erased_at now(). Opt-out stamps are cleared with the
--                   address (the address-keyed suppressions stay, below).
--       vehicles    vin, license_plate and notes null (year / make / model
--                   / trim / color kept for the job history)
--       deleted     messages, campaign recipient rows, lead submissions,
--                   documents (+ the customers/<id>/ folder queued for the
--                   storage purge), form submissions of the customer or of
--                   their jobs (signature images queued by 0025's trigger),
--                   staff notifications about the customer or their jobs,
--                   quotes and invoices
--       cleared     inspection signatures of their jobs (image queued for
--                   the purge; signer name and time cleared together, as
--                   inspections_signature_complete requires), job report
--                   links revoked, free text on the records kept for
--                   accounting: jobs notes / internal_notes / cancel_reason
--                   / custom_data / service address, job series notes /
--                   address (and the series ended: no new visits), quotes
--                   notes / internal_notes / approved_by_name /
--                   declined_reason, invoices notes / internal_notes,
--                   payments note, gift cards the customer owns (recipient
--                   name / email) or bought (message)
--       kept        every money row — jobs, their lines, quotes, invoices,
--                   invoice lines, payments (refunds are payments rows),
--                   memberships, coupon redemptions, referral credits, gift
--                   cards — with amounts, numbers and dates, so revenue,
--                   tax and report_* totals do not change.
--   Always kept: comms_suppressions and comms_unsubscribe_tokens. They are
--   keyed by address and must outlive the person: a record re-created later
--   with the same address is still opted out and cannot be marketed to.
--
-- Audit: customer_erasures (shop_id, customer_id, mode, erased_by,
-- erased_at) — no personal data; owners and admins read it.
--
-- An erased record stays erased (customers_02_erased_guard): its fields,
-- links (portal account, Stripe customer), archive stamp and merge pointer
-- cannot change afterwards — 55000 HINT customer_erased — and nothing new
-- attaches to it: jobs, quotes, vehicles, memberships and job series refuse
-- an erased customer_id on insert or re-point (customers_erased_link_guard).
-- erased_at is written only by erase_customer (42501 otherwise).
--
-- RLS: customers_delete is dropped (as 0117 did for shops), so a client can
-- no longer delete a customer directly (RLS: 0 rows); service_role and the
-- RPC above remain the only ways. (The table-level DELETE grant stays for
-- now so the web's pre-0125 delete call reports "nothing deleted" instead of
-- failing the contract check; it grants nothing without a policy.)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Columns / audit table
-- ---------------------------------------------------------------------------
alter table public.customers add column erased_at timestamptz;
comment on column public.customers.erased_at is
  'When the customer was erased at their request (erase_customer, 0125): the record was anonymised in place because accounting rows still reference it. Server-set; an erased record cannot be edited or linked again.';

create table public.customer_erasures (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  -- no foreign key: a 'deleted' customer's row is gone
  customer_id  uuid not null,
  mode         text not null check (mode in ('deleted', 'anonymised')),
  erased_by    uuid references auth.users (id) on delete set null,
  erased_at    timestamptz not null default now(),
  constraint customer_erasures_shop_id_id_key unique (shop_id, id)
);
create index customer_erasures_shop_idx on public.customer_erasures (shop_id, erased_at desc);

comment on table public.customer_erasures is
  'Audit of customer erasures (0125): which customer id was deleted or anonymised, by whom and when. No personal data. Owners and admins read; written only by erase_customer.';

alter table public.customer_erasures enable row level security;
create policy customer_erasures_select on public.customer_erasures for select to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.customer_erasures from anon;
revoke insert, update, delete, truncate, references, trigger on public.customer_erasures from authenticated;

-- the storage purge records why (a new reason)
alter table public.storage_purge_requests
  drop constraint storage_purge_requests_reason_check,
  add constraint storage_purge_requests_reason_check
    check (reason in ('shop_deleted', 'job_deleted', 'inspection_deleted', 'form_deleted', 'form_token_rotated',
                      'document_deleted', 'media_deleted', 'customer_deleted', 'report_revoked', 'customer_erased'));

-- ---------------------------------------------------------------------------
-- RLS: no client DELETE on customers
-- ---------------------------------------------------------------------------
drop policy customers_delete on public.customers;

comment on table public.customers is
  'Shop customers (SPEC §4.2). Deleted or anonymised only by erase_customer (0125, through the payments edge erase_customer): clients have no DELETE policy.';

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
-- The ids erase_customer is erasing in this transaction (text array).
create function public.customer_erase_in_progress(p_id uuid) returns boolean
language sql stable
set search_path = ''
as $$
  select p_id is not null
     and p_id::text = any (string_to_array(coalesce(current_setting('detailcrm.customer_erase', true), ''), ','))
$$;

comment on function public.customer_erase_in_progress(uuid) is
  'Internal (0125): true while erase_customer is erasing this customer in the current transaction.';
revoke execute on function public.customer_erase_in_progress(uuid) from public, anon;
grant execute on function public.customer_erase_in_progress(uuid) to authenticated, service_role;

create function public.customers_erased_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
  c_free constant text[] := array['updated_at', 'search_text', 'sort_name', 'merged_into_id'];
begin
  if tg_op = 'INSERT' then
    if new.erased_at is not null then
      raise exception 'customers are erased only through erase_customer' using errcode = '42501';
    end if;
    return new;
  end if;
  if public.customer_erase_in_progress(old.id) and not public.is_client_context() then
    return new;
  end if;
  if old.erased_at is null then
    if new.erased_at is not null then
      raise exception 'customers are erased only through erase_customer' using errcode = '42501';
    end if;
    return new;
  end if;
  -- an erased record: only the merge pointer may be cleared (its survivor
  -- was deleted: ON DELETE SET NULL), and updated_at follows any write
  if (to_jsonb(new) - c_free) is distinct from (to_jsonb(old) - c_free)
     or (new.merged_into_id is distinct from old.merged_into_id and new.merged_into_id is not null) then
    raise exception 'this customer was erased at their request; the record can''t be edited or linked again'
      using errcode = '55000', hint = 'customer_erased';
  end if;
  return new;
end
$$;

comment on function public.customers_erased_guard() is
  'Internal (0125): erased_at is set only by erase_customer (42501); an erased customer cannot be edited, re-linked (portal account, Stripe customer), un-archived or merged (55000 HINT customer_erased).';
revoke execute on function public.customers_erased_guard() from public, anon, authenticated;

create trigger customers_02_erased_guard before insert or update on public.customers
  for each row execute function public.customers_erased_guard();

-- Nothing new attaches to an erased customer.
create function public.customers_erased_link_guard() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.customer_id is not null
     and (tg_op = 'INSERT' or new.customer_id is distinct from old.customer_id)
     and exists (select 1 from public.customers c
                  where c.id = new.customer_id and c.shop_id = new.shop_id and c.erased_at is not null) then
    raise exception 'this customer was erased at their request; nothing new can be added to the record'
      using errcode = '55000', hint = 'customer_erased';
  end if;
  return new;
end
$$;

comment on function public.customers_erased_link_guard() is
  'Internal (0125): jobs, quotes, vehicles, memberships and job series cannot be created for, or moved to, an erased customer (55000 HINT customer_erased).';
revoke execute on function public.customers_erased_link_guard() from public, anon, authenticated;

create trigger jobs_02_erased_customer before insert or update of customer_id on public.jobs
  for each row execute function public.customers_erased_link_guard();
create trigger quotes_02_erased_customer before insert or update of customer_id on public.quotes
  for each row execute function public.customers_erased_link_guard();
create trigger vehicles_02_erased_customer before insert or update of customer_id on public.vehicles
  for each row execute function public.customers_erased_link_guard();
create trigger memberships_02_erased_customer before insert or update of customer_id on public.memberships
  for each row execute function public.customers_erased_link_guard();
create trigger job_series_02_erased_customer before insert or update of customer_id on public.job_series
  for each row execute function public.customers_erased_link_guard();

-- ---------------------------------------------------------------------------
-- customer_erase_apply — INTERNAL: erases ONE customer row (the caller has
-- locked it, checked the refusals and set detailcrm.customer_erase).
-- Returns the mode applied.
-- ---------------------------------------------------------------------------
create function public.customer_erase_apply(p_shop_id uuid, p_customer_id uuid) returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_jobs    uuid[];
  v_quotes  uuid[];
  v_invs    uuid[];
  v_path    text;
begin
  -- gift cards keep their money; the names on them go
  update public.gift_cards g set recipient_name = null, recipient_email = null
   where g.shop_id = p_shop_id and g.owner_customer_id = p_customer_id
     and (g.recipient_name is not null or g.recipient_email is not null);
  update public.gift_cards g set message = null
   where g.shop_id = p_shop_id and g.purchaser_customer_id = p_customer_id and g.message is not null;

  if not exists (select 1 from public.jobs j where j.shop_id = p_shop_id and j.customer_id = p_customer_id)
     and not exists (select 1 from public.invoices i where i.shop_id = p_shop_id and i.customer_id = p_customer_id)
     and not exists (select 1 from public.payments p where p.shop_id = p_shop_id and p.customer_id = p_customer_id)
     and not exists (select 1 from public.memberships m where m.shop_id = p_shop_id and m.customer_id = p_customer_id)
  then
    -- nothing of accounting: the record goes (cascades do the rest)
    delete from public.job_series s where s.shop_id = p_shop_id and s.customer_id = p_customer_id;
    delete from public.form_submissions f where f.shop_id = p_shop_id and f.customer_id = p_customer_id;
    delete from public.notifications n
     where n.shop_id = p_shop_id
       and (n.customer_id = p_customer_id
            or n.quote_id in (select q.id from public.quotes q where q.shop_id = p_shop_id and q.customer_id = p_customer_id));
    delete from public.customers c where c.id = p_customer_id and c.shop_id = p_shop_id;
    return 'deleted';
  end if;

  select coalesce(array_agg(j.id), '{}') into v_jobs
    from public.jobs j where j.shop_id = p_shop_id and j.customer_id = p_customer_id;
  select coalesce(array_agg(q.id), '{}') into v_quotes
    from public.quotes q where q.shop_id = p_shop_id and q.customer_id = p_customer_id;
  select coalesce(array_agg(i.id), '{}') into v_invs
    from public.invoices i where i.shop_id = p_shop_id and i.customer_id = p_customer_id;

  -- the person's own content
  delete from public.campaign_recipients r where r.shop_id = p_shop_id and r.customer_id = p_customer_id;
  delete from public.messages m where m.shop_id = p_shop_id and m.customer_id = p_customer_id;
  delete from public.lead_submissions l where l.shop_id = p_shop_id and l.customer_id = p_customer_id;
  delete from public.documents d                              -- files queued by documents_queue_storage_purge
   where d.shop_id = p_shop_id and (d.customer_id = p_customer_id or d.job_id = any (v_jobs));
  perform public.queue_storage_purge(p_shop_id, 'documents',
                                     p_shop_id::text || '/customers/' || p_customer_id::text || '/', true,
                                     'customer_erased');
  delete from public.form_submissions f                       -- signatures queued by 0025's trigger
   where f.shop_id = p_shop_id and (f.customer_id = p_customer_id or f.job_id = any (v_jobs));
  delete from public.notifications n
   where n.shop_id = p_shop_id
     and (n.customer_id = p_customer_id or n.job_id = any (v_jobs)
          or n.quote_id = any (v_quotes) or n.invoice_id = any (v_invs));

  -- signatures on inspections of their jobs (name, image and time go
  -- together: inspections_signature_complete)
  for v_path in
    select i.customer_signature_path from public.inspections i
     where i.shop_id = p_shop_id and i.job_id = any (v_jobs) and i.customer_signature_path is not null
  loop
    perform public.queue_storage_purge(p_shop_id, 'signatures', v_path, false, 'customer_erased');
  end loop;
  update public.inspections i
     set customer_signature_path = null, signed_by_name = null, signed_at = null
   where i.shop_id = p_shop_id and i.job_id = any (v_jobs) and i.customer_signature_path is not null;
  -- report links stop working
  update public.job_reports r set revoked_at = now()
   where r.shop_id = p_shop_id and r.job_id = any (v_jobs) and r.revoked_at is null;

  -- free text on the records accounting keeps
  update public.jobs j
     set notes = null, internal_notes = null, cancel_reason = null, custom_data = '{}'::jsonb,
         service_address_line1 = null, service_address_line2 = null, service_city = null,
         service_region = null, service_postal_code = null, service_lat = null, service_lng = null
   where j.shop_id = p_shop_id and j.customer_id = p_customer_id;
  update public.job_series s
     set notes = null, internal_notes = null,
         service_address_line1 = null, service_address_line2 = null, service_city = null,
         service_region = null, service_postal_code = null, service_lat = null, service_lng = null,
         active = false, ended_at = coalesce(s.ended_at, now())
   where s.shop_id = p_shop_id and s.customer_id = p_customer_id;
  update public.quotes q
     set notes = null, internal_notes = null, approved_by_name = null, declined_reason = null
   where q.shop_id = p_shop_id and q.customer_id = p_customer_id;
  update public.invoices i set notes = null, internal_notes = null
   where i.shop_id = p_shop_id and i.customer_id = p_customer_id
     and (i.notes is not null or i.internal_notes is not null);
  update public.payments p set note = null
   where p.shop_id = p_shop_id and p.customer_id = p_customer_id and p.note is not null;
  update public.vehicles v set vin = null, license_plate = null, notes = null
   where v.shop_id = p_shop_id and v.customer_id = p_customer_id;

  update public.customers c
     set first_name = 'Deleted', last_name = 'customer', company = null,
         email = null, phone = null,
         address_line1 = null, address_line2 = null, city = null, region = null, postal_code = null,
         country = null, lat = null, lng = null,
         notes = null, tags = '{}', custom_data = '{}'::jsonb, referral_code = null,
         sms_opt_in = false, email_opt_in = false, sms_opted_out_at = null, email_opted_out_at = null,
         phone_unverified = false,
         stripe_customer_id = null, portal_user_id = null,
         archived_at = coalesce(c.archived_at, now()), erased_at = now()
   where c.id = p_customer_id and c.shop_id = p_shop_id;
  return 'anonymised';
end
$$;

comment on function public.customer_erase_apply(uuid, uuid) is
  'Internal (0125): deletes or anonymises one customer row for erase_customer (which locks, checks and audits). Returns ''deleted'' or ''anonymised''.';
revoke execute on function public.customer_erase_apply(uuid, uuid) from public, anon, authenticated;
grant execute on function public.customer_erase_apply(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- erase_customer — the RPC (service_role; the payments edge)
-- ---------------------------------------------------------------------------
create function public.erase_customer(
  p_shop_id      uuid,
  p_customer_id  uuid,
  p_actor        uuid,
  p_dry_run      boolean default false
) returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cust        public.customers;
  v_ids         uuid[];
  v_id          uuid;
  v_mode        text;
  v_main_mode   text;
  v_membership  boolean;
  v_in_flight   integer;
  v_holds       integer;
  v_cards       integer;
  v_records     boolean;
begin
  if p_shop_id is null or p_customer_id is null then
    raise exception 'a shop and a customer are required' using errcode = '22023';
  end if;
  if p_actor is null or not exists (
       select 1 from public.shop_members m
        where m.shop_id = p_shop_id and m.user_id = p_actor and m.active and m.role in ('owner', 'admin')) then
    raise exception 'only owners and admins can delete a customer' using errcode = '42501';
  end if;
  select * into v_cust from public.customers c
   where c.id = p_customer_id and c.shop_id = p_shop_id
  for update;
  if not found then
    raise exception 'customer not found' using errcode = 'P0002';
  end if;

  -- the customer and every duplicate merged into them (the same person)
  with recursive d (id) as (
    select p_customer_id
    union
    select c.id from public.customers c join d on c.merged_into_id = d.id
     where c.shop_id = p_shop_id
  )
  select array_agg(d.id) into v_ids from d;
  perform 1 from public.customers c where c.shop_id = p_shop_id and c.id = any (v_ids) order by c.id for update;

  select exists (select 1 from public.memberships m
                  where m.shop_id = p_shop_id and m.customer_id = any (v_ids)
                    and m.status in ('active', 'past_due', 'incomplete'))
    into v_membership;
  select count(*) into v_in_flight from public.payments p
   where p.shop_id = p_shop_id and p.customer_id = any (v_ids)
     and public.payment_in_flight(p.status, p.created_at);
  select (select count(*) from public.job_checkout_holds h
            join public.jobs j on j.id = h.job_id and j.shop_id = h.shop_id
           where h.shop_id = p_shop_id and j.customer_id = any (v_ids) and h.expires_at > now())
       + (select count(*) from public.invoice_checkout_holds h
            join public.invoices i on i.id = h.invoice_id and i.shop_id = h.shop_id
           where h.shop_id = p_shop_id and i.customer_id = any (v_ids) and h.expires_at > now())
    into v_holds;
  select count(*) into v_cards from public.customer_payment_methods pm
   where pm.shop_id = p_shop_id and pm.customer_id = any (v_ids);
  v_records := exists (select 1 from public.jobs j where j.shop_id = p_shop_id and j.customer_id = p_customer_id)
            or exists (select 1 from public.invoices i where i.shop_id = p_shop_id and i.customer_id = p_customer_id)
            or exists (select 1 from public.payments p where p.shop_id = p_shop_id and p.customer_id = p_customer_id)
            or exists (select 1 from public.memberships m where m.shop_id = p_shop_id and m.customer_id = p_customer_id);
  v_main_mode := case when v_records or v_cust.erased_at is not null then 'anonymised' else 'deleted' end;

  if p_dry_run then
    return jsonb_build_object(
      'dry_run', true,
      'mode', v_main_mode,
      'erased', v_cust.erased_at is not null,
      'membership_active', v_membership,
      'payments_in_progress', v_in_flight,
      'open_checkouts', v_holds,
      'saved_cards', v_cards);
  end if;

  if v_membership then
    raise exception 'this customer has a membership that is still active; cancel it first'
      using errcode = '55000', hint = 'membership_active';
  end if;
  if v_in_flight > 0 then
    raise exception 'a payment from this customer is still in progress; try again once it has finished'
      using errcode = '55000', hint = 'payment_in_progress';
  end if;
  if v_holds > 0 then
    raise exception 'a card payment page for this customer is still open; cancel the open payments first'
      using errcode = '55000', hint = 'checkout_open';
  end if;
  if v_cards > 0 then
    raise exception 'remove this customer''s saved cards first' using errcode = '55000', hint = 'saved_cards';
  end if;

  if v_cust.erased_at is not null
     and not exists (select 1 from public.customers c
                      where c.shop_id = p_shop_id and c.id = any (v_ids) and c.erased_at is null) then
    return jsonb_build_object('mode', 'anonymised');     -- already erased: nothing left to do
  end if;

  perform set_config('detailcrm.customer_erase', array_to_string(v_ids, ','), true);
  -- duplicates first (deleting the survivor would only unlink them)
  foreach v_id in array (select array_agg(x order by x = p_customer_id, x) from unnest(v_ids) x) loop
    continue when exists (select 1 from public.customers c where c.id = v_id and c.erased_at is not null);
    v_mode := public.customer_erase_apply(p_shop_id, v_id);
    insert into public.customer_erasures (shop_id, customer_id, mode, erased_by)
    values (p_shop_id, v_id, v_mode, p_actor);
    if v_id = p_customer_id then
      v_main_mode := v_mode;
    end if;
  end loop;
  perform set_config('detailcrm.customer_erase', '', true);
  return jsonb_build_object('mode', v_main_mode);
end
$$;

comment on function public.erase_customer(uuid, uuid, uuid, boolean) is
  'Service role (payments edge erase_customer, 0125): erases a customer at their request — with every duplicate merged into them — deleting the record when nothing of accounting references it, else anonymising it in place (money rows kept). p_actor must be an active owner/admin (42501). 55000 HINT membership_active / payment_in_progress / checkout_open / saved_cards. p_dry_run reports {mode, erased, membership_active, payments_in_progress, open_checkouts, saved_cards} without changing anything. Returns {mode}.';
revoke execute on function public.erase_customer(uuid, uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.erase_customer(uuid, uuid, uuid, boolean) to service_role;
