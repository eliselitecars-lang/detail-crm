-- ============================================================================
-- 0132 — A customer is deleted only through the payments edge erase_customer.
--
-- 0125 dropped the RLS policy customers_delete, so a client DELETE on
-- public.customers already matched no rows, but it kept the table's DELETE
-- grant while the web still sent its old direct delete. The web (and any
-- other client) now asks the payments action erase_customer (owner / admin:
-- a dry run, then confirm), which closes what Stripe still holds for the
-- person and then calls erase_customer (service role) to delete or
-- anonymise the record.
--
-- So, as 0117 did for shops:
--   * DELETE on public.customers is revoked from public, anon and
--     authenticated: a client DELETE is 42501 permission denied instead of
--     silently deleting nothing.
-- service_role (the payments edge; erase_customer / customer_erase_apply
-- are SECURITY DEFINER) and direct database sessions keep deleting as
-- before, still bound by the ON DELETE RESTRICT references (jobs, invoices,
-- payments, memberships). Cascades from a deleted shop are unaffected.
-- ============================================================================

revoke delete on table public.customers from public, anon, authenticated;

comment on table public.customers is
  'Shop customers (SPEC §4.2). Deleted or anonymised only by erase_customer (0125, through the payments edge erase_customer): clients have no DELETE policy and no DELETE privilege (0132).';
