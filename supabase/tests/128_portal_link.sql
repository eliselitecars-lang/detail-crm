-- 128 (0128): {{portal_link}} — the client portal, opened on the shop — in
-- every customer message; the default membership welcome says how to
-- manage or cancel the membership.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;

-- ============================================================ the variable
select tests.eq(public.comms_customer_vars(tests.fx('shop_a'), tests.fx('cust_a')) ->> 'portal_link',
                'https://app.example.test/portal?shop=shop-a', 'portal_link = APP_BASE_URL/portal?shop=<slug>');
select tests.eq(public.comms_customer_vars(tests.fx('shop_b'), null) ->> 'portal_link',
                'https://app.example.test/portal?shop=shop-b', 'per shop, also without a customer (campaign previews)');
select tests.eq(public.comms_job_vars(tests.fx('job_a')) ->> 'portal_link',
                'https://app.example.test/portal?shop=shop-a', 'job messages have it too');
select tests.ok('portal_link' = any (public.comms_v2_optional_vars()), 'an optional placeholder');
select tests.ok(public.comms_uses_app_links('See {{ portal_link }}'), 'an app link (never queued without app_base_url)');
-- a line using it without a value is left out
select tests.eq(public.comms_omit_lines_without(E'Welcome!\n\nManage it here: {{portal_link}}\n\nThanks',
                                                '{"shop_name": "Shop A"}'::jsonb, public.comms_v2_optional_vars()),
                E'Welcome!\n\nThanks', 'the line (and its blank separator) is omitted when portal_link has no value');
select tests.eq(public.comms_omit_lines_without(E'Welcome!\nManage it here: {{portal_link}}',
                                                '{"portal_link": "https://x.test/portal"}'::jsonb, public.comms_v2_optional_vars()),
                E'Welcome!\nManage it here: {{portal_link}}', 'kept when it has one');

-- ============================================================ membership_welcome defaults
select tests.ok((select bool_and(body like '%Manage or cancel your membership any time in your account: {{portal_link}}%')
                   and count(*) = 2
                   from public.default_message_templates() where key = 'membership_welcome'),
                'both default channels carry the manage / cancel line');
select tests.ok((select bool_and(body like '%{{portal_link}}%') and count(*) = 2 from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'membership_welcome'),
                'a new shop is seeded with it');
select tests.eq((select count(*) from public.default_message_templates() where body like '%portal_link%'), 2::bigint,
                'no other default changed');

-- the queued welcome renders the link
update public.shops set phone = '+12055550199' where id = tests.fx('shop_a');
select tests.as_service();
select tests.fx_set('welcome', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'email'));
select tests.as_superuser();
select tests.ok((select body like E'%\n\nManage or cancel your membership any time in your account: https://app.example.test/portal?shop=shop-a\n\n%'
                   from public.messages where id = tests.fx('welcome')),
                'the welcome email links to the portal');

-- an edited template keeps its wording; reset brings the new default
select tests.as_superuser();
update public.message_templates set body = 'Welcome aboard, {{customer_first_name}}!'
 where shop_id = tests.fx('shop_a') and key = 'membership_welcome' and channel = 'sms'
 returning tests.fx_set('tpl_sms', id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.ok((public.reset_message_template(tests.fx('tpl_sms'))).body like '%{{portal_link}}%',
                'reset_message_template brings the new default wording');

-- without app_base_url the app links are unavailable: nothing is queued
select tests.as_superuser();
delete from public.platform_config where key = 'app_base_url';
select tests.eq(public.comms_customer_vars(tests.fx('shop_a'), tests.fx('cust_a')) -> 'portal_link', 'null'::jsonb,
                'no base URL: no link');
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'membership_welcome', 'email'),
                null::uuid, 'a message that would carry a blank app link is not queued');
