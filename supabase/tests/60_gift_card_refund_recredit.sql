-- 60 money: refunding a gift-card payment (refund_manual_payment, 0066)
-- never re-credits a card whose online purchase was refunded (in full or in
-- part) or that has expired — the same refusal as for a void card, and
-- nothing changes when it is refused. Normal re-credits still work (staff-
-- issued cards, online cards whose purchase was not refunded), a purchase
-- refund AFTER a re-credit takes the value off the balance, roles and
-- two-shop isolation.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.shops set tax_rate_bps = 0 where id in (tests.fx('shop_a'), tests.fx('shop_b'));
insert into public.message_templates (shop_id, key, channel, subject, body)
values (tests.fx('shop_a'), 'gift_card_delivery', 'email', 'A gift card from {{sender_name}}',
        'Hi {{recipient_name}}, you got {{gift_card_amount}}: code {{gift_card_code}}.')
on conflict (shop_id, key, channel) do update set subject = excluded.subject, body = excluded.body, enabled = true;

create function pg_temp.bal(p_id uuid) returns text language sql security definer as $$
  select concat_ws('/', status, balance_cents) from public.gift_cards where id = p_id
$$;
create function pg_temp.pay(p_id uuid) returns text language sql security definer as $$
  select concat_ws('/', status, refunded_cents) from public.payments where id = p_id
$$;
create function pg_temp.inv(p_id uuid) returns text language sql security definer as $$
  select concat_ws('/', status, amount_paid_cents, balance_cents) from public.invoices where id = p_id
$$;
grant execute on function pg_temp.bal(uuid), pg_temp.pay(uuid), pg_temp.inv(uuid) to authenticated, service_role;

-- an online purchase of p_cents for p_email; returns the card id and puts its code in fx 'code_<intent>'
create function pg_temp.buy_online(p_intent text, p_cents bigint, p_email text) returns uuid language plpgsql as $$
declare
  v_o    jsonb;
  v_paid jsonb;
  v_code text;
begin
  v_o := public.gift_card_order_prepare('shop-a', jsonb_build_object(
           'amount_cents', p_cents,
           'purchaser', jsonb_build_object('name', 'Paula Payer', 'email', 'paula@example.com'),
           'recipient', jsonb_build_object('name', 'Rick R', 'email', p_email)));
  v_paid := public.gift_card_order_paid((v_o ->> 'order_id')::uuid, p_intent, p_cents);
  select substring(m.body from '[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}') into v_code
    from public.messages m
   where m.shop_id = tests.fx('shop_a') and m.template_key = 'gift_card_delivery' and m.to_address = p_email
   order by m.created_at desc limit 1;
  perform set_config('pg_temp_code.' || p_intent, v_code, true);
  return (v_paid ->> 'gift_card_id')::uuid;
end $$;
create function pg_temp.code(p_intent text) returns text language sql as $$
  select current_setting('pg_temp_code.' || p_intent)
$$;
grant execute on function pg_temp.code(text), pg_temp.buy_online(text, bigint, text) to authenticated, service_role;

-- an invoice of p_cents for cust_a, sent
create function pg_temp.invoice(p_cents bigint) returns uuid language plpgsql as $$
declare
  v_i uuid;
begin
  v_i := (public.create_invoice(tests.fx('cust_a'), jsonb_build_array(jsonb_build_object('name', 'Detail', 'unit_price_cents', p_cents)))).id;
  perform public.mark_invoice_sent(v_i);
  return v_i;
end $$;
grant execute on function pg_temp.invoice(bigint) to authenticated;

select tests.authenticate_as(tests.fx('u_admin_a'));
update public.gift_card_settings set online_enabled = true, allow_custom_amount = true where shop_id = tests.fx('shop_a');

-- ============================================================ repro: purchase refunded in full after part was spent
select tests.as_service();
select tests.fx_set('card', pg_temp.buy_online('pi_gcrefund1', 10000, 'rick@example.com'));
select tests.ok(pg_temp.code('pi_gcrefund1') is not null, 'code delivered');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', pg_temp.invoice(6000));
select tests.fx_set('pay', (public.redeem_gift_card(tests.fx('inv'), pg_temp.code('pi_gcrefund1'), 6000)).id);
select tests.eq(pg_temp.bal(tests.fx('card')), 'active/4000', 'card 40.00 left');
select tests.eq(pg_temp.inv(tests.fx('inv')), 'paid/6000/0', 'the invoice is paid with the card');
select tests.as_service();
select tests.eq(public.gift_card_order_refunded('pi_gcrefund1', 10000) ->> 'unrecovered_cents', '6000', 'purchase refunded in full');
select tests.eq(pg_temp.bal(tests.fx('card')), 'depleted/0', 'card empty (the spent 60.00 is unrecovered)');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.refund_manual_payment(tests.fx('pay'), 6000)$$, '22023',
                         '%online purchase%was refunded%', 'the invoice payment cannot be refunded onto the card');
select tests.throws_like($$select public.refund_manual_payment(tests.fx('pay'), 1)$$, '22023',
                         '%online purchase%was refunded%', 'not even one cent of it');
select tests.eq(pg_temp.bal(tests.fx('card')), 'depleted/0', 'a card whose purchase was refunded in full is not re-credited');
select tests.eq(pg_temp.pay(tests.fx('pay')), 'succeeded/0', 'the payment is unchanged');
select tests.eq(pg_temp.inv(tests.fx('inv')), 'paid/6000/0', 'and so is the invoice');
select tests.eq((select count(*) from public.gift_card_transactions where gift_card_id = tests.fx('card') and kind = 'refund' and amount_cents > 0),
                0::bigint, 'no re-credit transaction');

