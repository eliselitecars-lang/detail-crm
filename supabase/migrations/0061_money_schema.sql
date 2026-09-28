-- ============================================================================
-- 0061 — Money v2 schema (range 0060-0069). Every new table, column, CHECK
-- replacement, index, RLS policy, grant, seed trigger and backfill of the
-- range lives here; the behaviour files after it (0062-0069) add functions
-- and triggers and may use any of these columns.
--
-- Tenancy rules as everywhere: shop_id + RLS on every table, UNIQUE
-- (shop_id, id) on tables with an id, composite (shop_id, x) foreign keys
-- between tenant tables, an index behind every foreign key of a foundation
-- table, no anon access, no TRUNCATE / TRIGGER / REFERENCES for API roles.
-- Settings-style tables keyed by shop_id have no id column.
--
-- Customer merge (P-20, ops 0074): every customer_id column added here is
-- moved by merge_customers (coupons.customer_id / referrer_customer_id,
-- coupon_redemptions, gift_cards purchaser / owner, referral_credits).
-- ============================================================================

-- ===========================================================================
-- P-6 Stripe Terminal: one Terminal location per shop (created by the
-- payments edge function when the shop's address is known; address_hash
-- detects address changes). Terminal payments are ordinary card_present
-- payments rows (upsert_stripe_payment), so payments need no change.
-- ===========================================================================
create table public.shop_terminal_locations (
  shop_id             uuid primary key references public.shops (id) on delete cascade,
  stripe_location_id  text not null check (stripe_location_id ~ '^tml_[A-Za-z0-9]+$'),
  address_hash        text not null check (address_hash ~ '^[0-9a-f]{64}$'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.shop_terminal_locations is
  'Stripe Terminal location of the shop on its connected account (P-6). address_hash = sha256 hex of the address it was created with. Written by service_role only; owners/admins read it.';

create trigger shop_terminal_locations_05_prevent_shop_change before update on public.shop_terminal_locations
  for each row execute function public.prevent_shop_change();
create trigger shop_terminal_locations_90_set_updated_at before update on public.shop_terminal_locations
  for each row execute function public.set_updated_at();

alter table public.shop_terminal_locations enable row level security;
create policy shop_terminal_locations_select on public.shop_terminal_locations for select to authenticated
  using (public.is_shop_admin(shop_id));

-- ===========================================================================
-- P-7 Multi-job invoices. invoice_jobs lists the jobs an invoice bills: one
-- row for a single-job invoice (invoices.job_id, maintained by trigger),
-- 2..100 rows for a grouped invoice (job_id null, create_invoice_from_jobs).
-- A job has at most one live (non-voided) invoice, single or grouped.
-- ===========================================================================
create table public.invoice_jobs (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops (id) on delete cascade,
  invoice_id  uuid not null,
  job_id      uuid not null,
  voided      boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint invoice_jobs_shop_id_id_key unique (shop_id, id),
  constraint invoice_jobs_invoice_job_key unique (invoice_id, job_id),
  constraint invoice_jobs_invoice_fk foreign key (shop_id, invoice_id)
    references public.invoices (shop_id, id) on delete cascade,
  -- a billed job is a financial record (like invoices.job_id)
  constraint invoice_jobs_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete restrict
);
create unique index invoice_jobs_one_live_invoice on public.invoice_jobs (job_id) where not voided;
create index invoice_jobs_shop_invoice_idx on public.invoice_jobs (shop_id, invoice_id);
create index invoice_jobs_shop_job_idx on public.invoice_jobs (shop_id, job_id);

comment on table public.invoice_jobs is
  'Jobs billed by an invoice (P-7): one row for a single-job invoice, 2..100 for a grouped invoice (invoices.job_id null). voided = the invoice is void. Server-maintained.';

create trigger invoice_jobs_05_prevent_shop_change before update on public.invoice_jobs
  for each row execute function public.prevent_shop_change();

alter table public.invoice_jobs enable row level security;
create policy invoice_jobs_select on public.invoice_jobs for select to authenticated
  using (public.is_shop_manager(shop_id) or public.can_collect_for_job(shop_id, job_id));

-- backfill: every existing job invoice
insert into public.invoice_jobs (shop_id, invoice_id, job_id, voided, created_at)
select i.shop_id, i.id, i.job_id, i.status = 'void', i.created_at
  from public.invoices i
 where i.job_id is not null;

-- per-line job (grouped invoices list each job's lines)
alter table public.invoice_line_items
  add column job_id uuid,
  add constraint invoice_line_items_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id);
create index invoice_line_items_shop_job_idx on public.invoice_line_items (shop_id, job_id);

-- backfill: lines of single-job invoices bill that job. The line guard
-- (no line changes once money is on the invoice) and the invoice touch are
-- bypassed for this one-time data fill only.
alter table public.invoice_line_items disable trigger user;
update public.invoice_line_items li
   set job_id = i.job_id
  from public.invoices i
 where i.id = li.invoice_id and i.shop_id = li.shop_id and i.job_id is not null;
alter table public.invoice_line_items enable trigger user;

comment on column public.invoice_line_items.job_id is
  'The job this line bills (one of the invoice''s jobs, invoice_line_items_validate); copied by create_invoice_from_job(s).';

-- ===========================================================================
-- P-12 Commissions and sold-by.
-- ===========================================================================
alter table public.services
  add column commission_kind   public.commission_kind not null default 'none',
  add column commission_value  bigint not null default 0,
  add constraint services_commission_value check (
    (commission_kind = 'none' and commission_value = 0)
    or (commission_kind = 'percent' and commission_value between 0 and 10000)
    or (commission_kind = 'flat' and commission_value >= 0));

comment on column public.services.commission_kind is
  'Service commission paid to the job''s assignees instead of their member commission (report_team): percent of the line net, or a flat amount per unit. Owners/admins set it.';
comment on column public.services.commission_value is
  'percent: basis points of the line net (0..10000); flat: cents per unit; none: 0.';

alter table public.member_compensation
  add column sales_commission_bps integer not null default 0 check (sales_commission_bps between 0 and 10000);

comment on column public.member_compensation.sales_commission_bps is
  'Commission on the pre-tax revenue of completed jobs this member sold (jobs.sold_by_member_id).';

alter table public.jobs
  add column sold_by_member_id uuid,
  add constraint jobs_sold_by_fk foreign key (shop_id, sold_by_member_id)
    references public.shop_members (shop_id, id) on delete set null (sold_by_member_id);
create index jobs_shop_sold_by_idx on public.jobs (shop_id, sold_by_member_id);
grant select (sold_by_member_id) on public.jobs to authenticated;

comment on column public.jobs.sold_by_member_id is
  'Team member credited with the sale (sales commission). Defaults to the creating member (jobs_60_sold_by_default; online bookings: none; quote conversions: the quote''s creator; recurring-series occurrences: the series creator). Managers+ may change it.';

-- ===========================================================================
-- P-13a Coupon restrictions.
-- ===========================================================================
alter table public.coupons
  add column service_ids           uuid[] check (service_ids is null
                                                 or (array_position(service_ids, null) is null
                                                     and cardinality(service_ids) between 1 and 100)),
  add column min_subtotal_cents    bigint check (min_subtotal_cents is null or min_subtotal_cents >= 0),
  add column once_per_customer     boolean not null default false,
  add column customer_id           uuid,
  add column new_customers_only    boolean not null default false,
  add column referrer_customer_id  uuid,
  add constraint coupons_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  add constraint coupons_referrer_fk foreign key (shop_id, referrer_customer_id)
    references public.customers (shop_id, id) on delete set null (referrer_customer_id);
create index coupons_shop_customer_idx on public.coupons (shop_id, customer_id);
create index coupons_shop_referrer_idx on public.coupons (shop_id, referrer_customer_id);

comment on column public.coupons.service_ids is
  'Services the coupon discounts (null = every line). Lines of other services are not discount-eligible; a job needs at least one eligible line.';
comment on column public.coupons.min_subtotal_cents is 'Minimum eligible subtotal (line totals of eligible lines) for the coupon to apply.';
comment on column public.coupons.once_per_customer is 'Each customer may use the coupon on one job (coupon_redemptions).';
comment on column public.coupons.customer_id is 'Only this customer may use the coupon (null = anyone).';
comment on column public.coupons.new_customers_only is 'Only customers without a completed job or a received payment may use it.';
comment on column public.coupons.referrer_customer_id is
  'Referral coupon of this customer (referral program, P-29). Server-set only.';

alter table public.job_line_items
  add column discount_eligible boolean not null default true;
alter table public.quote_line_items
  add column discount_eligible boolean not null default true;
alter table public.invoice_line_items
  add column discount_eligible boolean not null default true;

comment on column public.job_line_items.discount_eligible is
  'Whether the document discount applies to this line. Server-maintained from the job''s coupon (job_line_items_60_money).';
comment on column public.quote_line_items.discount_eligible is 'Whether the quote''s document discount applies to this line (default true).';
comment on column public.invoice_line_items.discount_eligible is
  'Whether the invoice''s document discount applies to this line (copied from the job line; default true).';

create table public.coupon_redemptions (
  id                 uuid primary key default gen_random_uuid(),
  shop_id            uuid not null references public.shops (id) on delete cascade,
  coupon_id          uuid not null,
  customer_id        uuid not null,
  job_id             uuid not null,
  once_per_customer  boolean not null,
  created_at         timestamptz not null default now(),
  constraint coupon_redemptions_shop_id_id_key unique (shop_id, id),
  constraint coupon_redemptions_job_key unique (job_id),
  constraint coupon_redemptions_coupon_fk foreign key (shop_id, coupon_id)
    references public.coupons (shop_id, id) on delete cascade,
  constraint coupon_redemptions_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint coupon_redemptions_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade
);
create unique index coupon_redemptions_once_key on public.coupon_redemptions (coupon_id, customer_id)
  where once_per_customer;
create index coupon_redemptions_shop_coupon_idx on public.coupon_redemptions (shop_id, coupon_id);
create index coupon_redemptions_shop_customer_idx on public.coupon_redemptions (shop_id, customer_id);
create index coupon_redemptions_shop_job_idx on public.coupon_redemptions (shop_id, job_id);

comment on table public.coupon_redemptions is
  'One row per job that carries a coupon (jobs_zz_money_coupon_redemption, every context). once_per_customer is copied from the coupon when redeemed. Server-maintained; managers+ read.';

create trigger coupon_redemptions_05_prevent_shop_change before update on public.coupon_redemptions
  for each row execute function public.prevent_shop_change();

alter table public.coupon_redemptions enable row level security;
create policy coupon_redemptions_select on public.coupon_redemptions for select to authenticated
  using (public.is_shop_manager(shop_id));

-- backfill: every job that already carries a coupon
insert into public.coupon_redemptions (shop_id, coupon_id, customer_id, job_id, once_per_customer, created_at)
select j.shop_id, j.coupon_id, j.customer_id, j.id, false, j.created_at
  from public.jobs j
 where j.coupon_id is not null;

-- ===========================================================================
-- P-13b Gift cards and store credit. A gift card SALE is not a payment
-- (liability, not revenue): orders + transactions. A REDEMPTION is a
-- payments row (method gift_card) written by the redeem RPCs (0066).
-- Codes are never stored: code_hash = sha256 hex of shop_id || ':' ||
-- normalised code; code_last4 identifies the card to people.
-- ===========================================================================

-- offers: [{value_cents, price_cents}] 0..8 items, 500 <= value <= 100000,
-- 0 < price <= value, no other keys. Never raises.
create function public.gift_card_offers_valid(p jsonb) returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  e jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 8 then
    return false;
  end if;
  for e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(e) <> 'object'
       or exists (select 1 from jsonb_object_keys(e) k where k not in ('value_cents', 'price_cents'))
       or jsonb_typeof(e -> 'value_cents') is distinct from 'number'
       or jsonb_typeof(e -> 'price_cents') is distinct from 'number'
       or (e ->> 'value_cents') !~ '^[0-9]{1,9}$'
       or (e ->> 'price_cents') !~ '^[0-9]{1,9}$' then
      return false;
    end if;
    if (e ->> 'value_cents')::bigint not between 500 and 100000
       or (e ->> 'price_cents')::bigint <= 0
       or (e ->> 'price_cents')::bigint > (e ->> 'value_cents')::bigint then
      return false;
    end if;
  end loop;
  return true;
end
$$;

comment on function public.gift_card_offers_valid(jsonb) is
  'gift_card_settings.offers: [{value_cents 500..100000, price_cents 1..value_cents}], at most 8.';

create table public.gift_card_settings (
  shop_id              uuid primary key references public.shops (id) on delete cascade,
  online_enabled       boolean not null default false,
  offers               jsonb not null default '[]'::jsonb check (public.gift_card_offers_valid(offers)),
  allow_custom_amount  boolean not null default false,
  min_custom_cents     bigint not null default 1000,
  max_custom_cents     bigint not null default 50000,
  -- US CARD Act: a gift card may not expire within 5 years of issue (state
  -- escheat rules also apply; review them before setting an expiry)
  expires_months       smallint check (expires_months is null or expires_months between 60 and 600),
  terms                text check (terms is null or char_length(terms) <= 5000),
  updated_at           timestamptz not null default now(),
  constraint gift_card_settings_custom_range check (
    min_custom_cents >= 500 and min_custom_cents <= max_custom_cents and max_custom_cents <= 100000)
);

comment on table public.gift_card_settings is
  'Online gift card sales (P-13b): offers the shop sells (nothing seeded), optional custom amounts, expiry (>= 60 months or none) and terms. Managers read, owners/admins edit.';

create trigger gift_card_settings_05_prevent_shop_change before update on public.gift_card_settings
  for each row execute function public.prevent_shop_change();
create trigger gift_card_settings_90_set_updated_at before update on public.gift_card_settings
  for each row execute function public.set_updated_at();

alter table public.gift_card_settings enable row level security;
create policy gift_card_settings_select on public.gift_card_settings for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy gift_card_settings_update on public.gift_card_settings for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));

