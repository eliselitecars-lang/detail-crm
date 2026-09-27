-- ============================================================================
-- 0015 — Money range privilege hardening. TRUNCATE / TRIGGER / REFERENCES
-- bypass RLS or are never needed by API roles; anon has nothing on any money
-- table (public pages go through the public_* RPCs). Pure helper functions
-- that do not touch tables stay callable by staff (they are harmless) but not
-- by anon.
-- ============================================================================
do $$
declare
  t text;
begin
  foreach t in array array[
    'quotes', 'quote_line_items', 'membership_plans', 'memberships', 'customer_payment_methods',
    'stripe_events', 'invoices', 'invoice_line_items', 'payments'] loop
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke truncate, trigger, references on public.%I from authenticated', t);
  end loop;
end
$$;

revoke execute on function
  public.quote_validity_end(date, text),
  public.payment_net_amount(public.payment_status, bigint, bigint, bigint),
  public.payment_net_tip(public.payment_status, bigint, bigint, bigint),
  public.payment_refund_status(bigint, bigint, bigint),
  public.payment_in_flight(public.payment_status, timestamptz, timestamptz)
from public, anon;
-- payment_in_flight is also evaluated by SECURITY INVOKER guards (staff).
grant execute on function
  public.quote_validity_end(date, text),
  public.payment_net_amount(public.payment_status, bigint, bigint, bigint),
  public.payment_net_tip(public.payment_status, bigint, bigint, bigint),
  public.payment_refund_status(bigint, bigint, bigint),
  public.payment_in_flight(public.payment_status, timestamptz, timestamptz)
to authenticated, service_role;
