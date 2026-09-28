-- 90 hardening (0096): the customer's own cancel (public_cancel_booking)
-- waits while a payment of the booking is still going through — a deposit
-- card attempt still pending, an ACH deposit still processing — so the
-- deposit can never land on a job the customer just cancelled. It answers
-- 55000 HINT payment_in_progress and changes nothing; once the payment
-- settles (or the attempt is released) the cancel works as before.
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
grant execute on function pg_temp.book(integer), pg_temp.err(text), pg_temp.job(uuid) to service_role;

select tests.as_service();
select tests.fx_set('tok1', pg_temp.book(1));
select tests.fx_set('tok2', pg_temp.book(2));
select tests.fx_set('tok3', pg_temp.book(3));
select tests.as_superuser();
select tests.fx_set('job1', (pg_temp.job(tests.fx('tok1'))).id);
select tests.fx_set('job2', (pg_temp.job(tests.fx('tok2'))).id);
select tests.fx_set('job3', (pg_temp.job(tests.fx('tok3'))).id);

-- ============================================================ a card deposit still pending
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'pending', 5500, 0, 'deposit', 'card', null, tests.fx('job1'));
select tests.as_service();
select tests.eq(public.public_get_booking(tests.fx('tok1'), '2025-06-01 12:05Z') #>> '{deposit,payment_pending}', 'true',
                'the page shows the deposit on its way');
select tests.eq(pg_temp.err(format('select public.public_cancel_booking(%L, %L, %L)', tests.fx('tok1'), 'changed plans',
                                   '2025-06-01 12:05Z')),
                '55000:payment_in_progress', 'the customer cannot cancel while it is going through');
select tests.throws_like(format('select public.public_cancel_booking(%L, null, %L)', tests.fx('tok1'), '2025-06-01 12:05Z'),
                         '55000', 'a payment for this booking is still going through; please try again once it has finished, or call the shop',
                         'a sentence the page shows as is');
select tests.as_superuser();
select tests.eq((pg_temp.job(tests.fx('tok1'))).status::text, 'requested', 'the booking is unchanged');
select tests.eq((select count(*) from public.notifications where kind = 'booking_cancelled' and job_id = tests.fx('job1')), 0::bigint,
                'and nobody was told it was cancelled');
-- it succeeds: the deposit is paid, and the customer may cancel as before
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep1', 'succeeded', 5500, 0, 'deposit', 'card',
                                    null, tests.fx('job1'), null, null, 'ch_1', null, 'visa', '4242', '2025-06-01 12:06Z');
select tests.as_service();
select tests.eq(public.public_cancel_booking(tests.fx('tok1'), 'changed plans', '2025-06-01 12:10Z') #>> '{booking,status}', 'cancelled',
                'once the payment settled the cancel works (deposits are not refunded automatically)');

-- ============================================================ a released attempt stops blocking (a declined one stays pending: it can be retried)
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep2', 'pending', 5500, 0, 'deposit', 'card', null, tests.fx('job2'));
select tests.as_service();
select tests.throws($$select public.public_cancel_booking(tests.fx('tok2'), null, '2025-06-01 12:05Z')$$, '55000', 'pending: refused');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_dep2', 'cancelled', 5500, 0, 'deposit', 'card', null, tests.fx('job2'));
select tests.as_service();
select tests.eq(public.public_cancel_booking(tests.fx('tok2'), null, '2025-06-01 12:10Z') #>> '{booking,status}', 'cancelled',
                'a released attempt (cancelled by the shop or the stale-attempt sweep) no longer blocks it');

-- ============================================================ an ACH deposit still clearing (P-31)
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach3', 'processing', 5500, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job3'), p_stripe_method_type => 'us_bank_account');
select tests.as_service();
select tests.eq(pg_temp.err(format('select public.public_cancel_booking(%L, null, %L)', tests.fx('tok3'), '2025-06-03 12:00Z')),
                '55000:payment_in_progress', 'an ACH deposit clearing for days blocks it too');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_ach3', 'succeeded', 5500, 0, 'deposit', 'ach_debit',
                                    null, tests.fx('job3'), p_paid_at => '2025-06-04 12:00Z', p_stripe_method_type => 'us_bank_account');
select tests.as_service();
select tests.eq(public.public_cancel_booking(tests.fx('tok3'), null, '2025-06-04 13:00Z') #>> '{booking,status}', 'cancelled',
                'cleared: the cancel works');

-- every booking ended cancelled once its payment had settled
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs where id in (tests.fx('job1'), tests.fx('job2'), tests.fx('job3'))
                   and status = 'cancelled'), 3::bigint, 'each booking cancelled exactly once it was allowed');
