-- 60 money: recurring-series occurrences (sched 0051) carry the same money
-- rules as one-off jobs.
--   * auto-applied fees (0068): every occurrence gets the fee matching its
--     location type, also the ones the nightly generator adds; re-pricing an
--     occurrence ("this and following" template change) keeps its fee lines,
--     a hand-added fee included; a series location change swaps the
--     auto-applied fee.
--   * sales commission (0065): every occurrence is credited to the series
--     creator's membership — the first batch, the generator's (no
--     auth.uid()) and occurrences re-created by another manager's edit —
--     and report_member_earnings credits the seller for each visit.
-- Two-shop isolation and the one-off defaults stay as they were.
\ir fixtures/two_shops.psql

create function pg_temp.fee_lines(p_series uuid, p_fee uuid) returns bigint language sql as $$
  select count(*) from public.jobs j join public.job_line_items li on li.job_id = j.id and li.fee_id = p_fee
   where j.series_id = p_series
$$;
create function pg_temp.occ(p_series uuid) returns bigint language sql as $$
  select count(*) from public.jobs j where j.series_id = p_series
$$;
grant execute on function pg_temp.fee_lines(uuid, uuid), pg_temp.occ(uuid) to authenticated, service_role;

select tests.as_superuser();
insert into public.shop_fees (shop_id, name, amount_cents, taxable, auto_apply, sort)
  values (tests.fx('shop_a'), 'Travel', 2500, false, 'mobile', 1) returning tests.fx_set('fee', id);
insert into public.shop_fees (shop_id, name, amount_cents, taxable, auto_apply, sort)
  values (tests.fx('shop_a'), 'Shop supplies', 500, true, 'shop', 2) returning tests.fx_set('fee_shop', id);
insert into public.shop_fees (shop_id, name, amount_cents)
  values (tests.fx('shop_a'), 'Pet hair', 3000) returning tests.fx_set('fee_hand', id);
insert into public.shop_fees (shop_id, name, amount_cents, auto_apply)
  values (tests.fx('shop_b'), 'B travel', 1000, 'mobile') returning tests.fx_set('fee_b', id);
insert into public.service_prices (shop_id, service_id, vehicle_category_id, price_cents)
  values (tests.fx('shop_b'), tests.fx('svc_b'), null, 6000);
insert into public.member_compensation (shop_id, member_id, sales_commission_bps)
  values (tests.fx('shop_a'), tests.fx('m_manager_a'), 1000)
  on conflict (member_id) do update set sales_commission_bps = excluded.sales_commission_bps;

-- ============================================================ fees: one-off vs series
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, location_type, service_address_line1, service_city, service_postal_code,
                         scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'mobile', '1 Main St', 'Austin', '78701',
          now() + interval '3 days', now() + interval '3 days 2 hours') returning tests.fx_set('one_off', id);
select tests.eq((select count(*) from public.job_line_items where job_id = tests.fx('one_off') and fee_id = tests.fx('fee')),
                1::bigint, 'a one-off mobile job carries the auto-applied travel fee');
select tests.eq((select sold_by_member_id from public.jobs where id = tests.fx('one_off')), tests.fx('m_manager_a'),
                'a staff job is still credited to the member creating it');

select (public.create_job_series(tests.fx('shop_a'), jsonb_build_object(
          'customer_id', tests.fx('cust_a'), 'vehicle_id', tests.fx('veh_a'), 'freq', 'week', 'local_start', '09:00',
          'start_date', ((now() at time zone 'America/Chicago')::date + 7)::text,
          'location_type', 'mobile', 'service_address_line1', '1 Main St', 'service_city', 'Austin',
          'service_postal_code', '78701',
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'))))) ->> 'series_id')::uuid
  as ser \gset
select tests.as_superuser();
select count(*) as first_batch from public.jobs where series_id = :'ser'::uuid \gset
select tests.ok(:first_batch > 0, 'occurrences generated');
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee')), :first_batch::bigint,
                'every mobile occurrence carries the auto-applied travel fee');
select tests.eq((select count(*) from public.jobs j where j.series_id = :'ser'::uuid
                   and j.subtotal_cents <> 2500 + (select sum(li.total_cents) from public.job_line_items li
                                                    where li.job_id = j.id and li.fee_id is null)), 0::bigint,
                'the fee counts in each occurrence''s totals');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = :'ser'::uuid and li.fee_id is not null and li.fee_id <> tests.fx('fee')), 0::bigint,
                'no fee of the other location type');
select tests.eq((select count(*) from public.jobs where series_id = :'ser'::uuid and sold_by_member_id = tests.fx('m_manager_a')),
                :first_batch::bigint, 'first batch credited to the series creator');

-- the nightly generator (service_role, no auth.uid())
select tests.as_service();
select public.generate_series_jobs(now() + interval '120 days');
select tests.as_superuser();
select pg_temp.occ(:'ser') as after_gen \gset
select tests.ok(:after_gen > :first_batch, 'the generator added occurrences');
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee')), :after_gen::bigint, 'generated occurrences carry the fee too');
select tests.eq((select count(*) from public.jobs where series_id = :'ser'::uuid
                   and sold_by_member_id is distinct from tests.fx('m_manager_a')), 0::bigint,
                'occurrences added by the generator are credited to the same seller');