-- ============================================================ a partial purchase refund also blocks the re-credit
select tests.as_service();
select tests.fx_set('card_p', pg_temp.buy_online('pi_gcrefund2', 10000, 'rick2@example.com'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_p', pg_temp.invoice(8000));
select tests.fx_set('pay_p', (public.redeem_gift_card(tests.fx('inv_p'), pg_temp.code('pi_gcrefund2'), 8000)).id);
select tests.as_service();
select tests.eq(public.gift_card_order_refunded('pi_gcrefund2', 5000) - 'gift_card_id',
                '{"refunded_total_cents": 5000, "removed_cents": 2000, "unrecovered_cents": 3000, "status": "depleted"}'::jsonb,
                'half the purchase refunded: 20.00 removed, 30.00 already spent');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.refund_manual_payment(tests.fx('pay_p'), 8000)$$, '22023',
                         '%online purchase%was refunded%', 'a partly refunded purchase blocks the re-credit too');
select tests.eq(concat_ws(' ', pg_temp.bal(tests.fx('card_p')), pg_temp.pay(tests.fx('pay_p'))), 'depleted/0 succeeded/0',
                'nothing changed');

-- ============================================================ normal re-credits still work
-- an online card whose purchase was never refunded
select tests.as_service();
select tests.fx_set('card_ok', pg_temp.buy_online('pi_gcrefund3', 5000, 'rick3@example.com'));
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv_ok', pg_temp.invoice(3000));
select tests.fx_set('pay_ok', (public.redeem_gift_card(tests.fx('inv_ok'), pg_temp.code('pi_gcrefund3'), 3000)).id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.refund_manual_payment(tests.fx('pay_ok'), 1000)).status::text, 'partially_refunded',
                'an online card whose purchase stands is re-credited');
select tests.eq(pg_temp.bal(tests.fx('card_ok')), 'active/3000', '20.00 left + 10.00 back');
select tests.eq(pg_temp.inv(tests.fx('inv_ok')), 'partially_paid/2000/1000', 'the invoice owes it again');
-- the purchase is refunded afterwards: the value comes off the (re-credited) balance, never twice
select tests.as_service();
select tests.eq(public.gift_card_order_refunded('pi_gcrefund3', 5000) - 'gift_card_id',
                '{"refunded_total_cents": 5000, "removed_cents": 3000, "unrecovered_cents": 2000, "status": "depleted"}'::jsonb,
                'a later purchase refund removes the re-credited value first');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.refund_manual_payment(tests.fx('pay_ok'), 1000)$$, '22023',
                         '%online purchase%was refunded%', 'and from then on the rest cannot be re-credited');
select tests.eq(pg_temp.bal(tests.fx('card_ok')), 'depleted/0', 'the card stays empty');

-- a staff-issued card (no online order)
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.issue_gift_card(tests.fx('shop_a'), 5000, '{"name":"Rita","email":"rita@example.com"}') as g \gset
select tests.fx_set('card_s', (:'g'::jsonb ->> 'gift_card_id')::uuid);
select tests.fx_set('inv_s', pg_temp.invoice(4000));
select tests.fx_set('pay_s', (public.redeem_gift_card(tests.fx('inv_s'), :'g'::jsonb ->> 'code', 4000)).id);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.refund_manual_payment(tests.fx('pay_s'), 1500)).refunded_cents, 1500::bigint, 'a staff-issued card is re-credited');
select tests.eq(pg_temp.bal(tests.fx('card_s')), 'active/2500', '10.00 left + 15.00 back');

-- ============================================================ an expired card is not re-credited
select tests.as_superuser();
update public.gift_cards set expires_at = now() - interval '1 day' where id = tests.fx('card_s');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.refund_manual_payment(tests.fx('pay_s'), 500)$$, '22023', '%has expired%',
                         'the value would land on a card that can never be redeemed');
select tests.eq(concat_ws(' ', pg_temp.bal(tests.fx('card_s')), pg_temp.pay(tests.fx('pay_s'))), 'active/2500 partially_refunded/1500',
                'nothing changed');
select tests.as_superuser();
update public.gift_cards set expires_at = now() + interval '1 day' where id = tests.fx('card_s');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((public.refund_manual_payment(tests.fx('pay_s'), 500)).refunded_cents, 2000::bigint, 'a card that has not expired yet is re-credited');
select tests.eq(pg_temp.bal(tests.fx('card_s')), 'active/3000', 'balance');

-- ============================================================ roles and isolation
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.refund_manual_payment(tests.fx('pay'), 100)$$, '42501', 'managers cannot refund');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.refund_manual_payment(tests.fx('pay'), 100)$$, '42501', 'nor technicians');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.refund_manual_payment(tests.fx('pay_s'), 100)$$, 'P0002', 'another shop''s admin: not found');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$select public.refund_manual_payment(tests.fx('pay_s'), 100)$$, 'P0002', 'an outsider: not found');
select tests.as_anon();
select tests.throws($$select public.refund_manual_payment(tests.fx('pay_s'), 100)$$, '42501', 'anon: no execute');
select tests.as_superuser();
select tests.eq(concat_ws(' ', pg_temp.bal(tests.fx('card_s')), pg_temp.pay(tests.fx('pay_s'))), 'active/3000 partially_refunded/2000',
                'the refused calls changed nothing');
