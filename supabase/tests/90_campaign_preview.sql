-- 90 integration: preview_campaign_message — the campaign text rendered as
-- launch_campaign renders it (placeholder recipient names), the SMS opt-out
-- footer and the length limit that follows from it, email unsubscribe
-- footer, truncation, validation and the role matrix.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');
update public.shops set phone = '+12055550199' where id = tests.fx('shop_a');

select tests.authenticate_as(tests.fx('u_manager_a'));
-- ------------------------------------------------------------ SMS without an opt-out instruction: footer added
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'sms',
                  'Hi {{customer_first_name}}! Spring special at {{shop_name}}: {{booking_page_link}}'),
                jsonb_build_object(
                  'subject', null,
                  'body', E'Hi [first name]! Spring special at Shop A: https://app.example.test/book/shop-a\nReply STOP to opt out.',
                  'body_length', char_length('Hi [first name]! Spring special at Shop A: https://app.example.test/book/shop-a'),
                  'max_body_length', 1600 - char_length(E'\nReply STOP to opt out.'),
                  'footer_added', true,
                  'truncated', false,
                  'postal_address_missing', false),
                'rendered with placeholder names; the opt-out line is appended and shortens the limit');
-- SMS that already tells how to opt out: no footer, full limit
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'Deal for {{customer_name}}. Text STOP to end.')
                  - 'body_length',
                '{"subject": null, "body": "Deal for [name]. Text STOP to end.", "max_body_length": 1600, "footer_added": false, "truncated": false, "postal_address_missing": false}'::jsonb,
                'an opt-out instruction in the wording: kept as is');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'Stop by Saturday!') -> 'footer_added', 'true'::jsonb,
                'merely using the word STOP is not an instruction');
-- the limit is exact and truncation is reported
select tests.eq((select jsonb_build_array(r -> 'body_length', r -> 'truncated', char_length(r ->> 'body'))
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'sms', repeat('a', 1577)) r) x),
                '[1577, false, 1600]'::jsonb, 'exactly at the limit: body + footer = 1600');
select tests.eq((select jsonb_build_array(r -> 'body_length', r -> 'max_body_length', r -> 'truncated', char_length(r ->> 'body'),
                                          right(r ->> 'body', 22))
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'sms', repeat('a', 1578)) r) x),
                '[1578, 1577, true, 1600, "Reply STOP to opt out."]'::jsonb, 'one over: truncated, the footer still fits');
select tests.eq((select jsonb_build_array(r -> 'max_body_length', r -> 'truncated', char_length(r ->> 'body'))
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'sms', repeat('b', 1700) || ' Reply STOP to quit') r) x),
                '[1577, true, 1600]'::jsonb, 'an instruction beyond the 1600th character does not count');
select tests.eq((select jsonb_build_array(r ->> 'body', r -> 'body_length', r -> 'footer_added')
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'sms', '   ') r) x),
                '["", 0, false]'::jsonb, 'a blank body renders empty');

-- ------------------------------------------------------------ email: unsubscribe footer, subject
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello {{customer_first_name}}, call {{shop_phone}}.',
                                                'News from {{shop_name}}'),
                jsonb_build_object(
                  'subject', 'News from Shop A',
                  'body', E'Hello [first name], call (205) 555-0199.\n\nTo unsubscribe from these emails, visit: [unsubscribe link]',
                  'body_length', char_length('Hello [first name], call (205) 555-0199.'),
                  'max_body_length', 50000 - char_length(E'\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/00000000-0000-0000-0000-000000000000'),
                  'footer_added', false, 'truncated', false,
                  'postal_address_missing', true),
                'email: the unsubscribe footer is shown with a placeholder link; the limit leaves room for the real one (0127); no postal address on file');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Bye: {{unsubscribe_link}}') ->> 'body',
                'Bye: [unsubscribe link]', 'the wording may place the link itself');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hi') ->> 'subject', 'Shop A',
                'no subject: the shop name (as sent)');
select tests.eq((select jsonb_build_array(r -> 'truncated', char_length(r ->> 'body'))
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'email', repeat('e', 50000)) r) x),
                '[true, 50000]'::jsonb, '50000 characters are allowed, but cut to make room for the footer (0127)');
select tests.throws_like($$select public.preview_campaign_message(tests.fx('shop_a'), 'email', repeat('e', 50001))$$, '22023', '%too long%',
                         'longer bodies are refused');
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', repeat('e', 50001))$$, '22023',
                    'for SMS too');
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), null, 'x')$$, '22023', 'a channel is required');
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), 'email', 'x', repeat('s', 501))$$, '22023',
                    'subject length');
-- the preview matches what launch_campaign queues (render path)
insert into public.customers (shop_id, first_name, phone, sms_opt_in) values (tests.fx('shop_a'), 'Zoe', '+12055550142', true)
  returning tests.fx_set('cust_z', id);
select tests.as_superuser();
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body)
  values (tests.fx('shop_a'), 'Spring', 'sms', 'Spring special at {{shop_name}}: {{booking_page_link}}') returning tests.fx_set('camp', id);
select public.launch_campaign(tests.fx('camp'));
select tests.eq((select body from public.messages where campaign_id = tests.fx('camp') and customer_id = tests.fx('cust_z')),
                public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'Spring special at {{shop_name}}: {{booking_page_link}}') ->> 'body',
                'the preview is exactly the text queued (no recipient placeholders used)');

-- ------------------------------------------------------------ roles
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'x')$$, 'owners');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'x')$$, 'admins');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'x')$$, '42501', 'technicians are refused');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'x')$$, '42501', 'another shop is refused');
select tests.eq(public.preview_campaign_message(tests.fx('shop_b'), 'sms', '{{shop_name}}') ->> 'body',
                E'Shop B\nReply STOP to opt out.', 'shop B previews with its own variables');
select tests.as_anon();
select tests.throws($$select public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'x')$$, '42501', 'anon cannot execute');
