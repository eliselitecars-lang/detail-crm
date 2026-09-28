-- 80 comms: templates v2 (0083) — seeding of every new key (channels,
-- enabled flags), the gift-card email-only rule, enqueue_message_core
-- (document links required, quote / invoice ownership, optional v2 lines
-- left out, app-link gating, idempotent nonce, marketing rules for
-- service_followup), and the default wording of the money / ops keys
-- (gift card delivery, referral reward, job report) rendered for real.
\ir fixtures/two_shops.psql

select tests.as_superuser();
update public.messages set status = 'cancelled' where status = 'queued';

-- ============================================================ seeding
select tests.eq((select array_agg(key::text || ':' || channel::text || ':' || enabled::text order by key::text, channel)
                   from public.message_templates
                  where shop_id = tests.fx('shop_a')
                    and key::text in ('quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue', 'service_followup',
                                      'lead_received', 'job_report', 'gift_card_delivery', 'referral_reward')),
                array['deposit_reminder:sms:false', 'deposit_reminder:email:false', 'gift_card_delivery:email:true',
                      'invoice_overdue:sms:false', 'invoice_overdue:email:false', 'invoice_reminder:sms:false',
                      'invoice_reminder:email:false', 'job_report:sms:true', 'job_report:email:true', 'lead_received:sms:true',
                      'lead_received:email:true', 'quote_reminder:sms:false', 'quote_reminder:email:false',
                      'referral_reward:sms:true', 'referral_reward:email:true', 'service_followup:sms:false',
                      'service_followup:email:false'],
                'follow-ups seeded off, transactional wording on; the gift card is email only');
select tests.eq((select count(*) from public.followup_settings where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))), 2::bigint,
                'every shop gets follow-up settings');
select tests.fx_set('shop_c', tests.make_shop('owner-c@test.local', 'shop-c', 'Shop C'));
select tests.ok(exists (select 1 from public.followup_settings where shop_id = tests.fx('shop_c'))
                and (select count(*) from public.message_templates where shop_id = tests.fx('shop_c')) = 40,
                'a new shop is seeded with both');
select tests.throws($$insert into public.message_templates (shop_id, key, channel, body)
                      values (tests.fx('shop_a'), 'gift_card_delivery', 'sms', 'Code {{gift_card_code}}')$$, '23514',
                    'gift card codes go by email only');
select tests.ok((select bool_and(offset_minutes is null and reminder_offsets_minutes is null) from public.message_templates
                  where key::text in ('quote_reminder', 'service_followup', 'lead_received')), 'no schedule on event keys');
select tests.throws($$update public.message_templates set offset_minutes = 60 where key = 'quote_reminder'$$, '23514',
                    'follow-up keys take no offset (their schedule is followup_settings)');
-- reset restores the v2 default wording too
select tests.authenticate_as(tests.fx('u_admin_a'));
update public.message_templates set body = 'x', enabled = true where shop_id = tests.fx('shop_a') and key = 'quote_reminder' and channel = 'sms';
select public.reset_message_template((select id from public.message_templates
                                       where shop_id = tests.fx('shop_a') and key = 'quote_reminder' and channel = 'sms'));
select tests.ok((select not enabled and body like 'Hi {{customer_first_name}}, just a reminder%' from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'quote_reminder' and channel = 'sms'), 'reset to the v2 default');

-- ============================================================ the core
select tests.as_superuser();
create function pg_temp.body_of(p_id uuid) returns text language sql as $$ select body from public.messages where id = p_id $$;
grant execute on function pg_temp.body_of(uuid) to service_role;
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a')) returning tests.fx_set('q', id);
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a2')) returning tests.fx_set('q_other', id);
select tests.as_service();
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_reminder', 'sms', null,
                                            'See {{quote_link}}', null, public.comms_quote_vars(tests.fx('q')), null, null, null,
                                            tests.fx('q')), null, 'a draft quote has no link: nothing queued');
select tests.throws_like($$select public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_reminder', 'sms', null, 'x',
                                                              p_quote_id => tests.fx('q_other'))$$, '22023', '%another customer%',
                         'the quote must be the customer''s');
select tests.throws($$select public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_reminder', 'sms', null, 'x',
                                                         p_quote_id => gen_random_uuid())$$, 'P0002', 'unknown quote');
select tests.throws($$select public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'invoice_reminder', 'sms', null, 'x',
                                                         p_invoice_id => gen_random_uuid())$$, 'P0002', 'unknown invoice');
select tests.throws($$select public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_b'), 'quote_reminder', 'sms', null, 'x')$$,
                    'P0002', 'the customer must be the shop''s');
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'lead_received', 'sms', null, '   '), null,
                'no wording: nothing');
select tests.as_superuser();
update public.quotes set status = 'sent' where id = tests.fx('q');
select tests.as_service();
select tests.fx_set('m1', public.enqueue_message_core(
  tests.fx('shop_a'), tests.fx('cust_a'), 'quote_reminder', 'email', 'Quote #{{quote_number}} reminder',
  E'Hi {{customer_first_name}},\n\nTotal: {{quote_total}}\nValid until: {{valid_until}}\n\nApprove: {{quote_link}}',
  null, public.comms_quote_vars(tests.fx('q')), null, null, 'nonce-core-0001', tests.fx('q')));
