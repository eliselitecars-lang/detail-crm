-- 127 (0127): email previews carry the postal-address footer marketing
-- email is queued with (0119) and say when the shop has no address on file;
-- SMS and transactional templates are unchanged.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
update public.shops set address_line1 = '100 Main St', city = 'Birmingham', region = 'AL', postal_code = '35203'
 where id = tests.fx('shop_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
update public.customers set email_opt_in = true where id = tests.fx('cust_a');
select set_config('x.footer', E'\n\nShop A · 100 Main St, Birmingham, AL 35203', false);

-- ============================================================ campaign preview, address on file
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello {{customer_first_name}}', 'News') ->> 'body',
                E'Hello [first name]\n\nTo unsubscribe from these emails, visit: [unsubscribe link]' || current_setting('x.footer'),
                'the email preview ends with the unsubscribe line, then the postal footer');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello') -> 'postal_address_missing', 'false'::jsonb,
                'address on file: not missing');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello') -> 'max_body_length',
                to_jsonb(50000 - char_length(E'\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/00000000-0000-0000-0000-000000000000')
                               - char_length(current_setting('x.footer'))),
                'the limit leaves room for both footers');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Visit us at 100 Main St, Birmingham, AL 35203!') ->> 'body',
                E'Visit us at 100 Main St, Birmingham, AL 35203!\n\nTo unsubscribe from these emails, visit: [unsubscribe link]',
                'wording that already shows the address gets no second copy (as queued)');
select tests.eq((select jsonb_build_array(r -> 'truncated', char_length(r ->> 'body'), right(r ->> 'body', char_length(current_setting('x.footer'))))
                   from (select public.preview_campaign_message(tests.fx('shop_a'), 'email', repeat('e', 49950)) r) x),
                jsonb_build_array(true, 50000, current_setting('x.footer')), 'a long body is cut and the footer still fits');

-- the footer is exactly the one the queued campaign email gets
insert into public.campaigns (shop_id, name, channel, subject, body)
  values (tests.fx('shop_a'), 'Spring', 'email', 'Spring', 'Hello {{customer_first_name}}') returning tests.fx_set('camp', id);
select public.launch_campaign(tests.fx('camp'));
select tests.as_superuser();
select tests.eq((select right(body, char_length(current_setting('x.footer'))) from public.messages
                  where campaign_id = tests.fx('camp') and customer_id = tests.fx('cust_a')),
                current_setting('x.footer'), 'the queued campaign email ends with the same footer');
select tests.eq((select regexp_replace(body, '/u/[0-9a-f-]{36}', '/u/X') from public.messages
                  where campaign_id = tests.fx('camp') and customer_id = tests.fx('cust_a')),
                E'Hello Alice\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/X' || current_setting('x.footer'),
                'and the same text but for the recipient and the real link');

-- ============================================================ template preview
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select right(body, char_length(current_setting('x.footer'))) || '|' || postal_address_missing::text
                   from public.preview_template_message(tests.fx('job_a'), 'follow_up', 'email')),
                current_setting('x.footer') || '|false', 'a marketing template''s email preview ends with the footer');
select tests.as_service();
select tests.fx_set('fu', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')));
select tests.as_superuser();
select tests.eq((select right(body, char_length(current_setting('x.footer'))) from public.messages where id = tests.fx('fu')),
                current_setting('x.footer'), 'as the queued follow-up does');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok((select body not like '%100 Main St%' and not postal_address_missing
                   from public.preview_template_message(tests.fx('job_a'), 'booking_confirmed', 'email')),
                'a transactional email preview is unchanged');
select tests.ok((select body not like '%100 Main St%' and not postal_address_missing
                   from public.preview_template_message(tests.fx('job_a'), 'follow_up', 'sms')),
                'an SMS preview is unchanged');

-- ============================================================ no address on file
select tests.as_superuser();
update public.shops set address_line1 = null where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello') -> 'postal_address_missing', 'true'::jsonb,
                'campaign preview: the address is missing');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'email', 'Hello') ->> 'body',
                E'Hello\n\nTo unsubscribe from these emails, visit: [unsubscribe link]', 'no footer to show');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'Hello') -> 'postal_address_missing', 'false'::jsonb,
                'SMS campaigns need no postal address');
select tests.eq(public.preview_campaign_message(tests.fx('shop_a'), 'sms', 'Hello') ->> 'body', E'Hello\nReply STOP to opt out.',
                'SMS preview unchanged');
select tests.ok((select postal_address_missing from public.preview_template_message(tests.fx('job_a'), 'follow_up', 'email')),
                'template preview: missing for a marketing email');
select tests.ok((select not postal_address_missing from public.preview_template_message(tests.fx('job_a'), 'invoice_sent', 'email')),
                'not for a transactional one');

-- grants unchanged
select tests.as_superuser();
select tests.ok(has_function_privilege('authenticated', 'public.preview_template_message(uuid, public.message_template_key, public.message_channel)', 'execute')
                and not has_function_privilege('anon', 'public.preview_template_message(uuid, public.message_template_key, public.message_channel)', 'execute'),
                'preview_template_message: authenticated, not anon');
