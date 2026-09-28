-- 60 money: a coupon's per-line discount eligibility (0062) is frozen once a
-- job's price is settled.
--   * editing a coupon's service list re-stamps only OPEN jobs: not billed,
--     not completed / cancelled / no-show, no money received or in flight
--     on the job (coupons_money_restamp_jobs)
--   * a billed job's lines never change eligibility (job_line_items_60_money)
--   * referential actions never re-derive it: deleting the coupon (jobs
--     keep the discount and the lines it covered) or a line's service
--   * only a writer's own change of a line's service (or re-attaching the
--     coupon) re-stamps a settled, unbilled job
-- Role denials, two-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id in (tests.fx('shop_a'), tests.fx('shop_b'));
insert into public.services (shop_id, name, duration_minutes) values (tests.fx('shop_a'), 'Wax', 30)
  returning tests.fx_set('svc_wax', id);

create function pg_temp.total(p_job uuid) returns bigint language sql security definer as $$
  select total_cents from public.jobs where id = p_job
$$;
grant execute on function pg_temp.total(uuid) to authenticated, service_role;

create function pg_temp.check_coupons() returns void language plpgsql as $$
begin
  set constraints public.jobs_zz_money_coupon_check immediate;
  set constraints public.jobs_zz_money_coupon_check deferred;
end $$;
grant execute on function pg_temp.check_coupons() to authenticated;

-- a job of shop A with Full Detail 200.00 + Wax 100.00 carrying p_coupon
create function pg_temp.coupon_job(p_customer uuid, p_coupon uuid, p_status public.job_status default 'scheduled')
returns uuid language plpgsql as $$
declare
  v_j uuid;
begin
  insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
    values (tests.fx('shop_a'), p_customer, p_status, '2025-05-01 15:00Z', '2025-05-01 17:00Z') returning id into v_j;
  insert into public.job_line_items (shop_id, job_id, service_id, name, unit_price_cents, sort) values
    (tests.fx('shop_a'), v_j, tests.fx('svc_a'), 'Full Detail', 20000, 1),
    (tests.fx('shop_a'), v_j, tests.fx('svc_wax'), 'Wax', 10000, 2);
  update public.jobs set coupon_id = p_coupon where id = v_j;
  perform pg_temp.check_coupons();
  return v_j;
end $$;
grant execute on function pg_temp.coupon_job(uuid, uuid, public.job_status) to authenticated;

-- ============================================================ repro: a completed, paid job keeps its price
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.coupons (shop_id, code, kind, value) values (tests.fx('shop_a'), 'SPRING10', 'percent', 1000)
  returning tests.fx_set('cp', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j_paid', pg_temp.coupon_job(tests.fx('cust_a2'), tests.fx('cp')));
select tests.fx_set('j_open', pg_temp.coupon_job(tests.fx('cust_a2'), tests.fx('cp')));
select tests.eq(pg_temp.total(tests.fx('j_paid')), 27000::bigint, '10% off 300.00');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restamp1', 'succeeded', 27000, 0, 'payment', 'card',
                                    p_job_id => tests.fx('j_paid'));
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'completed' where id = tests.fx('j_paid');
select tests.eq((select balance_cents from public.job_payment_summary(tests.fx('j_paid'))), 0::bigint, 'settled');

-- the owner narrows the coupon to the Wax only for a new campaign
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = array[tests.fx('svc_wax')] where id = tests.fx('cp');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.total(tests.fx('j_paid')), 27000::bigint, 'a completed, paid job keeps the price it was settled at');
select tests.eq((select balance_cents from public.job_payment_summary(tests.fx('j_paid'))), 0::bigint, 'and owes nothing');
select tests.eq((select array_agg(discount_eligible order by sort) from public.job_line_items where job_id = tests.fx('j_paid')),
                array[true, true], 'its lines keep the eligibility they were priced with');
select tests.eq(pg_temp.total(tests.fx('j_open')), 29000::bigint, 'an open job takes the new list (10% of the Wax only)');

-- widening the list: the settled job is not left overpaid either
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = null where id = tests.fx('cp');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.total(tests.fx('j_open')), 27000::bigint, 'widening re-stamps the open job');
select tests.eq(pg_temp.total(tests.fx('j_paid')), 27000::bigint, 'and still leaves the settled one alone');