select tests.as_superuser();
select tests.eq((select array[subject, body, (quote_id = tests.fx('q'))::text, request_nonce]
                   from public.messages where id = tests.fx('m1')),
                array['Quote #' || (select number from public.quotes where id = tests.fx('q')) || ' reminder',
                      E'Hi Alice,\n\nTotal: $0.00\n\nApprove: https://app.example.test/q/'
                        || (select public_token from public.quotes where id = tests.fx('q')),
                      'true', 'nonce-core-0001'],
                'rendered; the line with no validity date left out; linked to the quote');
select tests.as_service();
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'quote_reminder', 'email', 'other', 'other',
                                            p_request_nonce => 'nonce-core-0001'), tests.fx('m1'), 'a replayed nonce returns the message');
-- app links need the platform origin
select tests.as_superuser();
delete from public.platform_config where key = 'app_base_url';
select tests.as_service();
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'job_report', 'sms', null, 'See {{report_link}}',
                                            p_extra_vars => '{"report_link": "https://x.test/r/1"}'), null,
                'no app origin: nothing with an app link is queued');
select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
-- marketing: service_followup needs the opt-in
select tests.as_service();
select tests.eq(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'), 'service_followup', 'sms', null, 'Book again!'), null,
                'service follow-ups are marketing: no opt-in, nothing');
select tests.as_superuser();
update public.customers set sms_opt_in = true where id = tests.fx('cust_a');
select tests.as_service();
select tests.eq(pg_temp.body_of(public.enqueue_message_core(tests.fx('shop_a'), tests.fx('cust_a'),
                                                              'service_followup', 'sms', null, 'Book again!')),
                E'Book again!\nReply STOP to opt out.', 'opted in: sent with the opt-out line');

-- ============================================================ default wording, rendered
-- gift card delivery (money 0066 passes these variables)
select tests.as_service();
select tests.fx_set('m_gift', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'gift_card_delivery', 'email', null,
  public.gift_card_delivery_vars(tests.fx('shop_a'), 'ABCD-EFGH-JKLM-NPQR', 5000, 'Sam', 'Rita', null)));
select tests.as_superuser();
select tests.eq((select array[subject, body] from public.messages where id = tests.fx('m_gift')),
                array['A gift card from Sam',
                      E'Hi Alice,\n\nSam sent you a Shop A gift card worth $50.00.\n\nYour gift card code: ABCD-EFGH-JKLM-NPQR\n\nShow this code when you pay, or enter it when paying an invoice online.\n\nShop A'],
                'gift card email (no personal message: that line and its blank line are left out; no phone: no phone line)');
select tests.as_service();
select tests.eq(pg_temp.body_of(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'),
                   'gift_card_delivery', 'email', null,
                   public.gift_card_delivery_vars(tests.fx('shop_a'), 'ABCD-EFGH-JKLM-NPQS', 5000, null, null, 'Happy birthday!'))),
                E'Hi Alice,\n\nShop A sent you a Shop A gift card worth $50.00.\n\nHappy birthday!\n\nYour gift card code: ABCD-EFGH-JKLM-NPQS\n\nShow this code when you pay, or enter it when paying an invoice online.\n\nShop A',
                'with a personal message; the sender defaults to the shop');
-- referral reward (money 0069)
select tests.eq(array[pg_temp.body_of(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'referral_reward', 'sms', null,
                        '{"credit_amount": "$20.00", "gift_card_code": "CRED-1234-5678-9ABC", "referee_first_name": null}')),
                      pg_temp.body_of(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'referral_reward', 'email', null,
                        '{"credit_amount": "$20.00", "gift_card_code": "CRED-1234-5678-9ABC", "referee_first_name": "Nina"}'))],
                array[E'Hi Alice, thank you for referring a friend to Shop A! You earned store credit: $20.00.\nYour credit code: CRED-1234-5678-9ABC',
                      E'Hi Alice,\n\nThank you for referring a friend to Shop A!\n\nNina just completed their first visit with us.\n\nYou earned store credit: $20.00\nYour credit code: CRED-1234-5678-9ABC\n\nShow this code when you pay, or enter it when paying an invoice online.\n\nShop A'],
                'referral reward on both channels');
-- job report (ops 0072 passes report_link)
select tests.eq(pg_temp.body_of(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'),
                   'job_report', 'sms', tests.fx('job_a'), '{"report_link": "https://app.example.test/r/abc"}')),
                'Hi Alice, your job report from Shop A is ready. See the photos and details here: https://app.example.test/r/abc',
                'job report text');
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_report', 'sms', tests.fx('job_a')), null,
                'without a report link there is nothing to send');
-- lead received (0088)
select tests.eq(pg_temp.body_of(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'),
                   'lead_received', 'sms')),
                'Hi Alice, thanks for reaching out to Shop A! We received your request and will get back to you shortly.',
                'lead auto-reply (no phone line without a shop phone)');
