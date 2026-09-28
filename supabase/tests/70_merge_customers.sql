-- 70 ops: merge duplicate customers (P-20) — the guards still refuse the
-- same moves outside a merge (client context, or trusted code without the
-- merge setting), owner/admin only, preview counts and conflicts, a full
-- move (vehicles, jobs with an inspection and forms, quotes, invoices,
-- payments incl. a deposit, memberships, saved cards, messages, the
-- automation log, campaign duplicates, once-per-customer coupons,
-- customer-specific coupons, calendar events, notifications, documents),
-- links and queued reminders kept, the customer field rules (tags, notes,
-- empty fields, lifecycle, consent), the archived duplicate, refused merges
-- (portal accounts, open memberships, archived / merged customers) and
-- two-shop isolation.
\ir fixtures/two_shops.psql

-- ============================================================ fixture: the duplicate (source) of cust_a (target)
select tests.as_superuser();
select tests.fx_set('u_client', tests.create_user('ally@example.com'));
update public.customers
   set tags = '{vip}', notes = 'Prefers mornings', email_opt_in = true, sms_opt_in = false,
       stripe_customer_id = 'cus_TGT', lifecycle = 'customer'
 where id = tests.fx('cust_a');
insert into public.customers (shop_id, first_name, company, email, phone, address_line1, city, postal_code, lat, lng,
                              tags, notes, lifecycle, sms_opt_in, email_opt_in, sms_opted_out_at, portal_user_id,
                              stripe_customer_id, referral_code, source)
  values (tests.fx('shop_a'), 'Ally', 'Anders LLC', 'ally@example.com', '+12055550188', '1 Main St', 'Hoover', '35226',
          33.4, -86.8, '{fleet,vip}', 'Gate code 99', 'lead', true, true, '2025-01-01Z', tests.fx('u_client'),
          'cus_SRC', 'ALLY10', 'google')
  returning tests.fx_set('src', id);
update public.customers set last_name = null where id = tests.fx('src');
select tests.fx_set('tgt', tests.fx('cust_a'));

insert into public.coupons (shop_id, code, kind, value, once_per_customer) values (tests.fx('shop_a'), 'ONCE', 'percent', 1000, true)
  returning tests.fx_set('coupon_once', id);
update public.jobs set coupon_id = tests.fx('coupon_once') where id = tests.fx('job_a');

select tests.authenticate_as(tests.fx('u_admin_a'));
insert into public.form_templates (shop_id, name, body, attach_to) values (tests.fx('shop_a'), 'Waiver', 'I agree', 'all_jobs')
  returning tests.fx_set('ft', id);
insert into public.form_templates (shop_id, name, body, attach_to, requires_signature)
  values (tests.fx('shop_a'), 'Ack', 'Noted', 'manual', false) returning tests.fx_set('ft2', id);

select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.vehicles (shop_id, customer_id, year, make, model) values (tests.fx('shop_a'), tests.fx('src'), 2020, 'Kia', 'Soul')
  returning tests.fx_set('veh_s', id);
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('src'), tests.fx('veh_s'), '2030-06-02 15:00Z', '2030-06-02 17:00Z')
  returning tests.fx_set('job_s', id);
insert into public.job_line_items (shop_id, job_id, service_id, vehicle_id, name, unit_price_cents)
  values (tests.fx('shop_a'), tests.fx('job_s'), tests.fx('svc_a'), tests.fx('veh_s'), 'Full Detail', 20000);
insert into public.job_assignments (shop_id, job_id, member_id) values (tests.fx('shop_a'), tests.fx('job_s'), tests.fx('m_tech_a'));
insert into public.inspections (shop_id, job_id, vehicle_id, kind) values (tests.fx('shop_a'), tests.fx('job_s'), tests.fx('veh_s'), 'pre');
-- a second job: completed and invoiced, with a signed form
insert into public.jobs (shop_id, customer_id, vehicle_id, scheduled_start, scheduled_end, status, coupon_id)
  values (tests.fx('shop_a'), tests.fx('src'), tests.fx('veh_s'), '2025-05-02 15:00Z', '2025-05-02 17:00Z', 'completed',
          tests.fx('coupon_once'))
  returning tests.fx_set('job_s2', id);
