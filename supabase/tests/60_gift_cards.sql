-- 60 money: gift cards and store credit (P-13b, 0066) — issuing (code
-- returned once, only its hash stored, delivery message, recipient
-- customers, expiry), lookup / redeem / partial / refusals, store credit,
-- refunds credited back, adjust / void, the public /i redemption with its
-- brute-force limits, online orders (prepare / paid / refunded / status),
-- report_gift_cards, RLS / privileges / isolation and shop deletion.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id in (tests.fx('shop_a'), tests.fx('shop_b'));
-- wording for the delivery email (comms 0083 seeds a default; this file uses its own)
insert into public.message_templates (shop_id, key, channel, subject, body)
values (tests.fx('shop_a'), 'gift_card_delivery', 'email', 'A gift card from {{sender_name}}',
        'Hi {{recipient_name}}, {{sender_name}} sent you {{gift_card_amount}}: code {{gift_card_code}}. {{gift_message}}')
on conflict (shop_id, key, channel) do update set subject = excluded.subject, body = excluded.body, enabled = true;

create function pg_temp.bal(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, balance_cents) from public.gift_cards where id = p_id
$$;
create function pg_temp.inv(p_id uuid) returns text language sql as $$
  select concat_ws('/', status, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;
grant execute on function pg_temp.bal(uuid), pg_temp.inv(uuid) to authenticated, anon, service_role;

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv1', (public.create_invoice(tests.fx('cust_a'), '[{"name":"Detail","unit_price_cents":10000}]')).id);
select public.mark_invoice_sent(tests.fx('inv1'));
select tests.fx_set('inv2', (public.create_invoice(tests.fx('cust_a2'), '[{"name":"Wash","unit_price_cents":7000}]')).id);
select public.mark_invoice_sent(tests.fx('inv2'));

-- ============================================================ issue_gift_card
select public.issue_gift_card(tests.fx('shop_a'), 5000,
                              '{"name":"Rita","email":"Rita@Example.com","message":"Happy birthday!","sender_name":"Sam"}',
                              4500, 'gift', null, true) as g1 \gset
select tests.fx_set('g1', (:'g1'::jsonb ->> 'gift_card_id')::uuid);
select tests.ok((:'g1'::jsonb ->> 'code') ~ '^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$',
                'a 16-character Crockford code shown as XXXX-XXXX-XXXX-XXXX');
select tests.eq(:'g1'::jsonb ->> 'last4', right(replace(:'g1'::jsonb ->> 'code', '-', ''), 4), 'last4');
select tests.eq((:'g1'::jsonb -> 'balance_cents')::bigint, 5000::bigint, 'balance');
select tests.eq(:'g1'::jsonb -> 'delivery_queued', 'true'::jsonb, 'delivery email queued');
select tests.as_superuser();
select tests.eq((select code_hash from public.gift_cards where id = tests.fx('g1')),
                public.gift_card_code_hash(tests.fx('shop_a'), :'g1'::jsonb ->> 'code'), 'only the shop-bound hash is stored');
select tests.ok((select row_to_json(g)::text not like '%' || replace(:'g1'::jsonb ->> 'code', '-', '') || '%'
                        and row_to_json(g)::text not like '%' || (:'g1'::jsonb ->> 'code') || '%'
                 from public.gift_cards g where g.id = tests.fx('g1')), 'the code itself is never stored on the card');
select tests.ok((select bool_and(row_to_json(t)::text not like '%' || replace(:'g1'::jsonb ->> 'code', '-', '') || '%')
                 from public.gift_card_transactions t where t.gift_card_id = tests.fx('g1')), 'nor in its ledger');
select tests.ok((select kind = 'gift' and initial_cents = 5000 and sold_price_cents = 4500 and issued_via = 'staff' and status = 'active'
                        and recipient_name = 'Rita' and recipient_email = 'rita@example.com' and message = 'Happy birthday!'
                        and issued_by = tests.fx('u_manager_a') and expires_at is null
                 from public.gift_cards where id = tests.fx('g1')), 'card row');
select tests.ok((select c.lifecycle = 'lead' and c.source = 'staff' and c.first_name = 'Rita' and not c.sms_opt_in and not c.email_opt_in
                 from public.gift_cards g join public.customers c on c.id = g.owner_customer_id where g.id = tests.fx('g1')),
                'the recipient became a lead (no consent) and the card''s owner');
select tests.eq((select concat_ws('/', kind, amount_cents, balance_after_cents, created_by = tests.fx('u_manager_a'))
                   from public.gift_card_transactions where gift_card_id = tests.fx('g1')), 'issue/5000/5000/t', 'issue transaction');
select tests.eq((select concat_ws('|', m.to_address, m.subject, m.template_key)
                   from public.messages m join public.gift_cards g on g.owner_customer_id = m.customer_id
                  where g.id = tests.fx('g1')),
                'rita@example.com|A gift card from Sam|gift_card_delivery', 'delivery email to the recipient');
select tests.ok((select m.body like '%' || (:'g1'::jsonb ->> 'code') || '%' and m.body like '%$50.00%' and m.body like '%Happy birthday!%'
                 from public.messages m join public.gift_cards g on g.owner_customer_id = m.customer_id where g.id = tests.fx('g1')),
                'the message carries the code, amount and note (managers can read it; accepted trade-off)');
-- an existing customer is matched by email and never modified
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('g_alice', (public.issue_gift_card(tests.fx('shop_a'), 2000, '{"name":"Someone Else","email":"ALICE@example.com"}', null, 'gift', null, true) ->> 'gift_card_id')::uuid);
select tests.as_superuser();
select tests.ok((select g.owner_customer_id = tests.fx('cust_a') and c.first_name = 'Alice'
                 from public.gift_cards g join public.customers c on c.id = g.owner_customer_id where g.id = tests.fx('g_alice')),
                'an existing customer with that email is matched and kept as is');
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_a') and lower(email::text) = 'alice@example.com'),
                1::bigint, 'no duplicate customer');
