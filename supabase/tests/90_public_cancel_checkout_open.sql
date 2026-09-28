-- 90 hardening (0106): the customer's own cancel (public_cancel_booking)
-- waits while a Checkout Session of the booking can still be paid.
-- Regression: 0096 only saw payment rows, and an open Checkout Session that
-- is not yet submitted has none. A customer who opened "Pay deposit",
-- cancelled in another tab and then finished the still-open Stripe page
-- (payable for 32-42 minutes) paid a deposit on the cancelled job.
--   * the payments edge records each session it opens for a job
--     (payments_hold_job_checkout) before handing out its URL; a job closed
--     meanwhile refuses it (55000 HINT booking_closed)
--   * while a hold has not expired the cancel answers 55000 HINT
--     checkout_open and changes nothing; an expired hold, one the edge
--     released (payments_release_job_checkouts) or one whose session
--     completed (a processing / received payment row) no longer blocks it
--   * the holds and the RPCs are service_role only
-- (Called as the service role: public callers always get the server clock,
-- and these bookings are in 2025.)
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled) values (tests.fx('shop_a'), 'acct_A1', true);
update public.booking_settings set require_deposit = true, deposit_type = 'percent', deposit_value = 2500
 where shop_id = tests.fx('shop_a');

create function pg_temp.book(p_n integer) returns uuid language sql as $$
  select (public.create_online_booking('shop-a',
            jsonb_set(jsonb_set(pg_temp.booking(), '{customer,email}', to_jsonb('guest' || p_n || '@example.com')),
                      '{starts_at}', to_jsonb('2025-06-' || (10 + p_n)::text || 'T15:00:00Z')),
            '2025-06-01 12:00Z') ->> 'job_token')::uuid $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  declare v_hint text;
  begin
    get stacked diagnostics v_hint = pg_exception_hint;
    return sqlstate || coalesce(':' || nullif(v_hint, ''), '');
  end;
end $$;
create function pg_temp.job(p_tok uuid) returns public.jobs language sql as $$
  select * from public.jobs where public_token = p_tok $$;
create function pg_temp.cancel(p_tok uuid) returns text language sql as $$
  select pg_temp.err(format('select public.public_cancel_booking(%L, %L, %L)', p_tok, 'changed plans', '2025-06-01 12:05Z')) $$;
grant execute on function pg_temp.book(integer), pg_temp.err(text), pg_temp.job(uuid), pg_temp.cancel(uuid)
  to anon, authenticated, service_role;

select tests.as_service();
select tests.fx_set('tok4', pg_temp.book(4));
select tests.fx_set('tok5', pg_temp.book(5));
select tests.fx_set('tok6', pg_temp.book(6));
select tests.as_superuser();
select tests.fx_set('job4', (pg_temp.job(tests.fx('tok4'))).id);
select tests.fx_set('job5', (pg_temp.job(tests.fx('tok5'))).id);
select tests.fx_set('job6', (pg_temp.job(tests.fx('tok6'))).id);

-- ============================================================ the reported sequence: Pay deposit, then cancel
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job4'), 'cs_test_open4', now() + interval '32 minutes');
select tests.eq(pg_temp.cancel(tests.fx('tok4')), '55000:checkout_open',
                'the customer cannot cancel while the deposit page can still be paid');
select tests.throws_like(format('select public.public_cancel_booking(%L, null, %L)', tests.fx('tok4'), '2025-06-01 12:05Z'),
                         '55000', 'a payment page for this booking is still open; please close it and try again in a few minutes, or call the shop',
                         'a sentence the page shows as is');
select tests.as_superuser();
select tests.eq((pg_temp.job(tests.fx('tok4'))).status::text, 'requested', 'the booking is unchanged');
select tests.eq((select count(*) from public.notifications where kind = 'booking_cancelled' and job_id = tests.fx('job4')), 0::bigint,
                'and nobody was told it was cancelled');
-- Stripe expired the session: the hold no longer blocks (wall clock)
update public.job_checkout_holds set expires_at = now() - interval '1 second' where stripe_checkout_session_id = 'cs_test_open4';
select tests.as_service();
select tests.eq(pg_temp.cancel(tests.fx('tok4')), 'no error', 'an expired session no longer blocks the cancel');
select tests.as_superuser();
select tests.eq((pg_temp.job(tests.fx('tok4'))).status::text, 'cancelled', 'cancelled');