insert into public.job_line_items (shop_id, job_id, name, unit_price_cents, taxable)
  values (tests.fx('shop_a'), tests.fx('job_s2'), 'Wash', 5000, false);
insert into public.form_submissions (shop_id, job_id, form_template_id) values (tests.fx('shop_a'), tests.fx('job_s2'), tests.fx('ft2'))
  returning tests.fx_set('fs_signed', id);
select public.sign_form_submission(tests.fx('fs_signed'), 'Ally');
select tests.fx_set('inv_s', (public.create_invoice_from_job(tests.fx('job_s2'))).id);
select public.mark_invoice_sent(tests.fx('inv_s'));
select tests.fx_set('pay_s', (public.record_manual_payment(tests.fx('inv_s'), 4500, 'cash')).id);
-- quotes: one sent, one viewed, one draft
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('src')) returning tests.fx_set('q_sent', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_sent'), 'Coat', 90000);
select public.mark_quote_sent(tests.fx('q_sent'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('src')) returning tests.fx_set('q_viewed', id);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q_viewed'), 'Tint', 30000);
select public.mark_quote_sent(tests.fx('q_viewed'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('src')) returning tests.fx_set('q_draft', id);
-- membership, calendar event, customer-specific coupon, customer document
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Monthly Wash', 4900)
  returning tests.fx_set('plan', id);
select tests.fx_set('mem_s', (public.create_membership(tests.fx('plan'), tests.fx('src'), tests.fx('veh_s'))).id);
insert into public.blocked_times (shop_id, starts_at, ends_at, kind, title, customer_id)
  values (tests.fx('shop_a'), '2030-07-01 15:00Z', '2030-07-01 16:00Z', 'consultation', 'Consult', tests.fx('src'))
  returning tests.fx_set('evt_s', id);
select tests.as_superuser();
insert into public.coupons (shop_id, code, kind, value, customer_id) values (tests.fx('shop_a'), 'ALLYONLY', 'percent', 500, tests.fx('src'))
  returning tests.fx_set('coupon_s', id);
insert into storage.objects (bucket_id, name) values
  ('documents', tests.fx('shop_a') || '/customers/' || tests.fx('src') || '/license.pdf'),
  ('documents', tests.fx('shop_a') || '/jobs/' || tests.fx('job_s') || '/quote.pdf');
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.documents (shop_id, customer_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('src'), tests.fx('shop_a') || '/customers/' || tests.fx('src') || '/license.pdf',
          'License.pdf', 'application/pdf', 100) returning tests.fx_set('doc_cust', id);
insert into public.documents (shop_id, job_id, storage_path, file_name, content_type, size_bytes)
  values (tests.fx('shop_a'), tests.fx('job_s'), tests.fx('shop_a') || '/jobs/' || tests.fx('job_s') || '/quote.pdf',
          'Quote.pdf', 'application/pdf', 100) returning tests.fx_set('doc_job', id);

-- server-side records: a deposit, saved cards, a queued reminder, the
-- automation log, a campaign that reached both, a once-per-customer coupon
-- used by both, a notification
select tests.as_service();
insert into public.payments (shop_id, job_id, kind, method, status, amount_cents, paid_at)
  values (tests.fx('shop_a'), tests.fx('job_s'), 'deposit', 'cash', 'succeeded', 2500, now()) returning tests.fx_set('dep_s', id);
insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id, brand, last4, is_default)
  values (tests.fx('shop_a'), tests.fx('src'), 'pm_src1', 'visa', '4242', true) returning tests.fx_set('pm_src', id);
insert into public.customer_payment_methods (shop_id, customer_id, stripe_payment_method_id, brand, last4, is_default)
  values (tests.fx('shop_a'), tests.fx('tgt'), 'pm_tgt1', 'visa', '1111', true) returning tests.fx_set('pm_tgt', id);
select tests.eq((select array_agg(stripe_customer_id order by stripe_payment_method_id) from public.customer_payment_methods
                  where shop_id = tests.fx('shop_a')),
                array['cus_SRC', 'cus_TGT'], 'a saved card remembers its owner''s Stripe customer');
insert into public.messages (shop_id, customer_id, job_id, direction, channel, to_address, subject, body, status, template_key, send_after)
  values (tests.fx('shop_a'), tests.fx('src'), tests.fx('job_s'), 'outbound', 'email', 'ally@example.com', 'Reminder', 'See you tomorrow',
          'queued', 'appointment_reminder', '2030-06-01 15:00Z') returning tests.fx_set('msg_s', id);
insert into public.job_automation_log (shop_id, job_id, customer_id, key, scheduled_for, due_at, processed_at, outcome, message_ids)
  values (tests.fx('shop_a'), tests.fx('job_s'), tests.fx('src'), 'appointment_reminder', '2030-06-02 15:00Z',
          '2030-06-01 15:00Z', now(), 'queued', array[tests.fx('msg_s')]) returning tests.fx_set('log_s', id);
select tests.as_superuser();
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Spring', 'email', 'Hi') returning tests.fx_set('camp', id);
insert into public.campaigns (shop_id, name, channel, body) values (tests.fx('shop_a'), 'Summer', 'email', 'Hi') returning tests.fx_set('camp2', id);
insert into public.campaign_recipients (shop_id, campaign_id, customer_id, to_address) values
  (tests.fx('shop_a'), tests.fx('camp'), tests.fx('src'), 'ally@example.com'),
  (tests.fx('shop_a'), tests.fx('camp'), tests.fx('tgt'), 'alice@example.com'),
  (tests.fx('shop_a'), tests.fx('camp2'), tests.fx('src'), 'ally@example.com');
select public.notify_shop_staff(tests.fx('shop_a'), array['owner']::public.shop_role[], 'general', 'About Ally',
                                p_customer_id => tests.fx('src'));
select tests.fx_set('form_s', (select id from public.form_submissions where job_id = tests.fx('job_s') and form_template_id = tests.fx('ft')));
select tests.fx_set('form_tok', (select public_token from public.form_submissions where id = tests.fx('form_s')));
select tests.fx_set('job_tok', (select public_token from public.jobs where id = tests.fx('job_s')));
select tests.fx_set('q_sent_tok', (select public_token from public.quotes where id = tests.fx('q_sent')));
select tests.fx_set('q_viewed_tok', (select public_token from public.quotes where id = tests.fx('q_viewed')));
select tests.as_anon();
select public.public_get_quote(tests.fx('q_viewed_tok'));
select tests.as_superuser();
create temp table before_merge as
  select (select appointment_set_at from public.jobs where id = tests.fx('job_s')) as set_at,
         (select sent_at from public.quotes where id = tests.fx('q_sent')) as q_sent_at,
         (select viewed_at from public.quotes where id = tests.fx('q_viewed')) as q_viewed_at,
         (select status from public.quotes where id = tests.fx('q_viewed')) as q_viewed_status;
grant select on before_merge to authenticated, service_role;
select tests.eq((select q_viewed_status from before_merge), 'viewed'::public.quote_status, 'the customer viewed the second quote');

-- ============================================================ the guards outside a merge
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.vehicles set customer_id = tests.fx('tgt') where id = tests.fx('veh_s')$$, '23514',
                         '%referenced%', 'a vehicle with history cannot move to another customer');
select set_config('detailcrm.customer_merge', 'on', true);
select tests.throws($$update public.vehicles set customer_id = tests.fx('tgt') where id = tests.fx('veh_s')$$, '23514',
                    'the merge setting is ignored for API writes');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('tgt') where id = tests.fx('job_s')$$, '23514',
                         '%inspection%', 'so is the job guard');
