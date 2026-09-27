-- 10 money: range-wide security — cross-shop isolation for every money table
-- with both shops populated, per-role read matrix, table grants, function
-- exposure per role, and shop deletion with money records present.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ populate both shops
create function pg_temp.populate(p_shop text, p_suffix text) returns void language plpgsql as $$
declare
  v_shop uuid := tests.fx('shop_' || p_shop);
  v_mgr  uuid := tests.fx('u_manager_' || p_shop);
  v_job  uuid := tests.fx('job_' || p_shop);
  v_cust uuid := tests.fx('cust_' || p_shop);
  v_q    uuid;
  v_inv  uuid;
  v_plan uuid;
  v_mem  uuid;
begin
  perform tests.authenticate_as(v_mgr);
  insert into public.quotes (shop_id, customer_id) values (v_shop, v_cust) returning id into v_q;
  insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (v_shop, v_q, 'Wash', 1000);
  perform public.mark_quote_sent(v_q);
  v_inv := (public.create_invoice_from_job(v_job)).id;
  perform public.record_manual_payment(v_inv, 100, 'cash');
  insert into public.membership_plans (shop_id, name, price_cents) values (v_shop, 'Plan', 3000) returning id into v_plan;
  v_mem := (public.create_membership(v_plan, v_cust)).id;
  perform tests.as_service();
  perform public.upsert_stripe_payment(v_shop, 'pi_sec' || p_suffix, 'succeeded', 200, p_invoice_id => v_inv);
  perform public.sync_stripe_subscription(v_shop, 'sub_sec' || p_suffix, 'active', null, false, v_mem, '2025-06-01Z');
  perform public.upsert_stripe_payment(v_shop, 'pi_secm' || p_suffix, 'succeeded', 3000, p_kind => 'membership', p_membership_id => v_mem);
  perform public.upsert_customer_payment_method(v_shop, v_cust, 'pm_sec' || p_suffix, 'visa', '4242', 1, 2030);
  perform public.record_stripe_event('evt_sec' || p_suffix, 'payment_intent.succeeded', null, '2025-06-01Z');
  perform tests.as_superuser();
end
$$;
select pg_temp.populate('a', 'a');
select pg_temp.populate('b', 'b');
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id in (tests.fx('shop_a'), tests.fx('shop_b'));

-- ------------------------------------------------------------ cross-shop: every money table, every role of A
do $$
declare
  t      text;
  u      text;
  v_n    bigint;
  v_rows bigint;
  v_ok   boolean;
begin
  foreach t in array array['quotes', 'quote_line_items', 'invoices', 'invoice_line_items', 'payments',
                           'membership_plans', 'memberships', 'customer_payment_methods'] loop
    perform tests.as_superuser();
    execute format('select count(*) from public.%I where shop_id = $1', t) into v_rows using tests.fx('shop_b');
    perform tests.ok(v_rows > 0, format('shop B has %s rows to protect', t));
    foreach u in array array['u_owner_a', 'u_admin_a', 'u_manager_a', 'u_tech_a', 'u_outsider'] loop
      perform tests.authenticate_as(tests.fx(u));
      execute format('select count(*) from public.%I where shop_id = $1', t) into v_n using tests.fx('shop_b');
      perform tests.eq(v_n, 0::bigint, format('%s reads no shop B %s', u, t));
      begin
        execute format('update public.%I set shop_id = shop_id where shop_id = $1', t) using tests.fx('shop_b');
        get diagnostics v_n = row_count;
        v_ok := v_n = 0;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s updates no shop B %s', u, t));
      begin
        execute format('delete from public.%I where shop_id = $1', t) using tests.fx('shop_b');
        get diagnostics v_n = row_count;
        v_ok := v_n = 0;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s deletes no shop B %s', u, t));
      begin
        execute format('insert into public.%I (shop_id) values ($1)', t) using tests.fx('shop_b');
        v_ok := false;
      exception when insufficient_privilege then
        v_ok := true;
      end;
      perform tests.ok(v_ok, format('%s cannot plant a %s row in shop B (42501)', u, t));
    end loop;
  end loop;
  perform tests.as_superuser();
end
$$;
select tests.eq((select count(*) from public.payments where shop_id = tests.fx('shop_b')), 3::bigint, 'shop B payments intact');
select tests.eq((select count(*) from public.invoices where shop_id = tests.fx('shop_b')), 1::bigint, 'shop B invoices intact');