-- ============================================================ which jobs count as settled
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j_deposit', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));    -- paid a deposit only
select tests.fx_set('j_inflight', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));   -- a card attempt in flight
select tests.fx_set('j_ach', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));        -- an ACH debit clearing
select tests.fx_set('j_failed', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));     -- only a failed attempt
select tests.fx_set('j_refunded', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));   -- paid, then refunded in full
select tests.fx_set('j_cancelled', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));
select tests.fx_set('j_noshow', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));
select tests.fx_set('j_done', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));        -- completed, nothing paid yet
select tests.fx_set('j_progress', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('cp')));    -- in progress, nothing paid
update public.jobs set status = 'cancelled' where id = tests.fx('j_cancelled');
update public.jobs set status = 'no_show' where id = tests.fx('j_noshow');
update public.jobs set status = 'completed' where id = tests.fx('j_done');
update public.jobs set status = 'in_progress' where id = tests.fx('j_progress');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampDep', 'succeeded', 5000, 0, 'deposit', 'card',
                                    p_job_id => tests.fx('j_deposit'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampPend', 'pending', 27000, 0, 'payment', 'card',
                                    p_job_id => tests.fx('j_inflight'));
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampAch', 'processing', 27000, 0, 'payment', 'ach_debit',
                                    p_job_id => tests.fx('j_ach'), p_stripe_method_type => 'us_bank_account');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampFail', 'pending', 27000, 0, 'payment', 'card',
                                    p_job_id => tests.fx('j_failed'), p_checkout_session_id => 'cs_restampFail');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampFail', 'failed', 27000, 0, 'payment', 'card',
                                    p_job_id => tests.fx('j_failed'), p_checkout_session_id => 'cs_restampFail');
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_restampFail'), 'failed',
                'the Checkout attempt failed');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_restampRef', 'succeeded', 27000, 0, 'payment', 'card',
                                    p_job_id => tests.fx('j_refunded'));
select public.apply_stripe_refund('pi_restampRef', 27000);
select tests.eq((select status::text from public.payments where stripe_payment_intent_id = 'pi_restampRef'), 'refunded',
                'the refunded job''s payment is refunded in full');

select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = array[tests.fx('svc_wax')] where id = tests.fx('cp');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select jsonb_object_agg(k, pg_temp.total(tests.fx(k)))
                   from unnest(array['j_deposit', 'j_inflight', 'j_ach', 'j_failed', 'j_refunded', 'j_cancelled',
                                     'j_noshow', 'j_done', 'j_progress', 'j_open', 'j_paid']) k),
                jsonb_build_object('j_deposit', 27000, 'j_inflight', 27000, 'j_ach', 27000, 'j_failed', 29000,
                                   'j_refunded', 27000, 'j_cancelled', 27000, 'j_noshow', 27000, 'j_done', 27000,
                                   'j_progress', 29000, 'j_open', 29000, 'j_paid', 27000),
                'narrowing re-prices only open jobs with no money received or in flight (a failed attempt is no money)');

-- a stale card attempt (pending for over an hour) is no longer in flight: the job is open again
select tests.as_superuser();
update public.payments set created_at = now() - interval '2 hours' where stripe_payment_intent_id = 'pi_restampPend';
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = null where id = tests.fx('cp');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.total(tests.fx('j_inflight')), 27000::bigint, 'widening: the abandoned attempt''s job is re-stamped (all eligible)');
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = array[tests.fx('svc_wax')] where id = tests.fx('cp');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(pg_temp.total(tests.fx('j_inflight')), 29000::bigint, 'and narrowing re-prices it');
select tests.eq(pg_temp.total(tests.fx('j_deposit')), 27000::bigint, 'the deposit-paid job never moved');

-- ============================================================ edits of a settled job's lines
-- (j_paid: priced with both lines eligible; the coupon now lists the Wax only)
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.job_line_items set description = 'Two-step' where job_id = tests.fx('j_paid') and name = 'Full Detail';
select tests.eq(pg_temp.total(tests.fx('j_paid')), 27000::bigint, 'an unrelated line edit keeps the line''s eligibility');
update public.job_line_items set discount_eligible = false where job_id = tests.fx('j_paid');
select tests.eq((select array_agg(discount_eligible order by sort) from public.job_line_items where job_id = tests.fx('j_paid')),
                array[true, true], 'a client cannot write discount_eligible');
update public.job_line_items set service_id = null where job_id = tests.fx('j_paid') and name = 'Full Detail';
select tests.eq(pg_temp.total(tests.fx('j_paid')), 29000::bigint,
                'the writer''s own change of a line''s service re-stamps that line from the coupon''s list');