select tests.throws_like($$update public.jobs set customer_id = tests.fx('tgt') where id = tests.fx('job_s2')$$, '22023',
                         '%once per customer%', 'and the money guards');
select set_config('detailcrm.customer_merge', '', true);
select tests.as_service();
select tests.throws_like($$update public.jobs set customer_id = tests.fx('tgt') where id = tests.fx('job_s')$$, '23514',
                         '%inspection%', 'trusted code without the merge setting is refused too');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$update public.customers set merged_into_id = tests.fx('tgt') where id = tests.fx('src')$$, '42501',
                         '%merge_customers%', 'merged_into_id is server-set');
select tests.throws($$insert into public.customers (shop_id, first_name, merged_into_id) values (tests.fx('shop_a'), 'X', tests.fx('tgt'))$$,
                    '42501', 'also on insert');

-- ============================================================ roles
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.merge_customers(tests.fx('src'), tests.fx('tgt'))$$, '42501', 'managers cannot merge');
select tests.throws($$select public.merge_customers_preview(tests.fx('src'), tests.fx('tgt'))$$, '42501', 'nor preview');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.merge_customers(tests.fx('src'), tests.fx('tgt'))$$, '42501', 'technicians cannot');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.merge_customers(tests.fx('src'), tests.fx('tgt'))$$, 'P0002', 'another shop''s admin gets not found');
select tests.throws($$select public.merge_customers_preview(tests.fx('cust_b'), tests.fx('tgt'))$$, 'P0002',
                    'a target in another shop is not found');