create table public.gift_cards (
  id                        uuid primary key default gen_random_uuid(),
  shop_id                   uuid not null references public.shops (id) on delete cascade,
  kind                      text not null default 'gift' check (kind in ('gift', 'credit')),
  code_hash                 text not null check (code_hash ~ '^[0-9a-f]{64}$'),
  code_last4                text not null check (code_last4 ~ '^[A-Z0-9]{4}$'),
  initial_cents             bigint not null check (initial_cents > 0),
  balance_cents             bigint not null check (balance_cents >= 0),
  sold_price_cents          bigint check (sold_price_cents is null or sold_price_cents >= 0),
  status                    public.gift_card_status not null default 'active',
  purchaser_customer_id     uuid,
  owner_customer_id         uuid,
  recipient_name            text check (recipient_name is null or char_length(btrim(recipient_name)) between 1 and 120),
  recipient_email           extensions.citext check (recipient_email is null or public.is_valid_email(recipient_email::text)),
  message                   text check (message is null or char_length(message) <= 500),
  issued_via                text not null check (issued_via in ('online', 'staff', 'referral', 'refund')),
  stripe_payment_intent_id  text unique check (stripe_payment_intent_id is null
                                                or stripe_payment_intent_id ~ '^pi_[A-Za-z0-9]+$'),
  expires_at                timestamptz,
  voided_at                 timestamptz,
  void_reason               text check (void_reason is null or char_length(void_reason) <= 500),
  issued_by                 uuid references auth.users (id) on delete set null,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  constraint gift_cards_shop_id_id_key unique (shop_id, id),
  constraint gift_cards_shop_code_key unique (shop_id, code_hash),
  constraint gift_cards_purchaser_fk foreign key (shop_id, purchaser_customer_id)
    references public.customers (shop_id, id) on delete set null (purchaser_customer_id),
  constraint gift_cards_owner_fk foreign key (shop_id, owner_customer_id)
    references public.customers (shop_id, id) on delete set null (owner_customer_id),
  constraint gift_cards_void_stamp check ((status = 'void') = (voided_at is not null)),
  constraint gift_cards_void_empty check (status <> 'void' or balance_cents = 0),
  constraint gift_cards_balance_status check ((status <> 'active' or balance_cents > 0)
                                             and (status <> 'depleted' or balance_cents = 0))
);
create index gift_cards_shop_purchaser_idx on public.gift_cards (shop_id, purchaser_customer_id);
create index gift_cards_shop_owner_idx on public.gift_cards (shop_id, owner_customer_id);
create index gift_cards_shop_created_idx on public.gift_cards (shop_id, created_at);
create index gift_cards_issued_by_idx on public.gift_cards (issued_by);

