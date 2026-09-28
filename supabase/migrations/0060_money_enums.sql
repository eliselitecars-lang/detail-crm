-- ============================================================================
-- 0060 — Money v2 (SPEC §9 range 0060-0069): enum types and enum values.
--
--   0060  enums (this file)
--   0061  schema: every new table, column, CHECK replacement, index, RLS
--         policy, grant, seed trigger and backfill of the range
--   0062  coupon restrictions + discount-eligible totals (P-13a)
--   0063  multi-job invoices, invoice_jobs, customer-merge bypasses (P-7)
--   0064  async (ACH / pay-later) payments and Terminal rows (P-31, P-6)
--   0065  sold-by, service / sales commissions, tips per technician (P-12)
--   0066  gift cards and store credit (P-13b)
--   0067  proposal options + quote self-scheduling (P-15, P-16)
--   0068  preset fees with auto-apply by location (P-21)
--   0069  memberships v2 + referral program (P-23, P-29)
--
-- ALTER TYPE ... ADD VALUE runs inside the migration's transaction, and a
-- value added in a transaction cannot be used before it commits, so nothing
-- in this file uses the new values (0061 onward may). New enum TYPES may be
-- used right away but are also only created here.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- New types
-- ---------------------------------------------------------------------------
-- services.commission_kind (P-12): none | percent (commission_value = bps of
-- the line's net) | flat (commission_value = cents per unit sold).
create type public.commission_kind as enum ('none', 'percent', 'flat');

-- shop_fees.auto_apply (P-21): which job location types get the fee line
-- automatically.
create type public.fee_apply_location as enum ('none', 'shop', 'mobile', 'both');

-- gift_cards.status (P-13b). 'expired' is informational (expiry is read from
-- expires_at); 'depleted' = balance 0, back to active on a credit-back.
create type public.gift_card_status as enum ('active', 'depleted', 'void', 'expired');

-- gift_card_transactions.kind (P-13b): the balance ledger of a card.
create type public.gift_card_txn_kind as enum ('issue', 'redeem', 'refund', 'adjust', 'void', 'expire');

comment on type public.commission_kind is
  'services.commission_kind: none | percent (commission_value in bps of the line net) | flat (commission_value cents per unit).';
comment on type public.fee_apply_location is
  'shop_fees.auto_apply: none (added by hand) | shop | mobile | both (location types that get the fee automatically).';
comment on type public.gift_card_status is 'gift_cards.status: active | depleted (balance 0) | void | expired.';
comment on type public.gift_card_txn_kind is
  'gift_card_transactions.kind: issue | redeem | refund (credit back or order refund) | adjust | void | expire.';

-- ---------------------------------------------------------------------------
-- New values of existing types
-- ---------------------------------------------------------------------------
-- payments (P-31, P-13b): gift card redemptions (tender recorded by the
-- redeem RPCs), ACH debits and buy-now-pay-later through Stripe.
alter type public.payment_method add value if not exists 'gift_card';
alter type public.payment_method add value if not exists 'ach_debit';
alter type public.payment_method add value if not exists 'bnpl';

-- an ACH / delayed-notification payment Stripe is still clearing (in flight
-- until it succeeds or fails; counts 0 toward balances)
alter type public.payment_status add value if not exists 'processing';

-- memberships v2 (P-23): weekly billing
alter type public.membership_interval add value if not exists 'week';

-- staff notifications (P-13b, P-23)
alter type public.notification_kind add value if not exists 'gift_card_purchased';
alter type public.notification_kind add value if not exists 'membership_joined';

-- customer messages (P-13b, P-29). Wording, seeding and classification
-- (both transactional) belong to the comms range (0083); until a shop has a
-- template for a key, enqueueing it is a no-op (returns null).
alter type public.message_template_key add value if not exists 'gift_card_delivery';
alter type public.message_template_key add value if not exists 'referral_reward';