select tests.throws($$select public.merge_customers(tests.fx('cust_b'), tests.fx('tgt'))$$, 'P0002', 'nor merged');
select tests.as_anon();
select tests.throws($$select public.merge_customers(tests.fx('src'), tests.fx('tgt'))$$, '42501', 'anon cannot');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.merge_customers(tests.fx('src'), tests.fx('src'))$$, '22023', 'not into itself');
select tests.throws($$select public.merge_customers(tests.fx('src'), null)$$, '22023', 'a target is required');
select tests.throws($$select public.merge_customers(gen_random_uuid(), tests.fx('tgt'))$$, 'P0002', 'unknown source');

-- ============================================================ preview
create temp table pv as select public.merge_customers_preview(tests.fx('src'), tests.fx('tgt')) as p;
select tests.eq((select p -> 'counts' from pv),
                '{"vehicles": 1, "jobs": 2, "series": 0, "events": 1, "quotes": 3, "invoices": 1, "payments": 2,
                  "memberships": 1, "saved_cards": 1, "messages": 1, "forms": 3, "documents": 2, "gift_cards": 0,
                  "coupons": 1}'::jsonb, 'what would move');
select tests.eq((select jsonb_agg(c ->> 'code' order by c ->> 'code') from pv, jsonb_array_elements(p -> 'conflicts') c),
                '["campaign_duplicates", "coupon_once", "default_card", "stripe_customers"]'::jsonb,
                'informational conflicts only');
select tests.eq((select jsonb_build_array(p -> 'can_merge', p -> 'source' ->> 'name', p -> 'target' ->> 'name',
                                          p -> 'source' -> 'portal_linked', p -> 'target' -> 'has_stripe_customer')
                   from pv),
                '[true, "Ally", "Alice Anders", true, true]'::jsonb, 'summaries of both customers');

-- ============================================================ merge
create temp table merged as select public.merge_customers(tests.fx('src'), tests.fx('tgt')) as m;
select tests.eq((select m from merged),
                jsonb_build_object('target_id', tests.fx('tgt'), 'moved', (select p -> 'counts' from pv)),
                'the merge reports what moved: the preview''s counts');
select tests.eq(current_setting('detailcrm.customer_merge', true), '', 'the merge setting ends with the call');