comment on table public.gift_cards is
  'Gift cards (kind gift, redeemed with the code) and store credit (kind credit: referral rewards / refunds, owned by owner_customer_id). The code is never stored (code_hash). Server-maintained; managers+ read (code_hash excluded).';
comment on column public.gift_cards.owner_customer_id is
  'Store credit owner (kind credit), or the recipient customer of a gift card (informational).';

create trigger gift_cards_05_prevent_shop_change before update on public.gift_cards
  for each row execute function public.prevent_shop_change();
create trigger gift_cards_90_set_updated_at before update on public.gift_cards
  for each row execute function public.set_updated_at();

alter table public.gift_cards enable row level security;
create policy gift_cards_select on public.gift_cards for select to authenticated
  using (public.is_shop_manager(shop_id));

create table public.gift_card_transactions (
  id                   uuid primary key default gen_random_uuid(),
  shop_id              uuid not null references public.shops (id) on delete cascade,
  gift_card_id         uuid not null,
  kind                 public.gift_card_txn_kind not null,
  amount_cents         bigint not null,
  balance_after_cents  bigint not null check (balance_after_cents >= 0),
  payment_id           uuid,
  note                 text check (note is null or char_length(note) <= 500),
  created_by           uuid references auth.users (id) on delete set null,
  created_at           timestamptz not null default now(),
  constraint gift_card_transactions_shop_id_id_key unique (shop_id, id),
  constraint gift_card_transactions_card_fk foreign key (shop_id, gift_card_id)
    references public.gift_cards (shop_id, id) on delete cascade,
  constraint gift_card_transactions_payment_fk foreign key (shop_id, payment_id)
    references public.payments (shop_id, id) on delete restrict,
  constraint gift_card_transactions_amount check (amount_cents <> 0 or kind in ('void', 'expire'))
);
create index gift_card_transactions_shop_card_idx on public.gift_card_transactions (shop_id, gift_card_id, created_at);
create index gift_card_transactions_shop_payment_idx on public.gift_card_transactions (shop_id, payment_id);
create index gift_card_transactions_shop_created_idx on public.gift_card_transactions (shop_id, created_at);
create index gift_card_transactions_created_by_idx on public.gift_card_transactions (created_by);