-- a fee added by hand to one upcoming occurrence (add_fee_line does not
-- detach it) survives a later "this and following" re-price
select id as occ2 from public.jobs where series_id = :'ser'::uuid order by series_seq offset 1 limit 1 \gset
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives(format($$select public.add_fee_line('job', %L, tests.fx('fee_hand'))$$, :'occ2'), 'fee added by hand');
select tests.as_superuser();
select tests.eq((select series_detached from public.jobs where id = :'occ2'::uuid), false, 'the occurrence stays in the series');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives(format($$select public.update_job_series(%L, jsonb_build_object('template_lines',
                     jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_a'), 'quantity', 2))))$$, :'ser'),
                   'another manager re-prices the series (quantity 2)');
select tests.as_superuser();
select tests.eq((select count(*) from public.jobs j where j.series_id = :'ser'::uuid and j.status = 'scheduled'
                   and not exists (select 1 from public.job_line_items li where li.job_id = j.id and li.service_id = tests.fx('svc_a')
                                                                          and li.quantity = 2)), 0::bigint,
                'the service lines were re-priced');
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee')), pg_temp.occ(:'ser'), 'the re-price keeps the travel fee on every occurrence');
select tests.eq((select count(*) from public.job_line_items where job_id = :'occ2'::uuid and fee_id = tests.fx('fee_hand')), 1::bigint,
                'and the hand-added fee');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = :'ser'::uuid and li.fee_id = tests.fx('fee_hand')), 1::bigint,
                'which stays on that visit only');

-- a location change re-created through the series swaps the auto fee
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives(format($$select public.update_job_series(%L, '{"location_type": "shop"}')$$, :'ser'),
                   'the series moves in-shop');
select tests.as_superuser();
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee')), 0::bigint, 'no travel fee on in-shop occurrences');
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee_shop')), pg_temp.occ(:'ser'), 'each carries the in-shop fee instead');
select tests.eq((select count(*) from public.job_line_items where job_id = :'occ2'::uuid and fee_id = tests.fx('fee_hand')), 1::bigint,
                'a hand-added (non auto) fee is kept');

-- a rule change re-creates occurrences as the editing admin: still the creator's sale
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives(format($$select public.update_job_series(%L, '{"freq": "week", "interval": 2}')$$, :'ser'),
                   'rule change by another manager');
select tests.as_superuser();
select tests.ok(exists (select 1 from public.jobs where series_id = :'ser'::uuid and created_at = now()), 'occurrences were written');
select tests.eq((select count(*) from public.jobs where series_id = :'ser'::uuid
                   and sold_by_member_id is distinct from tests.fx('m_manager_a')), 0::bigint,
                'occurrences written by another manager''s edit keep the creator as the seller');
select tests.eq(pg_temp.fee_lines(:'ser', tests.fx('fee_shop')), pg_temp.occ(:'ser'), 'and every occurrence its fee');

-- ============================================================ sales commission per visit
-- complete two occurrences: each earns the seller 10% of its pre-tax revenue
select tests.as_superuser();
select array_agg(id order by series_seq)::text as two
  from (select id, series_seq from public.jobs where series_id = :'ser'::uuid order by series_seq limit 2) x \gset
update public.jobs set status = 'completed' where id = any (:'two'::uuid[]);
select sum(round((subtotal_cents - discount_cents) * 0.1))::bigint as sold_comm
  from public.jobs where id = any (:'two'::uuid[]) \gset
select tests.ok(:sold_comm > 0, 'the completed visits have revenue');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select sum(sales_commission_cents) from public.report_member_earnings(
                   tests.fx('shop_a'), tests.fx('m_manager_a'),
                   (now() at time zone 'America/Chicago')::date, (now() at time zone 'America/Chicago')::date)
                  where job_id = any (:'two'::uuid[]))::bigint, :sold_comm::bigint,
                'the seller earns sales commission on every completed visit of the series');

-- ============================================================ shop B: isolation, creator gone
select tests.authenticate_as(tests.fx('u_manager_b'));
select (public.create_job_series(tests.fx('shop_b'), jsonb_build_object(
          'customer_id', tests.fx('cust_b'), 'vehicle_id', tests.fx('veh_b'), 'freq', 'week', 'local_start', '10:00',
          'start_date', ((now() at time zone 'America/Chicago')::date + 2)::text,
          'location_type', 'mobile', 'service_address_line1', '9 Oak St', 'service_city', 'Austin',
          'service_postal_code', '78702',
          'template_lines', jsonb_build_array(jsonb_build_object('service_id', tests.fx('svc_b'))))) ->> 'series_id')::uuid
  as ser_b \gset
select tests.as_superuser();
select tests.eq(pg_temp.fee_lines(:'ser_b', tests.fx('fee_b')), pg_temp.occ(:'ser_b'), 'shop B occurrences carry shop B''s fee');
select tests.eq((select count(*) from public.job_line_items li join public.jobs j on j.id = li.job_id
                  where j.series_id = :'ser_b'::uuid and li.fee_id in (tests.fx('fee'), tests.fx('fee_shop'), tests.fx('fee_hand'))),
                0::bigint, 'and none of shop A''s');
select tests.eq((select count(*) from public.jobs where series_id = :'ser_b'::uuid
                   and sold_by_member_id is distinct from tests.fx('m_manager_b')), 0::bigint,
                'shop B''s series is credited to its own creator');
select pg_temp.occ(:'ser_b') as b_first \gset
-- the creator's account is gone (job_series.created_by ON DELETE SET NULL):
-- later visits are nobody's sale, never the generator's or an editor's
update public.job_series set created_by = null where id = :'ser_b'::uuid;
select tests.as_service();
select public.generate_series_jobs(now() + interval '150 days');
select tests.as_superuser();
select tests.ok(pg_temp.occ(:'ser_b') > :b_first, 'the generator extended shop B''s series');
select tests.eq((select count(*) from public.jobs where series_id = :'ser_b'::uuid and sold_by_member_id is not null), :b_first::bigint,
                'occurrences generated after the creator left are credited to no one');
select tests.eq(pg_temp.fee_lines(:'ser_b', tests.fx('fee_b')), pg_temp.occ(:'ser_b'), 'and still carry the fee');
