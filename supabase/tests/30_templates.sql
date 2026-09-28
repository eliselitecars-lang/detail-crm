-- 30 comms: message_templates (per-shop seeding, placeholders, constraints,
-- offset sync, reset, role rules, cross-shop isolation) and render_template
-- (parity with supabase/functions/_shared/templates.ts).
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ seeding
select tests.eq((select count(*) from public.default_message_templates()), 40::bigint, 'defaults: 40 key/channel rows');
select tests.eq((select count(distinct key) from public.default_message_templates()), 22::bigint,
                'defaults cover every template key');
-- (0083 writes the wording of every key, including money's
-- gift_card_delivery / referral_reward and ops' job_report)
select tests.eq((select array_agg(distinct k::text order by k::text) from unnest(enum_range(null::public.message_template_key)) k),
                (select array_agg(distinct key::text order by key::text) from public.default_message_templates()),
                'every enum key has default wording');
select tests.eq((select count(*) from public.message_templates where shop_id = tests.fx('shop_a')), 40::bigint,
                'shop A seeded with every default');
select tests.eq((select count(*) from public.message_templates where shop_id = tests.fx('shop_b')), 40::bigint,
                'shop B seeded with every default');
select tests.ok((select bool_and(offset_minutes = -1440) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'), 'reminder 24h before');
select tests.ok((select bool_and(offset_minutes = 120) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'review_request'), 'review request 2h after');
select tests.ok((select bool_and(offset_minutes = 43200 and not enabled) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'follow_up'), 'follow-up 30 days after, off by default');
select tests.ok((select bool_and(offset_minutes is null) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key not in ('appointment_reminder', 'review_request', 'follow_up')),
                'event templates have no offset');
select tests.eq((select array_agg(channel::text order by channel) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'invite'), array['email'], 'invite is email only');
select tests.eq((select array_agg(channel::text order by channel) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'on_the_way'), array['sms'], 'on the way is sms only');
-- every placeholder used by the defaults is a documented variable
select tests.eq((
  select coalesce(array_agg(distinct m[1] order by m[1]), '{}')
    from public.default_message_templates() d,
         regexp_matches(coalesce(d.subject, '') || ' ' || d.body, '\{\{[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\}\}', 'g') m
   where m[1] <> all (array['customer_first_name', 'customer_name', 'shop_name', 'shop_phone', 'job_date', 'job_time',
                            'job_number', 'vehicle', 'services', 'booking_link', 'booking_page_link', 'quote_link',
                            'invoice_link', 'review_link', 'amount', 'balance', 'invite_link', 'unsubscribe_link',
                            -- v2 (0083)
                            'quote_number', 'quote_total', 'valid_until', 'invoice_number', 'due_date', 'days_overdue',
                            'deposit_due', 'deposit_link', 'rebook_link', 'report_link', 'gift_card_code',
                            'gift_card_amount', 'sender_name', 'recipient_name', 'gift_message', 'credit_amount',
                            'referee_first_name'])),
  '{}'::text[], 'defaults only use documented placeholders');
select tests.ok((select bool_and(char_length(body) <= 320) from public.default_message_templates() where channel = 'sms'),
                'default texts stay short (≤ 2 segments of text)');

-- a shop created later is seeded too
select tests.fx_set('shop_c', tests.make_shop('owner-c@test.local', 'shop-c', 'Shop C'));
select tests.eq((select count(*) from public.message_templates where shop_id = tests.fx('shop_c')), 40::bigint,
                'new shops are seeded');

-- ------------------------------------------------------------ roles
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$select 1 from public.message_templates$$), 40::bigint, 'managers read their templates');
select tests.eq(tests.row_count($$update public.message_templates set enabled = false where shop_id = tests.fx('shop_a')$$),
                0::bigint, 'managers cannot edit templates');
select tests.throws($$insert into public.message_templates (shop_id, key, channel, body)
                      values (tests.fx('shop_a'), 'on_the_way', 'email', 'x')$$, '42501', 'managers cannot add templates');
select tests.eq(tests.row_count($$delete from public.message_templates$$), 0::bigint, 'managers cannot delete templates');
select tests.throws($$select public.reset_message_template((select id from public.message_templates
                      where key = 'booking_confirmed' and channel = 'sms'))$$, '42501', 'managers cannot reset templates');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.message_templates$$), 0::bigint, 'technicians do not read templates');