-- a card without delivery: no customer, no message
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.issue_gift_card(tests.fx('shop_a'), 8000) as g2 \gset
select tests.fx_set('g2', (:'g2'::jsonb ->> 'gift_card_id')::uuid);
select tests.eq(:'g2'::jsonb -> 'delivery_queued', 'false'::jsonb, 'not sent');
-- store credit
select tests.throws_like($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{}', null, 'credit')$$, '22023', '%customer it belongs to%',
                         'store credit needs its customer');
select public.issue_gift_card(tests.fx('shop_a'), 3000, '{}', null, 'credit', tests.fx('cust_a')) as cr \gset
select tests.fx_set('credit_a', (:'cr'::jsonb ->> 'gift_card_id')::uuid);
-- validation / roles
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 0)$$, '22023', 'amount > 0');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000001)$$, '22023', 'amount capped');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{}', 2000)$$, '22023', 'sold price <= value');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{"nickname":"x"}')$$, '22023', 'unknown recipient keys');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{"email":"not-an-email"}')$$, '22023', 'invalid email');
select tests.throws_like($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{}', null, 'gift', null, true)$$, '22023',
                         '%recipient email%', 'sending needs an email');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{}', null, 'voucher')$$, '22023', 'kind gift or credit');
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000, '{}', null, 'credit', tests.fx('cust_b'))$$, 'P0002',
                    'another shop''s customer: not found');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000)$$, '42501', 'technicians cannot issue');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.issue_gift_card(tests.fx('shop_a'), 1000)$$, '42501', 'another shop''s manager cannot issue');
-- expiry follows the shop's setting (gift cards only; >= 60 months)
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.gift_card_settings set expires_months = 12 where shop_id = tests.fx('shop_a')$$, '23514',
                    'no expiry shorter than 5 years');
update public.gift_card_settings set expires_months = 60 where shop_id = tests.fx('shop_a');
select public.issue_gift_card(tests.fx('shop_a'), 1000) as gx \gset
select tests.eq((select expires_at from public.gift_cards where id = (:'gx'::jsonb ->> 'gift_card_id')::uuid), now() + interval '60 months',
                'expires 60 months after issue');
select tests.eq((select expires_at from public.gift_cards where id = tests.fx('credit_a')), null::timestamptz, 'store credit does not expire');
update public.gift_card_settings set expires_months = null where shop_id = tests.fx('shop_a');

-- ============================================================ lookup_gift_card
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.lookup_gift_card(tests.fx('shop_a'), lower(replace(:'g1'::jsonb ->> 'code', '-', ' '))) - 'expires_at',
                jsonb_build_object('gift_card_id', tests.fx('g1'), 'kind', 'gift', 'last4', :'g1'::jsonb ->> 'last4',
                                   'balance_cents', 5000, 'status', 'active'),
                'lookup ignores case, spaces and dashes');
select tests.eq(public.lookup_gift_card(tests.fx('shop_a'), 'WRONG-CODE-0000-0000'), null::jsonb, 'an unknown code is simply not found');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(public.lookup_gift_card(tests.fx('shop_b'), :'g1'::jsonb ->> 'code'), null::jsonb, 'codes are bound to their shop');
select tests.as_superuser();
select tests.eq((select count(*) || '/' || count(*) filter (where not succeeded) from public.gift_card_attempts
                  where attempt_key = 'user:' || tests.fx('u_manager_a')::text),
                '2/1', 'both lookups were logged (one miss)');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.lookup_gift_card(tests.fx('shop_a'), 'X')$$, '42501', 'technicians only when they may collect');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.lookup_gift_card(tests.fx('shop_a'), 'X')$$, '42501', 'outsiders cannot look up');