-- ------------------------------------------------------------ per-role read matrix inside shop A
create function pg_temp.visible(p_table text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('select count(*) from public.%I', p_table) into v;
  return v;
end
$$;
do $$
declare
  r record;
begin
  for r in select * from (values
      -- table,                     owner, admin, manager, tech (assigned + collecting on), tech2 (not assigned to job_a)
      ('quotes',                    1, 1, 1, 0, 0),
      ('quote_line_items',          1, 1, 1, 0, 0),
      ('invoices',                  1, 1, 1, 1, 0),
      ('invoice_line_items',        1, 1, 1, 1, 0),
      ('payments',                  3, 3, 3, 2, 0),
      ('membership_plans',          1, 1, 1, 0, 0),
      ('memberships',               1, 1, 1, 0, 0),
      ('customer_payment_methods',  1, 1, 1, 0, 0)) as x(t, o, a, m, te, te2) loop
    perform tests.authenticate_as(tests.fx('u_owner_a'));
    perform tests.eq(pg_temp.visible(r.t), r.o::bigint, 'owner sees ' || r.t);
    perform tests.authenticate_as(tests.fx('u_admin_a'));
    perform tests.eq(pg_temp.visible(r.t), r.a::bigint, 'admin sees ' || r.t);
    perform tests.authenticate_as(tests.fx('u_manager_a'));
    perform tests.eq(pg_temp.visible(r.t), r.m::bigint, 'manager sees ' || r.t);
    perform tests.authenticate_as(tests.fx('u_tech_a'));
    perform tests.eq(pg_temp.visible(r.t), r.te::bigint, 'assigned collecting technician sees ' || r.t);
    perform tests.authenticate_as(tests.fx('u_tech2_a'));
    perform tests.eq(pg_temp.visible(r.t), r.te2::bigint, 'unassigned technician sees ' || r.t);
  end loop;
  perform tests.as_superuser();
end
$$;
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select * from public.stripe_events$$, '42501', 'owners cannot read stripe_events');
select tests.as_service();
select tests.eq((select count(*) from public.stripe_events where id like 'evt_sec%'), 2::bigint, 'service_role reads stripe_events');
select tests.eq((select count(*) from public.payments where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))), 6::bigint,
                'service_role reads every payment');