comment on table public.gift_card_transactions is
  'Balance ledger of a gift card: issue (+), redeem (-, payment_id), refund (+ credit back of a refunded redemption, payment_id; - money refunded on an online order), adjust (±), void (- remaining balance).';

create trigger gift_card_transactions_05_prevent_shop_change before update on public.gift_card_transactions
  for each row execute function public.prevent_shop_change();

alter table public.gift_card_transactions enable row level security;
create policy gift_card_transactions_select on public.gift_card_transactions for select to authenticated
  using (public.is_shop_manager(shop_id));

create table public.gift_card_orders (
  id                          uuid primary key default gen_random_uuid(),
  shop_id                     uuid not null references public.shops (id) on delete cascade,
  token                       uuid not null default gen_random_uuid() unique,
  value_cents                 bigint not null check (value_cents > 0),
  price_cents                 bigint not null check (price_cents > 0),
  purchaser_name              text not null check (char_length(btrim(purchaser_name)) between 1 and 120),
  purchaser_email             extensions.citext not null check (public.is_valid_email(purchaser_email::text)),
  recipient_name              text check (recipient_name is null or char_length(btrim(recipient_name)) between 1 and 120),
  recipient_email             extensions.citext not null check (public.is_valid_email(recipient_email::text)),
  message                     text check (message is null or char_length(message) <= 500),
  status                      text not null default 'pending' check (status in ('pending', 'paid', 'refunded', 'expired')),
  stripe_checkout_session_id  text unique check (stripe_checkout_session_id is null
                                                  or stripe_checkout_session_id ~ '^cs_[A-Za-z0-9_]+$'),
  gift_card_id                uuid,
  refunded_cents              bigint not null default 0,
  signer_ip                   inet,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),
  constraint gift_card_orders_shop_id_id_key unique (shop_id, id),
  constraint gift_card_orders_card_fk foreign key (shop_id, gift_card_id)
    references public.gift_cards (shop_id, id) on delete set null (gift_card_id),
  constraint gift_card_orders_price check (price_cents <= value_cents),
  constraint gift_card_orders_refund_bound check (refunded_cents >= 0 and refunded_cents <= price_cents)
);
create index gift_card_orders_shop_email_idx on public.gift_card_orders (shop_id, purchaser_email, created_at);
create index gift_card_orders_shop_card_idx on public.gift_card_orders (shop_id, gift_card_id);