-- ============================================================ redeem_gift_card
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.redeem_gift_card(tests.fx('inv1'), :'g1'::jsonb ->> 'code') as p1 \gset
select tests.ok((select method = 'gift_card' and status = 'succeeded' and kind = 'payment' and amount_cents = 5000 and tip_cents = 0
                        and stripe_payment_intent_id is null and card_last4 is null and recorded_by = tests.fx('u_manager_a')
                        and note = 'Gift card …' || (:'g1'::jsonb ->> 'last4') and paid_at = now()
                 from public.payments where id = (:'p1'::public.payments).id), 'a gift card payment: tender, no Stripe or card data');
select tests.eq(pg_temp.bal(tests.fx('g1')), 'depleted/0', 'the whole card was used');
select tests.eq(pg_temp.inv(tests.fx('inv1')), 'partially_paid/5000/5000', 'and pays the invoice');
select tests.eq((select concat_ws('/', kind, amount_cents, balance_after_cents, payment_id = (:'p1'::public.payments).id)
                   from public.gift_card_transactions where gift_card_id = tests.fx('g1') and kind = 'redeem'),
                'redeem/-5000/0/t', 'redeem transaction with its payment');
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv1'), $$ || quote_literal(:'g1'::jsonb ->> 'code') || $$)$$, '22023',
                         '%no balance left%', 'an empty card is refused');
-- partial amounts and overpayment refusals (card g2: 8000; inv1 still owes 5000)
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv1'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$, 6000)$$,
                         '22023', '%exceeds the balance due%', 'never more than the invoice balance');
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv2'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$, 9000)$$,
                         '22023', '%balance is only $80.00%', 'never more than the card balance');
select tests.throws($$select public.redeem_gift_card(tests.fx('inv1'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$, 0)$$,
                    '22023', 'amount > 0');
select public.redeem_gift_card(tests.fx('inv1'), :'g2'::jsonb ->> 'code', 3000);
select tests.eq(pg_temp.bal(tests.fx('g2')), 'active/5000', 'partial redemption');
select public.redeem_gift_card(tests.fx('inv1'), :'g2'::jsonb ->> 'code');
select tests.eq(pg_temp.bal(tests.fx('g2')) || ' ' || pg_temp.inv(tests.fx('inv1')), 'active/3000 paid/10000/0',
                'no amount: as much as the invoice needs');
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv1'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$)$$,
                         '22023', '%paid and cannot take payments%', 'a paid invoice takes no more');
select tests.eq(public.redeem_gift_card(tests.fx('inv2'), 'ZZZZ-ZZZZ-ZZZZ-ZZZZ'), null::public.payments, 'unknown code: null (logged)');
-- in-flight card payments reduce what a card may pay
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_gcfly', 'pending', 6000, 0, 'payment', 'card', p_invoice_id => tests.fx('inv2'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv2'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$, 2000)$$,
                         '22023', '%exceeds the balance due ($10.00)%', 'the card payment in progress is left alone');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_gcfly', 'cancelled', 6000, 0, 'payment', 'card');
-- technicians who may collect, on their assigned job's invoice only
select tests.as_superuser();
update public.shops set techs_can_collect_payments = true where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_job', (public.create_invoice_from_job(tests.fx('job_a'))).id);
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$select public.redeem_gift_card(tests.fx('inv_job'), $$ || quote_literal(:'g2'::jsonb ->> 'code') || $$, 1000)$$,
                   'a collecting technician redeems on their assigned job''s invoice');
select tests.eq(pg_temp.bal(tests.fx('g2')), null, 'technicians cannot read gift cards');
select tests.throws($$select public.redeem_gift_card(tests.fx('inv2'), 'ANY')$$, '42501', 'but not on other invoices');
select tests.eq(public.lookup_gift_card(tests.fx('shop_a'), :'g2'::jsonb ->> 'code') ->> 'balance_cents', '2000',
                'and may look a card up');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.redeem_gift_card(tests.fx('inv2'), 'ANY')$$, 'P0002', 'another shop''s invoice: not found');
-- void / expired cards
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('g3', (public.issue_gift_card(tests.fx('shop_a'), 2500) ->> 'gift_card_id')::uuid);
select public.issue_gift_card(tests.fx('shop_a'), 2500) as g4 \gset
select tests.as_superuser();
update public.gift_cards set expires_at = now() - interval '1 day' where id = (:'g4'::jsonb ->> 'gift_card_id')::uuid;
update public.gift_card_transactions set created_at = now() - interval '3 days' where gift_card_id = (:'g4'::jsonb ->> 'gift_card_id')::uuid;
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv2'), $$ || quote_literal(:'g4'::jsonb ->> 'code') || $$)$$,
                         '22023', '%expired%', 'an expired card is refused');
select tests.eq(public.lookup_gift_card(tests.fx('shop_a'), :'g4'::jsonb ->> 'code') ->> 'status', 'expired', 'lookup says expired');