update public.job_line_items set service_id = tests.fx('svc_a') where job_id = tests.fx('j_paid') and name = 'Full Detail';
select tests.eq(pg_temp.total(tests.fx('j_paid')), 29000::bigint, '(the Full Detail is not on the Wax-only list)');
-- re-attaching the coupon takes its current list (an explicit edit of the job)
update public.jobs set coupon_id = null where id = tests.fx('j_done');
select tests.eq(pg_temp.total(tests.fx('j_done')), 30000::bigint, 'removing the coupon removes the discount');
update public.jobs set coupon_id = tests.fx('cp') where id = tests.fx('j_done');
select pg_temp.check_coupons();
select tests.eq(pg_temp.total(tests.fx('j_done')), 29000::bigint, 'attaching it again prices it with the current list');
-- a server-side re-stamp of an open job is honoured (the coupon-derived value)
select tests.as_superuser();
update public.job_line_items set discount_eligible = true where job_id = tests.fx('j_open');
select tests.eq((select array_agg(discount_eligible order by sort) from public.job_line_items where job_id = tests.fx('j_open')),
                array[false, true], 'server writes on a coupon job still take the coupon''s list');

-- ============================================================ repro: deleting a coupon or a service keeps billed totals
-- A: 10% off the Full Detail only, on job_a (Full Detail 200.00 + an uncovered 100.00 line), billed
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.coupons (shop_id, code, kind, value, service_ids)
  values (tests.fx('shop_a'), 'DETAIL10', 'percent', 1000, array[tests.fx('svc_a')]) returning tests.fx_set('c_detail', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, name, quantity, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a'), 'Pet hair removal', 1, 10000);
update public.jobs set coupon_id = tests.fx('c_detail') where id = tests.fx('job_a');
select tests.fx_set('inv_a', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.as_superuser();
select tests.eq((select jsonb_build_array(j.total_cents, i.total_cents) from public.jobs j, public.invoices i
                  where j.id = tests.fx('job_a') and i.id = tests.fx('inv_a')), '[28000, 28000]'::jsonb, 'billed at 280.00');
-- B: the same kind of coupon on job_a2 (a Full Detail line), billed
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.coupons (shop_id, code, kind, value, service_ids)
  values (tests.fx('shop_a'), 'DETAIL10B', 'percent', 1000, array[tests.fx('svc_a')]) returning tests.fx_set('c_b', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.job_line_items (shop_id, job_id, service_id, name, quantity, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_a2'), tests.fx('svc_a'), 'Full Detail', 1, 20000);
update public.jobs set coupon_id = tests.fx('c_b') where id = tests.fx('job_a2');
select tests.fx_set('inv_a2', (public.create_invoice_from_job(tests.fx('job_a2'))).id);
-- C: unbilled, open jobs with the same kinds of coupon
select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.coupons (shop_id, code, kind, value, service_ids)
  values (tests.fx('shop_a'), 'DETAIL10C', 'percent', 1000, array[tests.fx('svc_a')]) returning tests.fx_set('c_c', id);
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('j_unbilled_c', pg_temp.coupon_job(tests.fx('cust_a2'), tests.fx('c_detail')));   -- deleted coupon
select tests.fx_set('j_unbilled_s', pg_temp.coupon_job(tests.fx('cust_a2'), tests.fx('c_c')));        -- deleted service
select tests.eq(jsonb_build_array(pg_temp.total(tests.fx('j_unbilled_c')), pg_temp.total(tests.fx('j_unbilled_s'))),
                '[28000, 28000]'::jsonb, 'unbilled jobs: 10% of the Full Detail only');
-- D: a grouped (fleet) invoice of two jobs carrying the coupon
select tests.fx_set('j_g1', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('c_c')));
select tests.fx_set('j_g2', pg_temp.coupon_job(tests.fx('cust_a3'), tests.fx('c_c')));
select tests.fx_set('inv_g', (public.create_invoice_from_jobs(tests.fx('cust_a3'), array[tests.fx('j_g1'), tests.fx('j_g2')])).id);
select tests.eq((select total_cents from public.invoices where id = tests.fx('inv_g')), 56000::bigint, 'fleet invoice 2 × 280.00');

-- denials first: a technician and another shop's admin cannot end the promotion
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.coupons where id = tests.fx('c_detail')$$), 0::bigint,
                'a technician cannot delete a coupon');
select tests.eq(tests.row_count($$update public.coupons set service_ids = null where id = tests.fx('c_c')$$), 0::bigint,
                'nor edit its service list');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.coupons set service_ids = null where id = tests.fx('c_c')$$), 0::bigint,
                'managers cannot edit coupons (admin+)');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$delete from public.coupons where id = tests.fx('c_detail')$$), 0::bigint,
                'another shop''s admin cannot delete it');
select tests.eq(tests.row_count($$update public.coupons set service_ids = null where id = tests.fx('c_c')$$), 0::bigint,
                'nor edit it');
select tests.eq(tests.row_count($$delete from public.services where id = tests.fx('svc_a')$$), 0::bigint,
                'nor delete shop A''s service');
select tests.as_superuser();
select tests.ok((select service_ids = array[tests.fx('svc_a')] from public.coupons where id = tests.fx('c_c')), 'the list is unchanged');