comment on table public.gift_card_orders is
  'Online gift card purchases (payments edge gift_card_checkout -> gift_card_order_prepare / _paid / _refunded). token = the success page credential. refunded_cents = cumulative refunded price. Managers+ read.';

create trigger gift_card_orders_05_prevent_shop_change before update on public.gift_card_orders
  for each row execute function public.prevent_shop_change();
create trigger gift_card_orders_90_set_updated_at before update on public.gift_card_orders
  for each row execute function public.set_updated_at();

alter table public.gift_card_orders enable row level security;
create policy gift_card_orders_select on public.gift_card_orders for select to authenticated
  using (public.is_shop_manager(shop_id));

-- Brute-force ledger for code lookups (definer RPCs only; no API access).
-- attempt_key: 'user:<uuid>' (staff), 'invoice:<uuid>' / 'ip:<addr>'
-- (public /i page). Rows older than a day are pruned as new ones arrive.
create table public.gift_card_attempts (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  attempt_key  text not null check (char_length(attempt_key) between 1 and 100),
  succeeded    boolean not null,
  created_at   timestamptz not null default now(),
  constraint gift_card_attempts_shop_id_id_key unique (shop_id, id)
);
create index gift_card_attempts_key_idx on public.gift_card_attempts (shop_id, attempt_key, created_at);

alter table public.gift_card_attempts enable row level security;
-- (no policies: service_role and definer code only)