-- ============================================================ store credit (no code)
select tests.lives($$select public.redeem_customer_credit(tests.fx('inv_job'), tests.fx('credit_a'), 1500)$$,
                   'store credit pays its owner''s invoice');
select tests.eq((select note from public.payments where invoice_id = tests.fx('inv_job') and note like 'Store credit%'),
                (select 'Store credit …' || code_last4 from public.gift_cards where id = tests.fx('credit_a')), 'noted as store credit');
select tests.throws_like($$select public.redeem_customer_credit(tests.fx('inv2'), tests.fx('credit_a'))$$, '22023',
                         '%belongs to another customer%', 'never another customer''s invoice');
select tests.throws_like($$select public.redeem_customer_credit(tests.fx('inv2'), tests.fx('g2'))$$, '22023',
                         '%redeemed with their code%', 'gift cards always need their code');
select tests.throws($$select public.redeem_customer_credit(tests.fx('inv2'), gen_random_uuid())$$, 'P0002', 'unknown credit');
select tests.throws_like($$select public.redeem_gift_card(tests.fx('inv2'), $$ || quote_literal(:'cr'::jsonb ->> 'code') || $$)$$, '22023',
                         '%belongs to another customer%', 'a store credit code only pays its owner''s invoices');

-- ============================================================ refunds credit the card back
select tests.authenticate_as(tests.fx('u_admin_a'));
select public.refund_manual_payment((:'p1'::public.payments).id, 1000) as rf \gset
select tests.eq((select concat_ws('/', status, refunded_cents) from public.payments where id = (:'p1'::public.payments).id),
                'partially_refunded/1000', 'the payment is partially refunded');
select tests.eq(pg_temp.bal(tests.fx('g1')), 'active/1000', 'the refund goes back onto the card (not cash)');
select tests.eq((select concat_ws('/', amount_cents, balance_after_cents, payment_id = (:'p1'::public.payments).id)
                   from public.gift_card_transactions where gift_card_id = tests.fx('g1') and kind = 'refund'),
                '1000/1000/t', 'refund transaction');
select tests.eq(pg_temp.inv(tests.fx('inv1')), 'partially_paid/9000/1000', 'the invoice owes it again');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.refund_manual_payment((select id from public.payments where note like 'Gift card%' limit 1), 100)$$,
                    '42501', 'managers cannot refund');

-- ============================================================ adjust / void
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.adjust_gift_card(tests.fx('g3'), 500)$$, '42501', 'managers cannot adjust');
select tests.throws($$select public.void_gift_card(tests.fx('g3'))$$, '42501', 'nor void');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select concat_ws('/', balance_cents, status, code_hash is null) from public.adjust_gift_card(tests.fx('g3'), 500, 'Goodwill')),
                '3000/active/t', 'adjusted up; the returned row never carries the code hash');
select tests.throws_like($$select public.adjust_gift_card(tests.fx('g3'), -3001)$$, '22023', '%below zero%', 'never below zero');
select tests.throws($$select public.adjust_gift_card(tests.fx('g3'), 0)$$, '22023', 'not zero');
select tests.eq((select concat_ws('/', balance_cents, status) from public.adjust_gift_card(tests.fx('g3'), -3000)), '0/depleted',
                'adjusted to zero: depleted');
select public.adjust_gift_card(tests.fx('g3'), 700);
select tests.eq((select concat_ws('/', status, balance_cents, void_reason, code_hash is null) from public.void_gift_card(tests.fx('g3'), 'Lost card')),
                'void/0/Lost card/t', 'voided: the balance is gone');
select tests.eq((select concat_ws('/', kind, amount_cents, balance_after_cents) from public.gift_card_transactions
                  where gift_card_id = tests.fx('g3') and kind = 'void'), 'void/-700/0', 'void transaction');
select tests.throws($$select public.void_gift_card(tests.fx('g3'))$$, '22023', 'already void');
select tests.throws($$select public.adjust_gift_card(tests.fx('g3'), 100)$$, '22023', 'a void card cannot be adjusted');
select tests.throws($$select public.void_gift_card(gen_random_uuid())$$, 'P0002', 'unknown card');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.void_gift_card(tests.fx('g2'))$$, 'P0002', 'another shop''s card: not found');

-- ============================================================ public /i redemption
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.invoice_link_token(tests.fx('inv2')) as tok2 \gset
select public.issue_gift_card(tests.fx('shop_a'), 4000) as g5 \gset
select tests.as_anon();
select tests.eq(public.public_get_invoice(:'tok2') -> 'invoice' -> 'gift_card_redeemable', 'true'::jsonb,
                'the /i page offers gift card redemption');
select public.public_redeem_gift_card(:'tok2', :'g5'::jsonb ->> 'code', 1500) as pr \gset
select tests.eq((:'pr'::jsonb -> 'gift_card_result') - 'last4',
                '{"redeemed": true, "message": null, "amount_cents": 1500, "remaining_cents": 2500}'::jsonb, 'redeemed online');