-- the admin ends the DETAIL10 promotion (deletes the coupon) and retires the Full Detail service
select tests.authenticate_as(tests.fx('u_admin_a'));
delete from public.coupons where id = tests.fx('c_detail');
select tests.as_superuser();
select tests.eq(jsonb_build_array(pg_temp.total(tests.fx('job_a')), pg_temp.total(tests.fx('j_unbilled_c'))),
                '[28000, 28000]'::jsonb, 'deleting the coupon keeps the discount on the lines it covered (billed and unbilled)');
select tests.ok((select coupon_id is null and discount_kind = 'percent' and discount_value = 1000 from public.jobs where id = tests.fx('j_unbilled_c')),
                'the unbilled job keeps the discount without the coupon');
select tests.authenticate_as(tests.fx('u_admin_a'));
delete from public.services where id = tests.fx('svc_a');
select tests.as_superuser();
select tests.eq((select jsonb_agg(jsonb_build_array(j.total_cents, i.total_cents) order by j.number)
                   from public.jobs j join public.invoices i on i.job_id = j.id
                  where j.id in (tests.fx('job_a'), tests.fx('job_a2'))),
                '[[28000, 28000], [18000, 18000]]'::jsonb,
                'billed jobs keep the coupon discount they were invoiced with');
select tests.eq((select jsonb_agg(total_cents order by number) from public.jobs where id in (tests.fx('j_g1'), tests.fx('j_g2'))),
                '[28000, 28000]'::jsonb, 'so do the jobs of the grouped invoice');
select tests.eq((select sum(j.total_cents) from public.jobs j where j.id in (tests.fx('j_g1'), tests.fx('j_g2'))),
                (select total_cents from public.invoices where id = tests.fx('inv_g')), 'which still add up to the invoice');
select tests.eq(pg_temp.total(tests.fx('j_unbilled_s')), 28000::bigint,
                'an unbilled job keeps the eligibility of a line whose service was deleted');
select tests.ok((select bool_and(service_id is null) from public.job_line_items where job_id = tests.fx('j_unbilled_s') and name = 'Full Detail'),
                '(the service link itself is cleared)');
-- every shop-A job's totals still equal compute_document_totals over its lines
select tests.eq((select count(*) from public.jobs j
                  cross join lateral public.compute_document_totals(
                    (select coalesce(jsonb_agg(jsonb_build_object('quantity', li.quantity, 'unit_price_cents', li.unit_price_cents,
                                                                  'discount_cents', li.discount_cents, 'taxable', li.taxable,
                                                                  'discount_eligible', li.discount_eligible)), '[]')
                       from public.job_line_items li where li.job_id = j.id),
                    j.discount_kind, j.discount_value, j.tax_rate_bps) r
                  where j.shop_id = tests.fx('shop_a') and r.total_cents <> j.total_cents),
                0::bigint, 'every job''s stored total matches its lines');

-- a billed job's lines are frozen even for server-side writes
update public.job_line_items set discount_eligible = not discount_eligible where job_id = tests.fx('job_a2');
select tests.eq(pg_temp.total(tests.fx('job_a2')), 18000::bigint, 'a billed job''s eligibility cannot be rewritten');
-- coupon list edits skip billed jobs (grouped included)
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.coupons set service_ids = null where id = tests.fx('c_c');
select tests.as_superuser();
select tests.eq(jsonb_build_object('g1', pg_temp.total(tests.fx('j_g1')), 'g2', pg_temp.total(tests.fx('j_g2')),
                                   'open', pg_temp.total(tests.fx('j_unbilled_s'))),
                '{"g1": 28000, "g2": 28000, "open": 27000}'::jsonb, 'widening re-stamps the open job only, never the grouped-billed ones');

-- voiding the invoice unfreezes the job: its coupon's current list applies again
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.void_invoice(tests.fx('inv_g'), 'Re-billing');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set coupon_id = null where id = tests.fx('j_g1');
update public.jobs set coupon_id = tests.fx('c_c') where id = tests.fx('j_g1');
select pg_temp.check_coupons();
select tests.eq(pg_temp.total(tests.fx('j_g1')), 27000::bigint, 'after the void, re-attaching prices with the current (widened) list');

-- ============================================================ isolation: shop B untouched
select tests.as_superuser();
select tests.eq(pg_temp.total(tests.fx('job_b')), 5000::bigint, 'shop B''s job is unchanged');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq((select count(*) from public.job_line_items where shop_id = tests.fx('shop_a')), 0::bigint,
                'shop B cannot see shop A''s lines');

-- the trigger functions are not RPCs
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.coupons_money_restamp_jobs()$$, null, 'the restamp trigger function is not callable');
select tests.throws($$select public.jobs_money_coupon_lines()$$, null, 'nor the job coupon trigger function');
