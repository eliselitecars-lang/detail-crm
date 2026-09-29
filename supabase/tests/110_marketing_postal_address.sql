-- 110 (0119): every marketing email — campaigns and the promotional
-- follow-up templates — ends with the shop's postal address (CAN-SPAM);
-- without an address on file an email campaign cannot launch
-- (55000 HINT postal_address_required) and other marketing email is not
-- queued. Texts and transactional email are unchanged.
\ir fixtures/two_shops.psql

select tests.as_superuser();
insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
  on conflict (key) do update set value = excluded.value;
insert into public.shop_sms_numbers (phone_number, shop_id) values ('+12055550100', tests.fx('shop_a'));
update public.shops set sms_from_number = '+12055550100' where id = tests.fx('shop_a');
update public.customers set phone = '+12055550150', sms_opt_in = true, email_opt_in = true where id = tests.fx('cust_a');
update public.message_templates set enabled = true where shop_id = tests.fx('shop_a') and key = 'follow_up';
-- online booking on, so the follow-up's {{booking_page_link}} is live
update public.booking_settings set enabled = true where shop_id = tests.fx('shop_a');

-- ============================================================ the address line
select tests.as_service();
select tests.eq(public.comms_shop_postal_address(tests.fx('shop_a')), null::text, 'no address on file: none');
select tests.as_superuser();
update public.shops set address_line1 = '100 Main St', city = 'Birmingham' where id = tests.fx('shop_a');
select tests.as_service();
select tests.eq(public.comms_shop_postal_address(tests.fx('shop_a')), '100 Main St, Birmingham', 'street and city suffice');
select tests.as_superuser();
update public.shops set address_line1 = ' 100 Main St ', address_line2 = 'Suite 4', region = 'AL', postal_code = '35203'
 where id = tests.fx('shop_a');
update public.shops set address_line1 = '1 King St W', city = 'Toronto', region = 'ON', postal_code = 'M5H 1A1', country = 'CA'
 where id = tests.fx('shop_b');
select tests.as_service();
select tests.eq(public.comms_shop_postal_address(tests.fx('shop_a')), '100 Main St, Suite 4, Birmingham, AL 35203', 'the full US address');
select tests.eq(public.comms_shop_postal_address(tests.fx('shop_b')), '1 King St W, Toronto, ON M5H 1A1, CA', 'the country outside the US');
select tests.as_superuser();
update public.shops set city = '  ' where id = tests.fx('shop_b');
select tests.as_service();
select tests.eq(public.comms_shop_postal_address(tests.fx('shop_b')), null::text, 'no city: no usable address');

select tests.eq(public.comms_email_with_postal_address('Hello', 'Shop A', '1 Main St, Town'), E'Hello\n\nShop A · 1 Main St, Town',
                'the footer is appended');
select tests.eq(public.comms_email_with_postal_address(E'Hello\nVisit us at 1 Main St, Town', 'Shop A', '1 Main St, Town'),
                E'Hello\nVisit us at 1 Main St, Town', 'not repeated when the wording shows the address');
select tests.eq(public.comms_email_with_postal_address('Hello', 'Shop A', null), 'Hello', 'unchanged without an address');
select tests.eq(char_length(public.comms_email_with_postal_address(repeat('x', 50000), 'Shop A', '1 Main St, Town')), 50000,
                'the body is cut to keep the 50000-character limit');
select tests.ok(public.comms_email_with_postal_address(repeat('x', 50000), 'Shop A', '1 Main St, Town') like '%Shop A · 1 Main St, Town',
                'and still ends with the address');

-- internal only
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.comms_shop_postal_address(tests.fx('shop_b'))$$, '42501', 'not callable by staff');
select tests.throws($$select public.comms_email_with_postal_address('a', 'b', 'c')$$, '42501', 'nor the footer helper');

-- ============================================================ email campaigns
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body, audience)
  values (tests.fx('shop_a'), 'News', 'email', 'News from {{shop_name}}', 'Hi {{customer_first_name}}, new packages are here.', '{}')
  returning tests.fx_set('camp_mail', id);
select tests.eq(tests.row_count($$select public.launch_campaign(tests.fx('camp_mail'))$$), 1::bigint, 'with an address it launches');
select tests.as_superuser();
select tests.eq((select body from public.messages where campaign_id = tests.fx('camp_mail') and to_address = 'alice@example.com'),
                E'Hi Alice, new packages are here.\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/'
                  || (select unsubscribe_token::text from public.messages
                       where campaign_id = tests.fx('camp_mail') and to_address = 'alice@example.com')
                  || E'\n\nShop A · 100 Main St, Suite 4, Birmingham, AL 35203',
                'each email ends with the opt-out, then the shop''s postal address');

-- no address on file: the launch is refused and nothing is queued
update public.shops set address_line1 = null where id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, subject, body, audience)
  values (tests.fx('shop_a'), 'More news', 'email', 'More', 'Hi again.', '{}')
  returning tests.fx_set('camp_mail2', id);
select tests.throws_like($$select public.launch_campaign(tests.fx('camp_mail2'))$$, '55000',
                         'add your shop''s mailing address (Settings → Business profile) before sending marketing email: the law requires it in every marketing email',
                         'an email campaign needs the shop''s postal address');
create function pg_temp.hint_of(p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return v_hint;
end
$$;
select tests.eq(pg_temp.hint_of($$select public.launch_campaign(tests.fx('camp_mail2'))$$), 'postal_address_required',
                'HINT postal_address_required');
select tests.as_superuser();
select tests.eq((select status::text from public.campaigns where id = tests.fx('camp_mail2')), 'draft', 'still a draft');
select tests.eq((select count(*) from public.messages where campaign_id = tests.fx('camp_mail2')), 0::bigint, 'nothing queued');

-- text campaigns need no postal address
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.campaigns (shop_id, name, channel, body, audience)
  values (tests.fx('shop_a'), 'Text', 'sms', 'Deal this week at {{shop_name}}', '{}')
  returning tests.fx_set('camp_sms', id);
select tests.eq((public.launch_campaign(tests.fx('camp_sms'))).status::text, 'launched', 'a text campaign still launches');
select tests.as_superuser();
select tests.ok((select bool_and(body not like '%Main St%') from public.messages where campaign_id = tests.fx('camp_sms')),
                'texts carry no address');

-- ============================================================ marketing templates (follow-up)
select tests.as_service();
select tests.eq(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')),
                null::uuid, 'no address: the follow-up email is not queued');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_a') and template_key = 'follow_up'
                  and channel = 'email'), 0::bigint, 'no row at all');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'sms', tests.fx('job_a')) is not null,
                'the follow-up text still goes out');
select tests.ok(public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'job_completed', 'email', tests.fx('job_a')) is not null,
                'transactional email is unaffected');
select tests.as_superuser();
update public.shops set address_line1 = '100 Main St' where id = tests.fx('shop_a');
select tests.as_service();
select tests.fx_set('fu', public.enqueue_customer_template(tests.fx('shop_a'), tests.fx('cust_a'), 'follow_up', 'email', tests.fx('job_a')));
select tests.ok((select body like E'%\n\nTo unsubscribe from these emails, visit: https://app.example.test/u/%'
                                 || E'\n\nShop A · 100 Main St, Suite 4, Birmingham, AL 35203'
                   from public.messages where id = tests.fx('fu')),
                'with an address the follow-up email ends with it');
select tests.ok((select body not like '%Main St%' from public.messages
                  where customer_id = tests.fx('cust_a') and template_key = 'job_completed' and channel = 'email'),
                'transactional email carries no address footer');