select tests.eq((:'pr'::jsonb -> 'invoice' ->> 'balance_cents')::bigint, 5500::bigint, 'the returned document shows the new balance');
select tests.eq((select p ->> 'method' from jsonb_array_elements(:'pr'::jsonb -> 'payments') p limit 1), 'gift_card', 'listed as a gift card payment');
select tests.eq(public.public_redeem_gift_card(:'tok2', 'NOPE-NOPE-NOPE-NOPE') -> 'gift_card_result' ->> 'message',
                'this gift card code is not valid', 'a wrong code is an answer');
select tests.eq(public.public_redeem_gift_card(:'tok2', :'cr'::jsonb ->> 'code') -> 'gift_card_result' ->> 'message',
                'this store credit belongs to another customer', 'store credit of another customer is refused');
select tests.eq(public.public_redeem_gift_card(:'tok2', :'g4'::jsonb ->> 'code') -> 'gift_card_result' ->> 'message',
                'this gift card has expired', 'expired cards are refused (no error)');
select tests.throws_like($$select public.public_redeem_gift_card($$ || quote_literal(:'tok2') || $$, $$ || quote_literal(:'g5'::jsonb ->> 'code') || $$, 999999)$$,
                         '22023', '%balance is only%', 'amount checks as for staff');
select tests.throws($$select public.public_redeem_gift_card(gen_random_uuid(), 'X')$$, 'PT404', 'unknown invoice: 404');
-- 5 wrong codes per invoice per hour
select public.public_redeem_gift_card(:'tok2', 'NOPE-NOPE-NOPE-000' || g) from generate_series(1, 4) g;
select tests.throws($$select public.public_redeem_gift_card($$ || quote_literal(:'tok2') || $$, 'ANY')$$, 'PT429',
                    'the sixth wrong code within the hour is refused');
select tests.throws($$select public.public_redeem_gift_card($$ || quote_literal(:'tok2') || $$, $$ || quote_literal(:'g5'::jsonb ->> 'code') || $$)$$,
                    'PT429', 'even a right one, until the hour has passed');
-- 20 per client IP per hour (across invoices)
select tests.as_superuser();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.7"}', true);
select tests.authenticate_as(tests.fx('u_manager_a'));
create temp table toks_ids as
  select (public.mark_invoice_sent((public.create_invoice(tests.fx('cust_a2'), '[{"name":"X","unit_price_cents":100}]')).id)).id as i
    from generate_series(1, 5);
create temp table toks as select public.invoice_link_token(i) as t from toks_ids;
grant select on toks to anon;
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.7"}', true);
select public.public_redeem_gift_card(t, 'BAD-' || g) from toks, generate_series(1, 4) g;
select tests.as_superuser();
select tests.eq((select count(*) from public.gift_card_attempts where attempt_key = 'ip:198.51.100.7'), 20::bigint,
                'the client address is logged');
select tests.as_anon();
select set_config('request.headers', '{"x-forwarded-for": "198.51.100.7"}', true);
select tests.throws($$select public.public_redeem_gift_card((select t from toks limit 1), 'ANY')$$, 'PT429', '20 misses from one address: blocked');
select tests.as_superuser();
select set_config('request.headers', '', true);
select tests.as_anon();
select tests.lives($$select public.public_redeem_gift_card((select t from toks limit 1), 'ANY')$$, 'another address is not blocked');

-- ============================================================ online orders
select tests.as_anon();
select tests.eq(public.public_gift_card_offer('shop-a') - 'shop' - 'terms' - 'expires_months' - 'currency',
                '{"enabled": false, "offers": [], "allow_custom_amount": false, "min_custom_cents": 1000, "max_custom_cents": 50000}'::jsonb,
                'nothing sold online until the shop sets it up (no seeded offers)');
select tests.throws($$select public.public_gift_card_offer('no-such-shop')$$, 'PT404', 'unknown shop');
select tests.as_service();
select tests.throws($$select public.gift_card_order_prepare('shop-a', '{"offer_index":0}')$$, '55000', 'online sales off: refused');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.gift_card_settings set online_enabled = true where shop_id = tests.fx('shop_a')$$), 0::bigint,
                'managers read but cannot change gift card settings');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.gift_card_settings set offers = '[{"value_cents":400,"price_cents":400}]' where shop_id = tests.fx('shop_a')$$,
                    '23514', 'offers are at least $5');
select tests.throws($$update public.gift_card_settings set offers = '[{"value_cents":1000,"price_cents":1500}]' where shop_id = tests.fx('shop_a')$$,
                    '23514', 'the price never exceeds the value');
select tests.throws($$update public.gift_card_settings set offers = '[{"value_cents":1000,"price_cents":900,"bonus":1}]' where shop_id = tests.fx('shop_a')$$,
                    '23514', 'no other keys');
