-- ============================================================================
-- 0117 — A shop is deleted only through the payments edge delete_shop.
--
-- 0002 let the owner delete the shop row straight through PostgREST
-- (policy shops_delete + the table's DELETE grant). That skipped everything
-- delete_shop (supabase/functions/payments/shop_delete.ts) does around the
-- delete: the typed shop name, stopping the shop's platform subscription
-- (docs/BILLING.md — shop_billing cascaded away, so billing-webhook could no
-- longer map the subscription's later invoices and the owner kept being
-- charged for a shop that no longer exists), expiring the shop's open
-- Connect Checkout links (a customer could still pay a deleted shop's
-- invoice or deposit) and giving self-serve text numbers back to Twilio.
--
-- The edge deletes with the service role (step 5), so clients need neither:
--   * policy shops_delete is dropped;
--   * DELETE on public.shops is revoked from anon and authenticated (a
--     client DELETE is 42501 permission denied).
-- service_role and direct database sessions keep deleting as before
-- (shops_money_delete_guard still re-checks memberships and payments in
-- flight).
-- ============================================================================

drop policy shops_delete on public.shops;
revoke delete on table public.shops from public, anon, authenticated;

comment on table public.shops is
  'Tenant. Created only via public.create_shop (or service_role); deleted only by the payments edge delete_shop (service role, 0117: clients have no DELETE), which first stops the shop''s platform subscription and expires its open pay links.';