-- ============================================================ a closed job takes no new hold
select tests.as_service();
select tests.eq(pg_temp.err(format('select public.payments_hold_job_checkout(%L, %L, %L, %L)', tests.fx('shop_a'), tests.fx('job4'),
                                   'cs_test_late4', now() + interval '30 minutes')),
                '55000:booking_closed', 'a session opened as the job was cancelled is refused (the edge expires it)');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_late4'), 0::bigint,
                'and not recorded');

-- ============================================================ the edge expired and released the sessions
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job5'), 'cs_test_open5a', now() + interval '32 minutes');
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job5'), 'cs_test_open5b', now() + interval '40 minutes');
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job5'), 'cs_test_open5b', now() + interval '35 minutes');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_checkout_holds where job_id = tests.fx('job5')), 2::bigint,
                'one hold per session (a repeated hold is idempotent)');
select tests.eq((select expires_at from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_open5b'),
                now() + interval '40 minutes', 'and never shortens it');
select tests.as_service();
select tests.eq(pg_temp.err(format('select public.payments_hold_job_checkout(%L, %L, %L, %L)', tests.fx('shop_a'), tests.fx('job6'),
                                   'cs_test_open5b', now() + interval '30 minutes')),
                '22023', 'a session held for one job cannot be moved to another');
select tests.eq(pg_temp.cancel(tests.fx('tok5')), '55000:checkout_open', 'two open pages: refused');
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job5'), array['cs_test_open5a']), 1,
                'the edge releases one session it expired');
select tests.eq(pg_temp.cancel(tests.fx('tok5')), '55000:checkout_open', 'the other one still blocks');
select tests.eq(public.payments_release_job_checkouts(tests.fx('shop_a'), tests.fx('job5')), 1, 'or all of the job''s');
select tests.eq(pg_temp.cancel(tests.fx('tok5')), 'no error', 'released: the cancel works');

-- ============================================================ a completed session releases its hold
select tests.as_service();
select public.payments_hold_job_checkout(tests.fx('shop_a'), tests.fx('job6'), 'cs_test_open6', now() + interval '32 minutes');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep6', 'pending', 5500, 0, 'deposit', 'card', null, tests.fx('job6'),
                                    p_checkout_session_id => 'cs_test_open6');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_open6'), 1::bigint,
                'a card attempt still pending keeps the session payable (and held)');
select tests.as_service();
select tests.eq(pg_temp.cancel(tests.fx('tok6')), '55000:payment_in_progress', 'and the cancel waits');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep6', 'succeeded', 5500, 0, 'deposit', 'card',
                                    null, tests.fx('job6'), null, null, 'ch_6', 'cs_test_open6', 'visa', '4242', '2025-06-01 12:06Z');
select tests.as_superuser();
select tests.eq((select count(*) from public.job_checkout_holds where stripe_checkout_session_id = 'cs_test_open6'), 0::bigint,
                'the paid session released its hold');
select tests.as_service();
select tests.eq(pg_temp.cancel(tests.fx('tok6')), 'no error', 'the deposit is paid: the customer may cancel as before');

-- ============================================================ argument checks
select tests.as_service();
select tests.throws(format('select public.payments_hold_job_checkout(%L, %L, %L, %L)', tests.fx('shop_a'), tests.fx('job6'),
                           'pi_not_a_session', now()), '22023', 'only Checkout Session ids');
select tests.throws(format('select public.payments_hold_job_checkout(%L, %L, %L, null)', tests.fx('shop_a'), tests.fx('job6'),
                           'cs_test_x'), '22023', 'an expiry is required');
select tests.throws(format('select public.payments_hold_job_checkout(%L, %L, %L, %L)', tests.fx('shop_b'), tests.fx('job6'),
                           'cs_test_x', now()), 'P0002', 'the job must be the shop''s');
select tests.throws('select public.payments_release_job_checkouts(null, null)', '22023', 'release needs the shop and job');

-- ============================================================ service_role only
select tests.as_anon();
select tests.throws($$select count(*) from public.job_checkout_holds$$, '42501', 'anon cannot read the holds');
select tests.throws(format('select public.payments_release_job_checkouts(%L, %L)', tests.fx('shop_a'), tests.fx('job6')), '42501',
                    'or release them');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select count(*) from public.job_checkout_holds$$, '42501', 'nor can the shop''s owner read them');
select tests.throws($$delete from public.job_checkout_holds$$, '42501', 'or clear them to cancel anyway');
select tests.throws(format('select public.payments_hold_job_checkout(%L, %L, %L, %L)', tests.fx('shop_a'), tests.fx('job6'),
                           'cs_test_x', now() + interval '1 hour'), '42501', 'or place one to block a customer''s cancel');