select tests.throws($$update public.gift_card_settings set min_custom_cents = 60000 where shop_id = tests.fx('shop_a')$$, '23514',
                    'min <= max');
update public.gift_card_settings
   set online_enabled = true, offers = '[{"value_cents":10000,"price_cents":9000},{"value_cents":5000,"price_cents":5000}]',
       allow_custom_amount = true, terms = 'No cash value.'
 where shop_id = tests.fx('shop_a');
select tests.as_anon();
select tests.eq(public.public_gift_card_offer('shop-a') -> 'enabled', 'true'::jsonb, 'now on sale');
select tests.eq(public.public_gift_card_offer('shop-a') -> 'offers' -> 0, '{"value_cents": 10000, "price_cents": 9000}'::jsonb, 'offers listed');
select tests.throws($$select public.gift_card_order_prepare('shop-a', '{"offer_index":0}')$$, '42501', 'prepare is not public');
select tests.as_service();
create function pg_temp.order_payload(p_extra jsonb) returns jsonb language sql as $$
  select '{"purchaser":{"name":"Paula Payer","email":"paula@example.com"},"recipient":{"name":"Rick Receiver","email":"rick@example.com","message":"Enjoy!"}}'::jsonb || p_extra
$$;
select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":0}')) as o1 \gset
select tests.eq(:'o1'::jsonb - 'order_id' - 'token' - 'shop_id',
                '{"value_cents": 10000, "price_cents": 9000, "currency": "usd", "purchaser_email": "paula@example.com"}'::jsonb,
                'an offer: value and price from the shop''s settings');
select tests.throws_like($$select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"amount_cents":999}'))$$, '22023',
                         '%out of range%', 'custom amounts within the shop''s range');
select tests.throws_like($$select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":0,"amount_cents":2000}'))$$,
                         '22023', '%one of the offers or an amount%', 'an offer or an amount, not both');
select tests.throws_like($$select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":5}'))$$, '22023',
                         '%no longer available%', 'unknown offer');
select tests.throws($$select public.gift_card_order_prepare('shop-a', '{"offer_index":0,"purchaser":{"name":"P","email":"bad"},"recipient":{"email":"r@example.com"}}')$$,
                    '22023', 'purchaser email validated');
select tests.throws($$select public.gift_card_order_prepare('shop-a', '{"offer_index":0,"purchaser":{"name":"P","email":"p@example.com"}}')$$,
                    '22023', 'recipient required');
select tests.throws($$select public.gift_card_order_prepare('nope', pg_temp.order_payload('{"offer_index":0}'))$$, 'PT404', 'unknown shop');
select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"amount_cents":2500}')) as o2 \gset
select tests.eq((:'o2'::jsonb ->> 'price_cents')::bigint, 2500::bigint, 'custom amount: price = value');
-- paid (webhook)
select tests.throws_like($$select public.gift_card_order_paid($$ || quote_literal(:'o1'::jsonb ->> 'order_id') || $$::uuid, 'pi_gco1', 8000)$$,
                         '22023', '%does not match%', 'the amount received must be the price');
select public.gift_card_order_paid((:'o1'::jsonb ->> 'order_id')::uuid, 'pi_gco1', 9000) as paid1 \gset
select tests.eq(:'paid1'::jsonb -> 'first_time', 'true'::jsonb, 'first delivery issues the card');
select tests.fx_set('gco1', (:'paid1'::jsonb ->> 'gift_card_id')::uuid);
select tests.as_superuser();
select tests.ok((select g.initial_cents = 10000 and g.sold_price_cents = 9000 and g.issued_via = 'online' and g.stripe_payment_intent_id = 'pi_gco1'
                        and b.email = 'paula@example.com' and b.lifecycle = 'lead' and b.source = 'other' and not b.email_opt_in
                        and r.email = 'rick@example.com' and r.first_name = 'Rick' and r.last_name = 'Receiver'
                 from public.gift_cards g
                 join public.customers b on b.id = g.purchaser_customer_id
                 join public.customers r on r.id = g.owner_customer_id
                 where g.id = tests.fx('gco1')), 'card issued online; purchaser and recipient became leads without consent');
select tests.eq((select string_agg(m.to_address, ',' order by m.to_address) from public.messages m
                  where m.shop_id = tests.fx('shop_a') and m.template_key = 'gift_card_delivery' and m.to_address in ('paula@example.com', 'rick@example.com')),
                'paula@example.com,rick@example.com', 'delivered to the recipient, with a copy to the purchaser');
select tests.eq((select count(*) from public.notifications n where n.shop_id = tests.fx('shop_a') and n.kind = 'gift_card_purchased'),
                (select count(*) from public.shop_members m where m.shop_id = tests.fx('shop_a') and m.active and m.role in ('owner', 'admin', 'manager')),
                'owners, admins and managers are notified');