-- ===========================================================================
-- P-15 Proposal options: a quote may offer up to 4 options (good / better /
-- best); a line with option_id belongs to that option, a line without is
-- shared by every option. Option totals are server-maintained.
-- ===========================================================================
create table public.quote_options (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops (id) on delete cascade,
  quote_id        uuid not null,
  name            text not null check (char_length(btrim(name)) between 1 and 80),
  description     text check (description is null or char_length(description) <= 2000),
  sort            integer not null default 0,
  subtotal_cents  bigint not null default 0 check (subtotal_cents >= 0),
  discount_cents  bigint not null default 0 check (discount_cents >= 0),
  tax_cents       bigint not null default 0 check (tax_cents >= 0),
  total_cents     bigint not null default 0 check (total_cents >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint quote_options_shop_id_id_key unique (shop_id, id),
  constraint quote_options_quote_fk foreign key (shop_id, quote_id)
    references public.quotes (shop_id, id) on delete cascade,
  constraint quote_options_totals_consistent check (total_cents = subtotal_cents - discount_cents + tax_cents)
);
create index quote_options_shop_quote_idx on public.quote_options (shop_id, quote_id, sort);

comment on table public.quote_options is
  'Proposal options of a quote (P-15, at most 4). Totals = shared lines + this option''s lines (counted lines only), with the quote''s discount and tax; server-maintained.';

alter table public.quote_line_items
  add column option_id uuid,
  add constraint quote_line_items_option_fk foreign key (shop_id, option_id)
    references public.quote_options (shop_id, id) on delete cascade;
create index quote_line_items_shop_option_idx on public.quote_line_items (shop_id, option_id);

comment on column public.quote_line_items.option_id is 'The proposal option this line belongs to (null = shared by every option).';

alter table public.quotes
  add column selected_option_id uuid,
  add constraint quotes_selected_option_fk foreign key (shop_id, selected_option_id)
    references public.quote_options (shop_id, id) on delete set null (selected_option_id);
create index quotes_shop_selected_option_idx on public.quotes (shop_id, selected_option_id);

comment on column public.quotes.selected_option_id is
  'The option the customer chose (public_respond_quote); staff may preselect one while the quote is a draft. Until then the lowest-sort option is counted.';

create trigger quote_options_05_prevent_shop_change before update on public.quote_options
  for each row execute function public.prevent_shop_change();
create trigger quote_options_90_set_updated_at before update on public.quote_options
  for each row execute function public.set_updated_at();

alter table public.quote_options enable row level security;
create policy quote_options_select on public.quote_options for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy quote_options_insert on public.quote_options for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy quote_options_update on public.quote_options for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy quote_options_delete on public.quote_options for delete to authenticated
  using (public.is_shop_manager(shop_id));

-- ===========================================================================
-- P-16 Quote self-scheduling.
-- ===========================================================================
alter table public.booking_settings
  add column quote_self_schedule boolean not null default false;
alter table public.quotes
  add column self_schedule     boolean not null default true,
  add column self_scheduled_at timestamptz;

comment on column public.booking_settings.quote_self_schedule is
  'Customers may pick a time for an approved quote on its /q page (public_quote_slots / public_schedule_quote).';
comment on column public.quotes.self_schedule is 'Per-quote opt-out of customer self-scheduling (staff-editable).';
comment on column public.quotes.self_scheduled_at is
  'When the customer scheduled the approved quote on its page (server-set by public_schedule_quote).';

-- ===========================================================================
-- P-21 Preset fees (fixed amounts entered by the shop; nothing seeded).
-- ===========================================================================
create table public.shop_fees (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 80),
  amount_cents  bigint not null check (amount_cents > 0),
  taxable       boolean not null default false,
  auto_apply    public.fee_apply_location not null default 'none',
  active        boolean not null default true,
  sort          integer not null default 0,
  archived_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint shop_fees_shop_id_id_key unique (shop_id, id)
);
create index shop_fees_shop_sort_idx on public.shop_fees (shop_id, sort, name);

comment on table public.shop_fees is
  'Preset fees (P-21): fixed amounts added as ordinary lines (fee_id), by hand (add_fee_line) or automatically by location type. Members read, owners/admins edit.';

create trigger shop_fees_05_prevent_shop_change before update on public.shop_fees
  for each row execute function public.prevent_shop_change();
create trigger shop_fees_90_set_updated_at before update on public.shop_fees
  for each row execute function public.set_updated_at();

alter table public.shop_fees enable row level security;
create policy shop_fees_select on public.shop_fees for select to authenticated
  using (public.is_shop_member(shop_id));
create policy shop_fees_insert on public.shop_fees for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy shop_fees_update on public.shop_fees for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy shop_fees_delete on public.shop_fees for delete to authenticated
  using (public.is_shop_admin(shop_id));

alter table public.job_line_items
  add column fee_id uuid,
  add constraint job_line_items_fee_fk foreign key (shop_id, fee_id)
    references public.shop_fees (shop_id, id) on delete set null (fee_id);
create index job_line_items_shop_fee_idx on public.job_line_items (shop_id, fee_id);
alter table public.quote_line_items
  add column fee_id uuid,
  add constraint quote_line_items_fee_fk foreign key (shop_id, fee_id)
    references public.shop_fees (shop_id, id) on delete set null (fee_id);
create index quote_line_items_shop_fee_idx on public.quote_line_items (shop_id, fee_id);
alter table public.invoice_line_items
  add column fee_id uuid,
  add constraint invoice_line_items_fee_fk foreign key (shop_id, fee_id)
    references public.shop_fees (shop_id, id) on delete set null (fee_id);
create index invoice_line_items_shop_fee_idx on public.invoice_line_items (shop_id, fee_id);

comment on column public.job_line_items.fee_id is 'The preset fee this line was added from (auto-applied or add_fee_line).';

-- ===========================================================================
-- P-23 Memberships v2: weekly interval, online joining, usage limits.
-- ===========================================================================
alter table public.membership_plans drop constraint membership_plans_interval_count;
alter table public.membership_plans
  add constraint membership_plans_interval_count check (
    (interval = 'month' and interval_count between 1 and 12)
    or (interval = 'year' and interval_count = 1)
    or (interval = 'week' and interval_count between 1 and 4));