-- ------------------------------------------------------------ table grants
select tests.as_superuser();
select tests.eq((
  select coalesce(string_agg(table_name || ':' || privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public' and grantee = 'anon'
    and table_name in ('quotes', 'quote_line_items', 'invoices', 'invoice_line_items', 'payments', 'membership_plans',
                       'memberships', 'customer_payment_methods', 'stripe_events')),
  '', 'anon holds no privileges on money tables');
select tests.eq((
  select coalesce(string_agg(table_name || ':' || privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public' and grantee = 'authenticated'
    and table_name in ('quotes', 'quote_line_items', 'invoices', 'invoice_line_items', 'payments', 'membership_plans',
                       'memberships', 'customer_payment_methods', 'stripe_events')
    and (privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES')
         or (table_name = 'payments' and privilege_type <> 'SELECT')
         or (table_name = 'customer_payment_methods' and privilege_type <> 'SELECT')
         or (table_name = 'stripe_events')
         or (table_name in ('invoices', 'memberships') and privilege_type = 'INSERT')
         or (table_name = 'memberships' and privilege_type = 'DELETE'))),
  '', 'authenticated: read-only payments/cards, no stripe_events, RPC-only inserts for invoices/memberships, '
      || 'memberships never deleted, no TRUNCATE/TRIGGER/REFERENCES');

-- ------------------------------------------------------------ function exposure
select tests.eq((
  select coalesce(string_agg(p.proname, ',' order by p.proname), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
    and p.proname in ('public_get_quote', 'public_respond_quote', 'public_get_invoice', 'mark_quote_sent', 'convert_quote_to_job',
                      'expire_quotes', 'create_invoice_from_job', 'create_invoice', 'mark_invoice_sent', 'void_invoice',
                      'record_manual_payment', 'refund_manual_payment', 'upsert_stripe_payment', 'apply_stripe_refund',
                      'record_stripe_event', 'mark_stripe_event_processed', 'job_payment_summary', 'create_membership',
                      'sync_stripe_subscription', 'upsert_customer_payment_method', 'remove_customer_payment_method',
                      'can_collect_for_job', 'can_collect_for_invoice', 'money_public_quote_json', 'money_public_invoice_json',
                      'money_public_shop_json', 'money_raise_invalid', 'quote_validity_end', 'payment_net_amount')),
  'public_get_invoice,public_get_quote,public_respond_quote', 'anon executes only the public money RPCs');
select tests.eq((
  select coalesce(string_agg(p.proname, ',' order by p.proname), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname in ('expire_quotes', 'upsert_stripe_payment', 'apply_stripe_refund', 'record_stripe_event',
                      'mark_stripe_event_processed', 'sync_stripe_subscription', 'upsert_customer_payment_method',
                      'remove_customer_payment_method', 'money_public_quote_json', 'money_public_invoice_json',
                      'money_public_shop_json', 'money_public_vehicle_json', 'money_vehicle_label', 'money_raise_invalid')),
  '', 'service-only and internal helpers are not executable by signed-in users');
select tests.eq((
  select string_agg(p.proname, ',' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname in ('mark_quote_sent', 'convert_quote_to_job', 'create_invoice_from_job', 'create_invoice', 'mark_invoice_sent',
                      'void_invoice', 'record_manual_payment', 'refund_manual_payment', 'job_payment_summary', 'create_membership')),
  'convert_quote_to_job,create_invoice,create_invoice_from_job,create_membership,job_payment_summary,mark_invoice_sent,mark_quote_sent,'
  || 'record_manual_payment,refund_manual_payment,void_invoice', 'staff RPCs are executable by signed-in users (they check roles)');
select tests.eq((
  select string_agg(p.proname, ',' order by p.proname)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('service_role', p.oid, 'execute')
    and p.proname in ('expire_quotes', 'upsert_stripe_payment', 'apply_stripe_refund', 'record_stripe_event',
                      'mark_stripe_event_processed', 'sync_stripe_subscription', 'upsert_customer_payment_method',
                      'remove_customer_payment_method')),
  'apply_stripe_refund,expire_quotes,mark_stripe_event_processed,record_stripe_event,remove_customer_payment_method,'
  || 'sync_stripe_subscription,upsert_customer_payment_method,upsert_stripe_payment', 'service_role runs the webhook/cron helpers');
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and p.proname in ('mark_quote_sent', 'convert_quote_to_job', 'expire_quotes', 'create_invoice_from_job', 'create_invoice',
                      'mark_invoice_sent', 'void_invoice', 'record_manual_payment', 'refund_manual_payment', 'upsert_stripe_payment',
                      'apply_stripe_refund', 'record_stripe_event', 'mark_stripe_event_processed', 'job_payment_summary',
                      'create_membership', 'sync_stripe_subscription', 'upsert_customer_payment_method',
                      'remove_customer_payment_method', 'public_get_quote', 'public_respond_quote', 'public_get_invoice')
    and not coalesce('search_path=""' = any (p.proconfig), false)),
  '', 'every money SECURITY DEFINER RPC pins search_path to empty');

-- ------------------------------------------------------------ guards never reveal another shop's rows
-- A manager of A who knows B's ids gets the same RLS rejection whatever state B's rows are in.
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('inv_b2', (public.create_invoice(tests.fx('cust_b'), '[{"name":"Wash","unit_price_cents":5000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_b2'));
select public.record_manual_payment(tests.fx('inv_b2'), 100, 'cash');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$insert into public.invoice_line_items (shop_id, invoice_id, name, unit_price_cents)
                      values (tests.fx('shop_b'), tests.fx('inv_b2'), 'X', 1)$$, '42501',
                    'planting a line on B''s paid-into invoice: plain RLS denial, no status leak');
select tests.throws($$insert into public.membership_plans (shop_id, name, price_cents, included_service_ids)
                      values (tests.fx('shop_b'), 'X', 100, array[tests.fx('svc_b')])$$, '23503',
                    'B''s services are invisible to A''s staff, so a plan can never include them');

-- ------------------------------------------------------------ shop deletion vs. Stripe billing
-- Deleting a shop cascades through its memberships and payments, but the
-- Stripe objects on its connected account live on: a subscription would keep
-- charging customers with nothing recorded and no way to cancel it. So the
-- delete is refused (in every context) while a membership is not cancelled
-- or a card payment is in flight.
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', '%membership(s) that are not cancelled%',
                         'a shop with a membership still billing in Stripe (sub_secb) cannot be deleted');
select tests.as_service();
select tests.throws($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', 'not by service_role either');
select tests.as_superuser();
select tests.throws($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', 'nor from a direct database session');
select tests.ok((select count(*) = 1 from public.memberships where shop_id = tests.fx('shop_b') and status = 'active'),
                'the membership is still there to be cancelled');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 0::bigint,
                'another shop''s owner still cannot delete it (RLS, no state revealed)');
-- a past_due membership bills (Stripe retries) as well
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_b'), 'sub_secb', 'past_due', null, false, null, '2025-07-01Z');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', 'nor with a past_due membership');
-- membership_cancel stops the subscription; the webhook records the cancellation
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_b'), 'sub_secb', 'cancelled', null, false, null, '2025-07-02Z');
-- an incomplete membership may have a payable subscription-mode Checkout link
select tests.authenticate_as(tests.fx('u_manager_b'));
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_b'), 'Yearly', 30000)
  returning tests.fx_set('plan_b_yearly', id);
select tests.fx_set('mem_b_new', (public.create_membership(tests.fx('plan_b_yearly'), tests.fx('cust_b'))).id);
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', '%1 membership(s)%',
                         'nor with an incomplete membership (its checkout link could start a subscription)');
select tests.as_service();
update public.memberships set status = 'cancelled' where id = tests.fx('mem_b_new') and status = 'incomplete';
-- a card payment being confirmed (PaymentSheet) would move unrecorded money
select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_secfly', 'pending', 500, p_customer_id => tests.fx('cust_b'));
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$delete from public.shops where id = tests.fx('shop_b')$$, '55000', '%card payment is in progress%',
                         'a shop with a card payment in flight cannot be deleted');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_b'), 'pi_secfly', 'cancelled', 500, p_customer_id => tests.fx('cust_b'));
-- an abandoned intent (pending for over an hour) no longer blocks anything
select tests.as_superuser();
insert into public.payments (shop_id, customer_id, method, status, amount_cents, stripe_payment_intent_id, created_at)
  values (tests.fx('shop_b'), tests.fx('cust_b'), 'card', 'pending', 700, 'pi_secstale', now() - interval '2 hours');
-- shop A's own open membership does not block shop B
select tests.ok((select count(*) = 1 from public.memberships where shop_id = tests.fx('shop_a') and status = 'active'),
                'shop A still has a billing membership');

-- ------------------------------------------------------------ the owner can then delete a shop full of money records
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_b')$$), 1::bigint,
                'deleting a shop cascades through quotes, invoices, payments, memberships and cards');
select tests.as_superuser();
select tests.eq((select count(*) from public.payments where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.invoices where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.invoice_line_items where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.quotes where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.memberships where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.membership_plans where shop_id = tests.fx('shop_b'))
              + (select count(*) from public.customer_payment_methods where shop_id = tests.fx('shop_b')), 0::bigint,
                'no money rows of the deleted shop remain');
select tests.eq((select count(*) from public.payments where shop_id = tests.fx('shop_a')), 3::bigint, 'shop A untouched');

-- ============================================================ saved cards belong to the customer's Stripe customer
select tests.as_superuser();
update public.customers set stripe_customer_id = 'cus_Alice01' where id = tests.fx('cust_a');
select tests.as_service();
select tests.eq((select last4 from public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_owned', 'visa', '4242',
                   12, 2031, false, 'cus_Alice01')), '4242', 'a card of the customer''s own Stripe customer is saved');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_foreign', 'visa',
                           '1111', 12, 2031, false, 'cus_Someone9')$$, '22023', '%another Stripe customer%',
                         'a card attached to another Stripe customer is refused');
select tests.throws_like($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a2'), 'pm_nolink', 'visa',
                           '1111', 12, 2031, false, 'cus_Alice01')$$, '22023', '%another Stripe customer%',
                         'a customer with no Stripe customer cannot take a Stripe customer''s card');
select tests.lives($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_legacy', 'visa', '5555',
                     1, 2030)$$, 'without the Stripe customer the old check (card owner in this shop) applies');
select tests.as_superuser();
select tests.eq((select count(*) from public.customer_payment_methods where stripe_payment_method_id in ('pm_foreign', 'pm_nolink')),
                0::bigint, 'refused cards are not stored');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.upsert_customer_payment_method(tests.fx('shop_a'), tests.fx('cust_a'), 'pm_x', 'visa', '1111',
                      1, 2030, false, 'cus_Alice01')$$, '42501', 'staff cannot write saved cards');