select tests.eq((select status from public.gift_card_orders where id = (:'o1'::jsonb ->> 'order_id')::uuid), 'paid', 'order paid');
select tests.as_service();
select tests.eq(public.gift_card_order_paid((:'o1'::jsonb ->> 'order_id')::uuid, 'pi_gco1', 9000) -> 'first_time', 'false'::jsonb,
                'a replay issues nothing');
select tests.eq(public.gift_card_order_paid((:'o2'::jsonb ->> 'order_id')::uuid, 'pi_gco1', 2500) -> 'gift_card_id',
                to_jsonb(tests.fx('gco1')), 'an intent that already issued a card never issues another');
select tests.eq((select count(*) from public.gift_cards where stripe_payment_intent_id = 'pi_gco1'), 1::bigint, 'one card per payment');
select tests.throws($$select public.gift_card_order_paid(gen_random_uuid(), 'pi_x', 1)$$, 'P0002', 'unknown order');
-- success page
select token as o1_token from public.gift_card_orders where id = (:'o1'::jsonb ->> 'order_id')::uuid \gset
select tests.as_anon();
select tests.eq(public.public_gift_card_order_status(:'o1_token') - 'last4',
                '{"status": "paid", "value_cents": 10000, "recipient_name": "Rick Receiver"}'::jsonb, 'status by token, never the code');
select tests.as_anon();
select tests.throws($$select public.public_gift_card_order_status(gen_random_uuid())$$, 'PT404', 'unknown token');
-- refunds (charge.refunded, cumulative, price terms)
select tests.as_service();
select tests.eq(public.gift_card_order_refunded('pi_gco1', 4500) - 'gift_card_id',
                '{"refunded_total_cents": 4500, "removed_cents": 5000, "unrecovered_cents": 0, "status": "active"}'::jsonb,
                'half the price refunded: half the value comes off the unused card');
select tests.eq(public.gift_card_order_refunded('pi_gco1', 4500) ->> 'removed_cents', '0', 'a replay changes nothing');
select tests.eq(public.gift_card_order_refunded('pi_gco1', 9000) - 'gift_card_id',
                '{"refunded_total_cents": 9000, "removed_cents": 5000, "unrecovered_cents": 0, "status": "void"}'::jsonb,
                'fully refunded and never used: voided');
select tests.eq((select status from public.gift_card_orders where id = (:'o1'::jsonb ->> 'order_id')::uuid), 'refunded', 'order refunded');
select tests.throws($$select public.gift_card_order_refunded('pi_gco1', 9001)$$, '22023', 'never more than the price');
select tests.throws($$select public.gift_card_order_refunded('pi_nothing', 1)$$, 'P0002', 'unknown intent');
-- a partly spent card: what was spent cannot be taken back
select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":1}') || '{"purchaser":{"name":"Q","email":"q@example.com"}}') as o3 \gset
select public.gift_card_order_paid((:'o3'::jsonb ->> 'order_id')::uuid, 'pi_gco3', 5000) as paid3 \gset
select tests.as_superuser();
update public.gift_cards set balance_cents = 1500 where id = (:'paid3'::jsonb ->> 'gift_card_id')::uuid;   -- as if 3500 were spent
insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents)
values (tests.fx('shop_a'), (:'paid3'::jsonb ->> 'gift_card_id')::uuid, 'redeem', -3500, 1500);
select tests.as_service();
select tests.eq(public.gift_card_order_refunded('pi_gco3', 5000) - 'gift_card_id',
                '{"refunded_total_cents": 5000, "removed_cents": 1500, "unrecovered_cents": 3500, "status": "depleted"}'::jsonb,
                'only the unspent balance comes off; the rest is reported');
-- abuse limit: 5 orders per purchaser email per day
select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":1}')) from generate_series(1, 3);
select tests.throws($$select public.gift_card_order_prepare('shop-a', pg_temp.order_payload('{"offer_index":1}'))$$, 'PT429',
                    'the sixth order of the day for one email is refused');

-- ============================================================ report_gift_cards
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.report_gift_cards(tests.fx('shop_a'), (now() at time zone 'America/Chicago')::date,
                                (now() at time zone 'America/Chicago')::date) as rep \gset
select tests.as_superuser();
select tests.eq((:'rep'::jsonb ->> 'sold_count')::bigint,
                (select count(*) from public.gift_cards where shop_id = tests.fx('shop_a') and kind = 'gift'), 'gift cards sold today');
select tests.eq((:'rep'::jsonb ->> 'sold_price_cents')::bigint,
                (select sum(coalesce(sold_price_cents, 0))::bigint from public.gift_cards where shop_id = tests.fx('shop_a') and kind = 'gift'),
                'what they sold for');