alter table public.memberships drop constraint memberships_interval_count;
alter table public.memberships
  add constraint memberships_interval_count check (
    (interval = 'month' and interval_count between 1 and 36)
    or (interval = 'year' and interval_count between 1 and 3)
    or (interval = 'week' and interval_count between 1 and 12));

alter table public.membership_plans
  add column online_joinable           boolean not null default false,
  add column included_uses_per_period  integer check (included_uses_per_period is null
                                                      or included_uses_per_period between 1 and 100),
  add column terms                     text check (terms is null or char_length(terms) <= 5000);

comment on column public.membership_plans.online_joinable is 'Offered on the public join page (public_membership_plans).';
comment on column public.membership_plans.included_uses_per_period is
  'Included services may be used this many times per billing period (null = unlimited).';

alter table public.job_line_items
  add column membership_id uuid,
  add constraint job_line_items_membership_fk foreign key (shop_id, membership_id)
    references public.memberships (shop_id, id) on delete set null (membership_id);
create index job_line_items_shop_membership_idx on public.job_line_items (shop_id, membership_id);
alter table public.quote_line_items
  add column membership_id uuid,
  add constraint quote_line_items_membership_fk foreign key (shop_id, membership_id)
    references public.memberships (shop_id, id) on delete set null (membership_id);
create index quote_line_items_shop_membership_idx on public.quote_line_items (shop_id, membership_id);
alter table public.invoice_line_items
  add column membership_id uuid,
  add constraint invoice_line_items_membership_fk foreign key (shop_id, membership_id)
    references public.memberships (shop_id, id) on delete set null (membership_id);
create index invoice_line_items_shop_membership_idx on public.invoice_line_items (shop_id, membership_id);

comment on column public.job_line_items.membership_id is
  'The membership whose included visit this line uses (validated / auto-assigned by job_line_items_61_membership_use).';

-- ===========================================================================
-- P-29 Referral program. The referee discount IS a coupon (referral code),
-- the referrer reward IS store credit (gift_cards kind 'credit').
-- ===========================================================================
create table public.referral_settings (
  shop_id                 uuid primary key references public.shops (id) on delete cascade,
  enabled                 boolean not null default false,
  referee_discount_kind   public.coupon_kind not null default 'fixed',
  referee_discount_value  bigint not null default 0 check (referee_discount_value >= 0),
  referrer_reward_cents   bigint not null default 0 check (referrer_reward_cents >= 0),
  terms                   text check (terms is null or char_length(terms) <= 2000),
  updated_at              timestamptz not null default now(),
  constraint referral_settings_percent check (referee_discount_kind <> 'percent' or referee_discount_value <= 10000),
  -- a referral code is a coupon, and a coupon discounts something
  constraint referral_settings_enabled_discount check (not enabled or referee_discount_value > 0)
);

comment on table public.referral_settings is
  'Referral program (P-29): the new customer''s discount (their referral coupon) and the referrer''s store credit once the referee''s first job is completed. Nothing enabled or seeded with amounts. Managers read, owners/admins edit.';

create trigger referral_settings_05_prevent_shop_change before update on public.referral_settings
  for each row execute function public.prevent_shop_change();
create trigger referral_settings_90_set_updated_at before update on public.referral_settings
  for each row execute function public.set_updated_at();

alter table public.referral_settings enable row level security;
create policy referral_settings_select on public.referral_settings for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy referral_settings_update on public.referral_settings for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));

alter table public.customers
  add column referral_code extensions.citext check (referral_code is null or referral_code::text ~ '^[A-Z0-9]{4,12}$');
create unique index customers_shop_referral_code_key on public.customers (shop_id, referral_code)
  where referral_code is not null;

comment on column public.customers.referral_code is
  'The customer''s referral code (also the code of their referral coupon). Server-set (get_or_create_referral_code).';