select tests.as_superuser();
select tests.eq((select count(*) from public.vehicles where customer_id = tests.fx('src'))
              + (select count(*) from public.jobs where customer_id = tests.fx('src'))
              + (select count(*) from public.quotes where customer_id = tests.fx('src'))
              + (select count(*) from public.invoices where customer_id = tests.fx('src'))
              + (select count(*) from public.payments where customer_id = tests.fx('src'))
              + (select count(*) from public.memberships where customer_id = tests.fx('src'))
              + (select count(*) from public.customer_payment_methods where customer_id = tests.fx('src'))
              + (select count(*) from public.messages where customer_id = tests.fx('src'))
              + (select count(*) from public.form_submissions where customer_id = tests.fx('src'))
              + (select count(*) from public.job_automation_log where customer_id = tests.fx('src'))
              + (select count(*) from public.campaign_recipients where customer_id = tests.fx('src'))
              + (select count(*) from public.coupon_redemptions where customer_id = tests.fx('src'))
              + (select count(*) from public.coupons where customer_id = tests.fx('src'))
              + (select count(*) from public.blocked_times where customer_id = tests.fx('src'))
              + (select count(*) from public.notifications where customer_id = tests.fx('src'))
              + (select count(*) from public.documents where customer_id = tests.fx('src')),
                0::bigint, 'nothing references the duplicate any more');
select tests.eq((select jsonb_build_array(archived_at is not null, merged_into_id = tests.fx('tgt'), portal_user_id,
                                          stripe_customer_id, referral_code)
                   from public.customers where id = tests.fx('src')),
                '[true, true, null, "cus_SRC", null]'::jsonb,
                'the duplicate is archived and points at the survivor; its portal link and referral code moved');

-- the merged duplicate stays archived (client context cannot restore it)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws_like($$update public.customers set archived_at = null where id = tests.fx('src')$$, '42501',
                         '%merged into another customer%',
                         'a manager cannot restore a merged duplicate as a live customer');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$update public.customers set archived_at = null where id = tests.fx('src')$$, '42501',
                    'nor can an admin');
select tests.throws($$update public.customers set archived_at = null, merged_into_id = null where id = tests.fx('src')$$, '42501',
                    'clearing merged_into_id at the same time is refused too');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$update public.customers set archived_at = null where id = tests.fx('src')$$, '42501',
                    'nor can the owner');
select tests.lives($$update public.customers set notes = coalesce(notes, '') || ' (dup)', archived_at = archived_at - interval '1 minute'
                     where id = tests.fx('src')$$,
                   'the duplicate''s other fields stay editable, and it may stay archived at another time');
select tests.authenticate_as(tests.fx('u_manager_b'));
update public.customers set archived_at = null where id = tests.fx('src');
select tests.as_superuser();
select tests.eq((select jsonb_build_array(archived_at is not null, merged_into_id = tests.fx('tgt'))
                   from public.customers where id = tests.fx('src')),
                '[true, true]'::jsonb, 'the duplicate is still archived and merged (another shop''s manager reaches nothing)');

-- links and queued work survive
select tests.eq((select public_token from public.jobs where id = tests.fx('job_s')), tests.fx('job_tok'), 'the booking link is kept');
select tests.eq((select public_token from public.form_submissions where id = tests.fx('form_s')), tests.fx('form_tok'),
                'the unsigned form link is kept');
select tests.eq((select customer_id from public.form_submissions where id = tests.fx('form_s')), tests.fx('tgt'),
                'and the form follows the job');
select tests.eq((select count(*) from public.storage_purge_requests where path like '%' || tests.fx('form_tok')::text || '%'),
                0::bigint, 'no purge is queued for the kept form link');
select tests.eq((select appointment_set_at from public.jobs where id = tests.fx('job_s')), (select set_at from before_merge),
                'the appointment stamp is kept');
select tests.eq((select array[status::text, error] from public.messages where id = tests.fx('msg_s')), array['queued', null],
                'the queued reminder is still queued');
select tests.eq((select customer_id from public.job_automation_log where id = tests.fx('log_s')), tests.fx('tgt'),
                'the reminder log moved (so the reminder is not sent twice)');
select tests.eq((select jsonb_build_array(public_token = tests.fx('q_sent_tok'), status, sent_at = (select q_sent_at from before_merge))
                   from public.quotes where id = tests.fx('q_sent')),
                '[true, "sent", true]'::jsonb, 'a sent quote keeps its link, status and sent time');