select tests.eq((:'rep'::jsonb ->> 'credit_issued_cents')::bigint, 3000::bigint, 'store credit issued');
select tests.eq((:'rep'::jsonb ->> 'redeemed_cents')::bigint,
                (select sum(public.payment_net_amount(status, amount_cents, tip_cents, refunded_cents))::bigint + 3500
                   from public.payments where shop_id = tests.fx('shop_a') and method = 'gift_card'),
                'redeemed = net gift card payments (refunds credited back subtracted) + the 35.00 spend simulated above');
select tests.eq((:'rep'::jsonb ->> 'outstanding_liability_cents')::bigint,
                (select sum(balance_cents)::bigint from public.gift_cards where shop_id = tests.fx('shop_a')
                   and (expires_at is null or expires_at > now())),
                'liability = balances of unexpired cards (ledger-exact)');
select tests.eq((:'rep'::jsonb ->> 'expired_cents')::bigint, 0::bigint, 'nothing expired today');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((public.report_gift_cards(tests.fx('shop_a'), ((now() - interval '2 days') at time zone 'America/Chicago')::date,
                                          (now() at time zone 'America/Chicago')::date) ->> 'expired_cents')::bigint,
                2500::bigint, 'the card that expired yesterday: its balance counted as expired');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.report_gift_cards(tests.fx('shop_a'), '2025-01-01', '2025-01-31')$$, '42501', 'technicians: no report');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.report_gift_cards(tests.fx('shop_a'), '2025-01-01', '2025-01-31')$$, '42501', 'other shops: no report');

-- ============================================================ RLS, privileges, isolation
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select count(*) > 0 from public.gift_cards where shop_id = tests.fx('shop_a')), 'managers read gift cards');
select tests.throws($$select code_hash from public.gift_cards limit 1$$, '42501', 'but never the code hash');
select tests.throws($$insert into public.gift_cards (shop_id, code_hash, code_last4, initial_cents, balance_cents, issued_via)
                      values (tests.fx('shop_a'), repeat('a', 64), 'AAAA', 100, 100, 'staff')$$, '42501', 'no client inserts');
select tests.throws($$update public.gift_cards set balance_cents = 999999 where shop_id = tests.fx('shop_a')$$, '42501', 'no client updates');
select tests.throws($$insert into public.gift_card_transactions (shop_id, gift_card_id, kind, amount_cents, balance_after_cents)
                      values (tests.fx('shop_a'), tests.fx('g2'), 'adjust', 1, 1)$$, '42501', 'no client ledger writes');
select tests.throws($$select count(*) from public.gift_card_attempts$$, '42501', 'the attempt log is not readable');
select tests.ok((select count(*) > 0 from public.gift_card_orders where shop_id = tests.fx('shop_a')), 'managers read orders');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select count(*) from public.gift_card_transactions where shop_id = tests.fx('shop_a')), 0::bigint, 'technicians: no ledger');
select tests.eq((select count(*) from public.gift_card_orders where shop_id = tests.fx('shop_a')), 0::bigint, 'technicians: no orders');
select tests.eq((select count(*) from public.gift_card_settings), 0::bigint, 'technicians: no settings');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.eq((select count(*) from public.gift_cards where shop_id = tests.fx('shop_a')), 0::bigint, 'other shops: no cards');
select tests.as_superuser();
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.gift_card_code_hash(uuid, text)', 'public.gen_gift_card_code()', 'public.gift_card_issue_core(uuid, text, bigint, bigint, text, uuid, uuid, text, text, text, text, timestamp with time zone, text)',
    'public.gift_card_redeem_core(public.invoices, public.gift_cards, bigint, text)', 'public.gift_card_order_prepare(text, jsonb, timestamp with time zone)',
    'public.gift_card_order_paid(uuid, text, bigint)', 'public.gift_card_order_refunded(text, bigint)',
    'public.gift_card_log_attempt(uuid, text, boolean)', 'public.gift_card_match_customer(uuid, text, text, public.customer_source)']) as f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute')), '', 'internal / webhook helpers: service_role only');
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array['public.public_redeem_gift_card(uuid, text, bigint)', 'public.public_gift_card_offer(text)',
                    'public.public_gift_card_order_status(uuid)']) as f
  where not has_function_privilege('anon', f, 'execute')), '', 'public entry points are open to anon');

-- ============================================================ shop deletion with gift card history
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.fx_set('inv_b', (public.create_invoice(tests.fx('cust_b'), '[{"name":"Wash","unit_price_cents":5000}]')).id);
select public.mark_invoice_sent(tests.fx('inv_b'));
select public.issue_gift_card(tests.fx('shop_b'), 2000) as gb \gset
select public.redeem_gift_card(tests.fx('inv_b'), :'gb'::jsonb ->> 'code');
select tests.as_superuser();
select tests.lives($$delete from public.shops where id = tests.fx('shop_b')$$,
                   'a shop with gift card redemptions can still be deleted (ledger rows go with it)');
select tests.eq((select count(*) from public.gift_cards where shop_id = tests.fx('shop_b')), 0::bigint, 'cards gone with the shop');
