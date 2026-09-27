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

-- ---------------------------------------------------------------------------
-- invoices.public_token is the customer's credential: whoever holds it can,
-- without signing in, read the invoice (customer name, lines, payments with
-- card brand/last4) and open Checkout for it — i.e. act as the customer. A
-- technician who may collect payments on an assigned job reads that job's
-- invoice (invoices_select) but must not keep a working customer link after
-- the owner turns collecting off or removes them; technicians collect
-- through record_manual_payment and the in-app PaymentSheet instead. So, as
-- for jobs.public_token (0042) and form_submissions.public_token (0023):
-- `authenticated` gets SELECT on every invoices column EXCEPT public_token,
-- and owners/admins/managers fetch it with invoice_link_token(invoice_id) to
-- share the /i link. service_role keeps full access (edge functions resolve
-- tokens); anon has no table access. A migration that adds an invoices
-- column must grant SELECT on it to authenticated
-- (20_form_token_privacy.sql checks the whole column set).
-- ---------------------------------------------------------------------------
create function public.invoice_link_token(p_invoice_id uuid) returns uuid
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_shop  uuid;
  v_token uuid;
begin
  select i.shop_id, i.public_token into v_shop, v_token from public.invoices i where i.id = p_invoice_id;
  if v_shop is null or not public.is_shop_member(v_shop) then
    raise exception 'invoice not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_shop) then
    raise exception 'only owners, admins and managers can share the invoice link' using errcode = '42501';
  end if;
  return v_token;
end
$$;

revoke select on public.invoices from authenticated;
do $$
declare
  v_cols text;
begin
  select string_agg(format('%I', a.attname), ', ' order by a.attnum)
    into v_cols
    from pg_catalog.pg_attribute a
   where a.attrelid = 'public.invoices'::regclass
     and a.attnum > 0
     and not a.attisdropped
     and a.attname <> 'public_token';
  execute format('grant select (%s) on public.invoices to authenticated', v_cols);
end
$$;

revoke execute on function public.invoice_link_token(uuid) from public, anon, service_role;
grant execute on function public.invoice_link_token(uuid) to authenticated;