select tests.eq((select jsonb_build_array(public_token = tests.fx('q_viewed_tok'), status, viewed_at = (select q_viewed_at from before_merge))
                   from public.quotes where id = tests.fx('q_viewed')),
                '[true, "viewed", true]'::jsonb, 'a viewed quote too');
select tests.eq((select status from public.quotes where id = tests.fx('q_draft')), 'draft'::public.quote_status, 'drafts stay drafts');
select tests.eq((select array[customer_id = tests.fx('tgt'), vehicle_id = tests.fx('veh_s')] from public.jobs where id = tests.fx('job_s')),
                array[true, true], 'the job moved with its vehicle');
select tests.eq((select customer_id from public.vehicles where id = tests.fx('veh_s')), tests.fx('tgt'), 'the vehicle moved');
select tests.eq((select array_agg(p.customer_id = tests.fx('tgt') order by p.id) from public.payments p
                  where p.id in (tests.fx('pay_s'), tests.fx('dep_s'))), array[true, true], 'payment and deposit moved');
select tests.eq((select jsonb_build_array(customer_id = tests.fx('tgt'), status, amount_paid_cents)
                   from public.invoices where id = tests.fx('inv_s')),
                '[true, "paid", 4500]'::jsonb, 'the invoice moved, still paid');
select tests.eq((select customer_id from public.memberships where id = tests.fx('mem_s')), tests.fx('tgt'), 'the membership moved');
select tests.eq((select jsonb_agg(jsonb_build_array(stripe_payment_method_id, is_default, stripe_customer_id) order by stripe_payment_method_id)
                   from public.customer_payment_methods where customer_id = tests.fx('tgt')),
                '[["pm_src1", false, "cus_SRC"], ["pm_tgt1", true, "cus_TGT"]]'::jsonb,
                'the moved card keeps charging on its Stripe customer; the survivor''s default stays the default');
select tests.eq((select array_agg(campaign_id order by campaign_id) from public.campaign_recipients where customer_id = tests.fx('tgt')),
                (select array_agg(x order by x) from unnest(array[tests.fx('camp'), tests.fx('camp2')]) x),
                'one recipient row per campaign');
select tests.eq((select jsonb_agg(jsonb_build_array(job_id = tests.fx('job_a'), once_per_customer) order by once_per_customer desc)
                   from public.coupon_redemptions where customer_id = tests.fx('tgt')),
                '[[true, true], [false, false]]'::jsonb, 'the survivor''s once-per-customer marker wins');
select tests.eq((select customer_id from public.coupons where id = tests.fx('coupon_s')), tests.fx('tgt'), 'customer coupons moved');
select tests.eq((select customer_id from public.blocked_times where id = tests.fx('evt_s')), tests.fx('tgt'), 'calendar events moved');
select tests.eq((select count(*) from public.notifications where customer_id = tests.fx('tgt') and title = 'About Ally'), 1::bigint,
                'notification links moved');
select tests.eq((select array_agg(customer_id = tests.fx('tgt') order by file_name) from public.documents
                  where id in (tests.fx('doc_cust'), tests.fx('doc_job'))), array[true, true], 'documents moved');
select tests.eq((select storage_path from public.documents where id = tests.fx('doc_cust')),
                tests.fx('shop_a') || '/customers/' || tests.fx('src') || '/license.pdf', 'files stay where they are');

-- customer fields
select tests.eq((select jsonb_build_array(first_name, last_name, company, email, phone, address_line1, city, postal_code, lat, lng)
                   from public.customers where id = tests.fx('tgt')),
                '["Alice", "Anders", "Anders LLC", "alice@example.com", "+12055550101", "1 Main St", "Hoover", "35226", 33.4, -86.8]'::jsonb,
                'empty fields are filled from the duplicate; filled ones are kept');
select tests.eq((select tags from public.customers where id = tests.fx('tgt')), array['vip', 'fleet'], 'tags are united');
select tests.ok((select notes like 'Prefers mornings' || E'\n\n' || 'Merged from Ally on ____-__-__: Gate code 99'
                   from public.customers where id = tests.fx('tgt')), 'the duplicate''s notes are appended');