create table public.referral_credits (
  id                    uuid primary key default gen_random_uuid(),
  shop_id               uuid not null references public.shops (id) on delete cascade,
  referrer_customer_id  uuid not null,
  referee_customer_id   uuid not null,
  coupon_id             uuid,
  job_id                uuid,
  gift_card_id          uuid,
  amount_cents          bigint not null check (amount_cents >= 0),
  status                text not null check (status in ('issued', 'skipped')),
  created_at            timestamptz not null default now(),
  constraint referral_credits_shop_id_id_key unique (shop_id, id),
  constraint referral_credits_job_key unique (job_id),
  constraint referral_credits_referrer_fk foreign key (shop_id, referrer_customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint referral_credits_referee_fk foreign key (shop_id, referee_customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint referral_credits_coupon_fk foreign key (shop_id, coupon_id)
    references public.coupons (shop_id, id) on delete set null (coupon_id),
  -- the credit outlives the rewarded job: deleting that job must not let the
  -- referee earn the referrer a second reward (0069 checks per referee)
  constraint referral_credits_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id),
  constraint referral_credits_card_fk foreign key (shop_id, gift_card_id)
    references public.gift_cards (shop_id, id) on delete set null (gift_card_id),
  constraint referral_credits_skipped_zero check (status = 'issued' or amount_cents = 0)
);
create index referral_credits_shop_referrer_idx on public.referral_credits (shop_id, referrer_customer_id);
create index referral_credits_shop_referee_idx on public.referral_credits (shop_id, referee_customer_id);
create index referral_credits_shop_coupon_idx on public.referral_credits (shop_id, coupon_id);
create index referral_credits_shop_card_idx on public.referral_credits (shop_id, gift_card_id);
create index referral_credits_shop_job_idx on public.referral_credits (shop_id, job_id);

comment on table public.referral_credits is
  'One row per referee: their first completed job carrying a referral coupon, issued (store credit to the referrer) or skipped (program off / no reward). job_id is cleared (not the row) when that job is deleted. Server-maintained; managers+ read.';

create trigger referral_credits_05_prevent_shop_change before update on public.referral_credits
  for each row execute function public.prevent_shop_change();

alter table public.referral_credits enable row level security;
create policy referral_credits_select on public.referral_credits for select to authenticated
  using (public.is_shop_manager(shop_id));

-- ===========================================================================
-- P-31 ACH / pay-later payments through Stripe.
-- ===========================================================================
alter table public.payments
  add column stripe_method_type text check (stripe_method_type is null or stripe_method_type ~ '^[a-z][a-z0-9_]{0,39}$');

comment on column public.payments.stripe_method_type is
  'Stripe payment_method type (card, us_bank_account, affirm, klarna, afterpay_clearpay, link, ...) as reported by the webhook.';

alter table public.payments drop constraint payments_card_via_stripe;
alter table public.payments drop constraint payments_manual_no_card_data;
alter table public.payments
  -- Stripe-backed methods always come from a PaymentIntent; manual and gift
  -- card rows never have one
  add constraint payments_card_via_stripe check (
    (method in ('card', 'card_present', 'ach_debit', 'bnpl')) = (stripe_payment_intent_id is not null)),
  -- only Stripe-backed rows carry Stripe / card data
  add constraint payments_manual_no_card_data check (
    method in ('card', 'card_present', 'ach_debit', 'bnpl')
    or (card_brand is null and card_last4 is null and stripe_charge_id is null
        and stripe_checkout_session_id is null and stripe_method_type is null)),
  -- gift card redemptions pay invoices (no tips, no deposits)
  add constraint payments_gift_card_shape check (
    method <> 'gift_card' or (kind = 'payment' and tip_cents = 0));

-- ===========================================================================
-- Seeds: per-shop settings rows (defaults only: nothing enabled, no amounts).
-- ===========================================================================
create function public.shops_money_v2_seed() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.gift_card_settings (shop_id) values (new.id) on conflict (shop_id) do nothing;
  insert into public.referral_settings (shop_id) values (new.id) on conflict (shop_id) do nothing;
  return null;
end
$$;

create trigger shops_zz_money_seed after insert on public.shops
  for each row execute function public.shops_money_v2_seed();

insert into public.gift_card_settings (shop_id) select s.id from public.shops s on conflict (shop_id) do nothing;
insert into public.referral_settings (shop_id) select s.id from public.shops s on conflict (shop_id) do nothing;

-- ===========================================================================
-- Grants: no anon access; API roles never TRUNCATE / TRIGGER / REFERENCES;
-- server-maintained tables have no client writes.
-- ===========================================================================
do $$
declare
  t text;
begin
  foreach t in array array[
    'shop_terminal_locations', 'invoice_jobs', 'coupon_redemptions', 'gift_card_settings', 'gift_cards',
    'gift_card_transactions', 'gift_card_orders', 'gift_card_attempts', 'quote_options', 'shop_fees',
    'referral_settings', 'referral_credits'] loop
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke truncate, trigger, references on public.%I from authenticated', t);
  end loop;
end
$$;

revoke insert, update, delete on public.shop_terminal_locations, public.invoice_jobs, public.coupon_redemptions,
  public.gift_cards, public.gift_card_transactions, public.gift_card_orders, public.referral_credits
  from authenticated;
revoke insert, delete on public.gift_card_settings, public.referral_settings from authenticated;
revoke all on public.gift_card_attempts from authenticated;

-- gift_cards.code_hash is never readable by API roles (codes are credentials)
revoke select on public.gift_cards from authenticated;
do $$
declare
  v_cols text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.gift_cards'::regclass
     and a.attnum > 0
     and not a.attisdropped
     and a.attname <> 'code_hash';
  execute format('grant select (%s) on public.gift_cards to authenticated', v_cols);
end
$$;

revoke execute on function public.shops_money_v2_seed() from public, anon, authenticated;
revoke execute on function public.gift_card_offers_valid(jsonb) from public, anon;
grant execute on function public.gift_card_offers_valid(jsonb) to authenticated, service_role;