select tests.eq(tests.row_count($$update public.message_templates set enabled = false$$), 0::bigint, 'technicians cannot edit');
select tests.throws($$select public.reset_message_template((select id from public.message_templates
                      where shop_id = tests.fx('shop_a') limit 1))$$, 'P0002', 'technicians cannot reset (not found)');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$update public.message_templates
                                   set body = '  Hi {{customer_first_name}}, see you {{job_date}}.  '
                                 where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'sms'$$),
                1::bigint, 'admins edit templates');
select tests.eq((select body from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'booking_confirmed' and channel = 'sms'),
                'Hi {{customer_first_name}}, see you {{job_date}}.', 'body is trimmed');
select tests.eq(tests.row_count($$update public.message_templates set enabled = false where shop_id = tests.fx('shop_b')$$),
                0::bigint, 'admins cannot edit another shop''s templates');
select tests.eq(tests.row_count($$select 1 from public.message_templates where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'admins cannot read another shop''s templates');
select tests.throws($$insert into public.message_templates (shop_id, key, channel, body)
                      values (tests.fx('shop_b'), 'on_the_way', 'email', 'x')$$, '42501',
                    'admins cannot add templates to another shop');
select tests.throws($$select public.reset_message_template((select id from public.message_templates t
                      where t.shop_id = tests.fx('shop_b') limit 1))$$, 'P0002', 'reset of another shop''s template: not found');
select tests.throws($$insert into public.message_templates (shop_id, key, channel, body)
                      values (tests.fx('shop_a'), 'booking_confirmed', 'sms', 'dup')$$, '23505', 'one row per key and channel');
select tests.throws($$update public.message_templates set key = 'job_started'
                      where shop_id = tests.fx('shop_a') and key = 'on_the_way'$$, '42501', 'key is immutable');
select tests.throws($$update public.message_templates set shop_id = tests.fx('shop_b')
                      where shop_id = tests.fx('shop_a') and key = 'on_the_way'$$, '42501', 'shop is immutable');

-- constraints
select tests.throws($$update public.message_templates set subject = 'Hi' where shop_id = tests.fx('shop_a') and key = 'on_the_way'$$,
                    '23514', 'texts have no subject');
select tests.throws($$update public.message_templates set subject = '  ' where shop_id = tests.fx('shop_a')
                      and key = 'quote_sent' and channel = 'email'$$, '23514', 'emails need a subject');
select tests.throws($$update public.message_templates set body = repeat('x', 1601) where shop_id = tests.fx('shop_a')
                      and key = 'on_the_way'$$, '23514', 'texts are at most 1600 characters');
select tests.throws($$update public.message_templates set body = ' ' where shop_id = tests.fx('shop_a') and key = 'on_the_way'$$,
                    '23514', 'body cannot be blank');
select tests.throws($$update public.message_templates set offset_minutes = 10 where shop_id = tests.fx('shop_a')
                      and key = 'on_the_way'$$, '23514', 'event templates take no offset');
select tests.throws($$update public.message_templates set offset_minutes = 60 where shop_id = tests.fx('shop_a')
                      and key = 'appointment_reminder' and channel = 'sms'$$, '23514', 'reminders are before the appointment');
select tests.throws($$update public.message_templates set offset_minutes = -5 where shop_id = tests.fx('shop_a')
                      and key = 'review_request' and channel = 'sms'$$, '23514', 'review requests are after completion');
select tests.throws($$update public.message_templates set offset_minutes = null where shop_id = tests.fx('shop_a')
                      and key = 'follow_up' and channel = 'sms'$$, '23514', 'time-based templates need an offset');
select tests.throws($$insert into public.message_templates (shop_id, key, channel, body)
                      values (tests.fx('shop_a'), 'invite', 'sms', 'Join us')$$, '23514', 'invites are email only');

-- all channels of a key share one schedule
select tests.lives($$update public.message_templates set offset_minutes = -120
                     where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'sms'$$);
select tests.eq((select array_agg(offset_minutes order by channel) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'), array[-120, -120],
                'changing one channel''s offset moves its siblings');
select tests.as_superuser();
select tests.eq((select offset_minutes from public.message_templates
                  where shop_id = tests.fx('shop_b') and key = 'appointment_reminder' and channel = 'email'), -1440,
                'other shops are unaffected');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count($$delete from public.message_templates
                                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email'$$),
                1::bigint, 'admins delete templates');
insert into public.message_templates (shop_id, key, channel, subject, body, offset_minutes)
  values (tests.fx('shop_a'), 'appointment_reminder', 'email', 'Reminder', 'See you {{job_date}}', -1440);
select tests.eq((select offset_minutes from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email'), -120,
                'a re-added channel adopts the key''s existing offset');

-- reset restores the defaults (and the shared offset)
select tests.eq((public.reset_message_template((select id from public.message_templates
                   where shop_id = tests.fx('shop_a') and key = 'appointment_reminder' and channel = 'email'))).body,
                (select body from public.default_message_templates() where key = 'appointment_reminder' and channel = 'email'),
                'reset restores the default wording');
select tests.eq((select array_agg(offset_minutes order by channel) from public.message_templates
                  where shop_id = tests.fx('shop_a') and key = 'appointment_reminder'), array[-1440, -1440],
                'reset restores the default offset on every channel');

-- owners manage templates as well
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$insert into public.message_templates (shop_id, key, channel, subject, body)
                     values (tests.fx('shop_a'), 'on_the_way', 'email', 'On the way', 'Hi {{customer_first_name}}, we are on the way.')$$,
                   'owners add a missing channel');

select tests.as_anon();
select tests.throws($$select public.reset_message_template(gen_random_uuid())$$, '42501', 'anon cannot reset templates');
select tests.throws($$select public.render_template('x', '{}')$$, '42501', 'anon cannot call render_template');
select tests.as_superuser();

-- ------------------------------------------------------------ render_template
select tests.eq(public.render_template('Hi {{name}}!', '{"name": "Al"}'), 'Hi Al!', 'basic substitution');
select tests.eq(public.render_template(E'{{ name }} {{\tname\t}} {{name  }}', '{"name": "Al"}'), 'Al Al Al',
                'spaces and tabs inside braces');
select tests.eq(public.render_template('[{{missing}}]', '{"name": "Al"}'), '[]', 'unknown placeholders render empty');
select tests.eq(public.render_template('[{{name}}]', '{"name": null}'), '[]', 'null renders empty');
select tests.eq(public.render_template('{{n}} {{f}} {{t}} {{no}}', '{"n": 42, "f": 1.5, "t": true, "no": false}'),
                '42 1.5 true false', 'numbers and booleans in JSON form');
select tests.eq(public.render_template('[{{o}}][{{a}}]', '{"o": {"x": 1}, "a": [1]}'), '[][]', 'objects and arrays render empty');
select tests.eq(public.render_template('{{a}}', '{"a": "{{b}}", "b": "x"}'), '{{b}}', 'single pass: values are not re-scanned');
select tests.eq(public.render_template('{{ a b }} {x} {{}} {{1a}}', '{"a": "x", "1a": "y"}'), '{{ a b }} {x} {{}} {{1a}}',
                'malformed placeholders are left untouched');
select tests.eq(public.render_template('{{{a}}}', '{"a": "x"}'), '{x}', 'extra braces around a placeholder stay');
select tests.eq(public.render_template('{{Name}}', '{"name": "Al"}'), '', 'names are case-sensitive');
select tests.eq(public.render_template('{{a}}{{b}}', '{"a": "1", "b": "2"}'), '12', 'adjacent placeholders');
select tests.eq(public.render_template(E'{{a}}\nmiddle\n{{a}}', '{"a": "x"}'), E'x\nmiddle\nx', 'placeholders at both ends, newlines kept');
select tests.eq(public.render_template('{{a}}', '{"a": "\\1 $& $1 \\\\"}'), '\1 $& $1 \\', 'values are inserted literally');
select tests.eq(public.render_template('no placeholders', '{"a": "x"}'), 'no placeholders', 'plain text unchanged');
select tests.eq(public.render_template('', '{}'), '', 'empty body');
select tests.eq(public.render_template(null, '{"a": "x"}'), null::text, 'null body renders null');
select tests.eq(public.render_template('[{{a}}]', null), '[]', 'null vars never error');
select tests.eq(public.render_template('[{{a}}]', '[1, 2]'), '[]', 'non-object vars never error');
select tests.eq(public.render_template('[{{a}}]', '"x"'), '[]', 'scalar vars never error');
select tests.eq(public.render_template('{{_a1}} {{a_}}', '{"_a1": "p", "a_": "q"}'), 'p q', 'underscores and digits in names');
select tests.eq(public.render_template('Price: {{amount}}', '{"amount": "$1,234.56"}'), 'Price: $1,234.56', 'money strings verbatim');
select tests.eq(public.render_template('{{a}} ☃ {{a}}', '{"a": "é"}'), 'é ☃ é', 'unicode');