select tests.eq((select jsonb_build_array(lifecycle, sms_opt_in, email_opt_in, sms_opted_out_at is not null, email_opted_out_at,
                                          portal_user_id = tests.fx('u_client'), stripe_customer_id, referral_code)
                   from public.customers where id = tests.fx('tgt')),
                '["customer", false, true, true, null, null, "cus_TGT", "ALLY10"]'::jsonb,
                'opt-ins stay the survivor''s, opt-outs are carried over, referral code taken from the duplicate; the duplicate''s portal link is NOT (0107: the survivor keeps alice@, the link was for ally@)');

-- the duplicate's portal account does not get the survivor's records (0107;
-- 100_portal_link_realtime.sql covers a survivor that takes the duplicate's email)
select tests.authenticate_as(tests.fx('u_client'));
select tests.eq((select jsonb_array_length(o -> 'customers') + jsonb_array_length(o -> 'upcoming_jobs') + jsonb_array_length(o -> 'past_jobs')
                   from (select public.portal_overview() as o) x), 0, 'the duplicate''s portal account sees nothing of the survivor');

-- ============================================================ refused merges
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.merge_customers(tests.fx('src'), tests.fx('cust_a3'))$$, '22023', '%already merged%',
                         'a merged duplicate cannot be merged again');
select tests.throws_like($$select public.merge_customers(tests.fx('cust_a3'), tests.fx('src'))$$, '22023', '%merged into another%',
                         'nor be a merge target');
update public.customers set archived_at = now() where id = tests.fx('cust_a2');
select tests.throws_like($$select public.merge_customers(tests.fx('cust_a3'), tests.fx('cust_a2'))$$, '22023', '%archived%',
                         'an archived target must be restored first');
update public.customers set archived_at = null where id = tests.fx('cust_a2');
-- two different portal accounts
select tests.as_superuser();
update public.customers set portal_user_id = tests.create_user('fleet@example.com') where id = tests.fx('cust_a3');
update public.customers set portal_user_id = tests.create_user('aaron@example.com') where id = tests.fx('cust_a2');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select jsonb_build_array(p -> 'can_merge', p -> 'conflicts' -> 0 ->> 'code')
                   from (select public.merge_customers_preview(tests.fx('cust_a3'), tests.fx('cust_a2')) as p) x),
                '[false, "portal_accounts"]'::jsonb, 'the preview flags two portal accounts as blocking');
select tests.throws_like($$select public.merge_customers(tests.fx('cust_a3'), tests.fx('cust_a2'))$$, '22023', '%portal%',
                         'and the merge refuses it');
select tests.as_superuser();
update public.customers set portal_user_id = null where id = tests.fx('cust_a3');
-- two open memberships of the same plan without a vehicle
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.create_membership(tests.fx('plan'), tests.fx('cust_a3'), null);
select public.create_membership(tests.fx('plan'), tests.fx('cust_a2'), null);
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.merge_customers(tests.fx('cust_a3'), tests.fx('cust_a2'))$$, '22023', '%open Monthly Wash membership%',
                         'two open memberships of the same plan block the merge');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where merged_into_id is not null and shop_id = tests.fx('shop_a')), 1::bigint,
                'refused merges change nothing');
-- the owner can merge too; shop B is untouched
select tests.as_superuser();
update public.memberships set status = 'cancelled' where customer_id = tests.fx('cust_a3');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.merge_customers(tests.fx('cust_a3'), tests.fx('cust_a2'))$$, 'owners merge');
select tests.as_superuser();
select tests.eq((select count(*) from public.customers where shop_id = tests.fx('shop_b') and (archived_at is not null or merged_into_id is not null)),
                0::bigint, 'shop B is untouched');
select tests.throws($$insert into public.customers (shop_id, first_name, merged_into_id) values (tests.fx('shop_b'), 'X', tests.fx('tgt'))$$,
                    '23503', 'merged_into_id is a composite FK within the shop');
