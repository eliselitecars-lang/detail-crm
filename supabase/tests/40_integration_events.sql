-- 40 integration: cross-domain side effects (0041) fire exactly once — job
-- status messages (booking_confirmed, on_the_way, job_completed), quote
-- responses, payments (card and manual) with receipts, form signatures,
-- membership activation, online booking creation; inbound SMS stays single;
-- failures never block the business write; the integration_events ledger's
-- access rules; the realtime publication.
\ir fixtures/two_shops.psql
\ir fixtures/40_booking_setup.psql

create function pg_temp.msgs(p_job uuid, p_key text) returns text language sql as $$
  select coalesce(string_agg(channel::text, ',' order by channel, created_at), '')
  from public.messages where job_id = p_job and template_key::text = p_key
$$;
create function pg_temp.notes(p_kind text) returns bigint language sql as $$
  select count(*) from public.notifications where kind::text = p_kind
$$;

-- ------------------------------------------------------------ requested -> scheduled / confirmed: booking_confirmed
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, vehicle_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), tests.fx('veh_a'), 'requested', '2025-06-20 15:00Z', '2025-06-20 17:00Z')
  returning tests.fx_set('jr', id);
insert into public.job_line_items (shop_id, job_id, service_id, unit_price_cents) values (tests.fx('shop_a'), tests.fx('jr'), tests.fx('svc_a'), 20000);
update public.jobs set notes = 'edited' where id = tests.fx('jr');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jr'), 'booking_confirmed'), '', 'no message while requested (edits do not trigger)');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('jr');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jr'), 'booking_confirmed'), 'sms,email', 'requested -> scheduled queues booking_confirmed on both channels');
select tests.ok((select body like '%confirmed for Friday, June 20 at 10:00 AM%' from public.messages
                  where job_id = tests.fx('jr') and channel = 'sms'), 'rendered with the appointment time');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'confirmed' where id = tests.fx('jr');
update public.jobs set status = 'requested' where id = tests.fx('jr');
update public.jobs set status = 'confirmed' where id = tests.fx('jr');
update public.jobs set status = 'confirmed', notes = 'again' where id = tests.fx('jr');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jr'), 'booking_confirmed'), 'sms,email',
                'scheduled -> confirmed, backward and forward again, same-status updates: never re-sent');
select tests.eq((select count(*) from public.integration_events where job_id = tests.fx('jr')), 1::bigint, 'one ledger entry');

-- requested -> confirmed directly also confirms
select tests.authenticate_as(tests.fx('u_owner_a'));
insert into public.jobs (shop_id, customer_id, status, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), 'requested', '2025-06-21 15:00Z', '2025-06-21 16:00Z') returning tests.fx_set('jr2', id);
update public.jobs set status = 'confirmed' where id = tests.fx('jr2');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jr2'), 'booking_confirmed'), 'sms,email', 'requested -> confirmed');
-- jobs created already scheduled (staff, quote conversion) send nothing by themselves
select tests.eq(pg_temp.msgs(tests.fx('job_a'), 'booking_confirmed'), '', 'staff-created scheduled jobs: no automatic message');

-- ------------------------------------------------------------ en_route: on_the_way (SMS template only)
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'en_route' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('job_a'), 'on_the_way'), 'sms', 'a technician moving to en_route texts the customer');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('job_a');
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'en_route' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('job_a'), 'on_the_way'), 'sms', 'en_route again: not re-sent');

-- a manual "on my way" first: the status change does not duplicate it
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-22 15:00Z', '2025-06-22 16:00Z') returning tests.fx_set('jm', id);
select public.enqueue_template_message(tests.fx('jm'), 'on_the_way');
update public.jobs set status = 'en_route' where id = tests.fx('jm');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jm'), 'on_the_way'), 'sms', 'the manual message is not duplicated');

-- disabled template: nothing sent
update public.message_templates set enabled = false where shop_id = tests.fx('shop_a') and key = 'on_the_way';
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.jobs (shop_id, customer_id, scheduled_start, scheduled_end)
  values (tests.fx('shop_a'), tests.fx('cust_a'), '2025-06-23 15:00Z', '2025-06-23 16:00Z') returning tests.fx_set('jd', id);
update public.jobs set status = 'en_route' where id = tests.fx('jd');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jd'), 'on_the_way'), '', 'on_the_way only when its template is enabled');

-- ------------------------------------------------------------ completed: job_completed
select tests.authenticate_as(tests.fx('u_tech_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('job_a'), 'job_completed'), 'sms,email', 'completed: job_completed on both channels');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'in_progress' where id = tests.fx('job_a');
update public.jobs set status = 'completed' where id = tests.fx('job_a');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('job_a'), 'job_completed'), 'sms,email', 'completed again: not re-sent');
-- customers without contact details / opted out: no messages, no errors
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$update public.jobs set status = 'completed' where id = tests.fx('job_a2')$$, 'a customer without contact details');
select tests.as_superuser();
select tests.eq((select count(*) from public.messages where job_id = tests.fx('job_a2')), 0::bigint, 'nothing queued');
update public.customers set sms_opted_out_at = now(), email_opted_out_at = now() where id = tests.fx('cust_a');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'completed' where id = tests.fx('jm');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('jm'), 'job_completed'), '', 'opted-out customer: nothing queued');
update public.customers set sms_opted_out_at = null, email_opted_out_at = null where id = tests.fx('cust_a');

-- ------------------------------------------------------------ quotes: approved / declined
select tests.authenticate_as(tests.fx('u_manager_a'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))
  returning tests.fx_set('q1', id), tests.fx_set('q1_tok', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q1'), 'Coating', 90000);
select public.mark_quote_sent(tests.fx('q1'));
insert into public.quotes (shop_id, customer_id) values (tests.fx('shop_a'), tests.fx('cust_a'))
  returning tests.fx_set('q2', id), tests.fx_set('q2_tok', public_token);
insert into public.quote_line_items (shop_id, quote_id, name, unit_price_cents) values (tests.fx('shop_a'), tests.fx('q2'), 'Tint', 30000);
select public.mark_quote_sent(tests.fx('q2'));
select tests.as_superuser();
select tests.eq(pg_temp.notes('quote_approved') + pg_temp.notes('quote_declined'), 0::bigint, 'sending a quote notifies nobody');
select tests.as_anon();
select public.public_respond_quote(tests.fx('q1_tok'), 'approve', 'Alice A.');
select public.public_respond_quote(tests.fx('q2_tok'), 'decline', null, '{}', 'Too pricey');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications
                  where kind = 'quote_approved' and title = 'Quote #' || (select number from public.quotes where id = tests.fx('q1')) || ' approved by Alice A.'
                    and body = 'Alice Anders · $990.00'), 3::bigint, 'approval notifies owner, admin and manager');
select tests.eq((select count(*) from public.notifications
                  where kind = 'quote_declined' and body = 'Alice Anders · $330.00 · Too pricey'), 3::bigint,
                'decline notifies with the reason');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.quotes set internal_notes = 'follow up' where id = tests.fx('q1');
select tests.as_superuser();
select tests.eq(pg_temp.notes('quote_approved'), 3::bigint, 'later edits do not re-notify');
-- staff recording a response are not notified about their own action
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.quotes set status = 'draft' where id = tests.fx('q2');
select public.mark_quote_sent(tests.fx('q2'));
update public.quotes set status = 'approved', approved_by_name = 'Phone call' where id = tests.fx('q2');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications n join public.shop_members m on m.user_id = n.user_id and m.shop_id = n.shop_id
                  where n.kind = 'quote_approved' and n.title like '%by Phone call'), 2::bigint,
                'a revised quote approved again notifies again, but not the manager who recorded it');
select tests.eq((select count(*) from public.notifications where kind = 'quote_approved' and user_id = tests.fx('u_manager_a')
                   and title like '%Phone call'), 0::bigint, 'the recorder is excluded');

-- ------------------------------------------------------------ payments
-- manual payment on an invoice (recorded by the manager)
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.fx_set('inv', (public.create_invoice_from_job(tests.fx('jr'))).id);
select tests.fx_set('pay1', (public.record_manual_payment(tests.fx('inv'), 10000, 'cash', 500)).id);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'payment_received'
                   and title = 'Payment received: $105.00 from Alice Anders'
                   and body = 'Invoice #' || (select number from public.invoices where id = tests.fx('inv')) || ' · cash · includes $5.00 tip'),
                2::bigint, 'owner and admin notified; the manager who recorded it is not');
select tests.eq((select string_agg(channel::text, ',' order by channel) from public.messages where template_key = 'payment_receipt'),
                'sms,email', 'receipt on both channels');
select tests.ok((select body = E'Thank you, Alice! Shop A received your payment of $105.00.\nRemaining balance: $120.00.'
                   from public.messages where template_key = 'payment_receipt' and channel = 'sms'),
                'receipt: this payment incl. tip; the invoice balance after it (22000 - 10000)');
select tests.ok((select body like '%https://app.example.test/i/' || (select public_token from public.invoices where id = tests.fx('inv')) || '%'
                   from public.messages where template_key = 'payment_receipt' and channel = 'email'), 'receipt links the invoice');
-- refunding it: no new side effects
select tests.authenticate_as(tests.fx('u_owner_a'));
select public.refund_manual_payment(tests.fx('pay1'), 500);
select tests.as_superuser();
select tests.eq(pg_temp.notes('payment_received'), 2::bigint, 'refunds do not notify as payments');

-- card deposit via the webhook: pending -> succeeded -> replay -> refund
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_1', 'pending', 5000, 0, 'deposit', 'card', null, tests.fx('jr2'));
select tests.as_superuser();
select tests.eq(pg_temp.notes('payment_received'), 2::bigint, 'pending payments notify nobody');
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_1', 'succeeded', 5000, 0, 'deposit', 'card', null, tests.fx('jr2'),
                                    null, null, 'ch_1', null, 'visa', '4242');
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_1', 'succeeded', 5000, 0, 'deposit', 'card', null, tests.fx('jr2'),
                                    null, null, 'ch_1', null, 'visa', '4242');
select public.apply_stripe_refund('pi_1', 1000);
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'payment_received' and job_id = tests.fx('jr2')
                   and body = 'Deposit for job #' || (select number from public.jobs where id = tests.fx('jr2')) || ' · card'),
                3::bigint, 'webhook success notifies all managers+ once (replay and refund add nothing)');
select tests.eq(pg_temp.msgs(tests.fx('jr2'), 'payment_receipt'), 'sms,email', 'one receipt per channel');
select tests.ok((select body like E'%payment of $50.00.\nRemaining balance: $0.00.' from public.messages
                  where job_id = tests.fx('jr2') and template_key = 'payment_receipt' and channel = 'sms'),
                'deposit receipt: job with no lines owes nothing more');
-- a failed intent never notifies
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_2', 'failed', 5000, 0, 'deposit', 'card', null, tests.fx('jr2'));
select tests.as_superuser();
select tests.eq(pg_temp.notes('payment_received'), 5::bigint, 'failed payments notify nobody');

-- membership payments: staff notification, no receipt
insert into public.membership_plans (shop_id, name, price_cents) values (tests.fx('shop_a'), 'Gold', 9900) returning tests.fx_set('plan', id);
insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a2'))
  returning tests.fx_set('mem_aaron', id);
select tests.as_service();
select public.upsert_stripe_payment(tests.fx('shop_a'), 'pi_3', 'succeeded', 9900, 0, 'membership', 'card', null, null, null,
                                    tests.fx('mem_aaron'));
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'payment_received' and body = 'Membership: Gold · card'),
                3::bigint, 'membership payment notifies staff');
select tests.eq((select count(*) from public.messages where customer_id = tests.fx('cust_a2') and template_key = 'payment_receipt'),
                0::bigint, 'no receipt for subscription charges');

-- ------------------------------------------------------------ memberships: welcome once
insert into public.memberships (shop_id, plan_id, customer_id) values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'))
  returning tests.fx_set('mem', id);
select tests.eq((select count(*) from public.messages where template_key = 'membership_welcome'), 0::bigint, 'incomplete: no welcome');
select tests.as_service();
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-07-01Z', false, tests.fx('mem'));
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active', '2025-08-01Z');
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'past_due');
select public.sync_stripe_subscription(tests.fx('shop_a'), 'sub_1', 'active');
select tests.as_superuser();
select tests.eq((select string_agg(channel::text, ',' order by channel) from public.messages where template_key = 'membership_welcome'),
                'sms,email', 'one welcome per channel despite renewals and a past_due recovery');
select tests.ok((select body like 'Hi Alice, welcome to your Shop A membership!%' from public.messages
                  where template_key = 'membership_welcome' and channel = 'sms'), 'welcome rendered');
insert into public.memberships (shop_id, plan_id, customer_id, vehicle_id, status)
  values (tests.fx('shop_a'), tests.fx('plan'), tests.fx('cust_a'), tests.fx('veh_a'), 'active');
select tests.eq((select count(*) from public.messages where template_key = 'membership_welcome'), 4::bigint,
                'a second membership (inserted active) gets its own welcome');

-- ------------------------------------------------------------ forms signed
insert into public.form_templates (shop_id, name, body, requires_signature) values (tests.fx('shop_a'), 'Waiver', 'OK', false)
  returning tests.fx_set('ft', id);
insert into public.form_submissions (shop_id, form_template_id, job_id, customer_id, title, body_snapshot, requires_signature)
  values (tests.fx('shop_a'), tests.fx('ft'), tests.fx('jr2'), tests.fx('cust_a'), 'Waiver', 'OK', false)
  returning tests.fx_set('fs1', id), tests.fx_set('fs1_tok', public_token);
insert into public.form_submissions (shop_id, form_template_id, job_id, customer_id, title, body_snapshot, requires_signature)
  values (tests.fx('shop_a'), tests.fx('ft'), tests.fx('jr'), tests.fx('cust_a'), 'Waiver', 'OK', false)
  returning tests.fx_set('fs2', id);
select tests.as_anon();
select public.public_sign_form(tests.fx('fs1_tok'), 'Alice Anders');
select tests.throws($$select public.public_sign_form(tests.fx('fs1_tok'), 'Alice Anders')$$, '22023', 'signed once only');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'form_signed' and title = 'Form signed: Waiver'
                   and body = 'Signed by Alice Anders · Job #' || (select number from public.jobs where id = tests.fx('jr2'))),
                3::bigint, 'a customer signature notifies owner, admin and manager');
select tests.authenticate_as(tests.fx('u_manager_a'));
select public.sign_form_submission(tests.fx('fs2'), 'Alice Anders');
select tests.as_superuser();
select tests.eq((select count(*) from public.notifications where kind = 'form_signed' and job_id = tests.fx('jr')), 2::bigint,
                'signing on a staff device notifies the others, not the signer');

-- ------------------------------------------------------------ inbound SMS: one notification per manager+ (0033), no duplicate
select tests.as_service();
select public.record_inbound_sms('+12055550100', '+12055550101', 'Running late', 'SM1');
select public.record_inbound_sms('+12055550100', '+12055550101', 'Running late', 'SM1');
select tests.as_superuser();
select tests.eq(pg_temp.notes('inbound_message'), 3::bigint, 'inbound SMS: exactly one notification per owner/admin/manager');

-- ------------------------------------------------------------ online booking created: once
select tests.as_service();
select tests.fx_set('ob', (public.create_online_booking('shop-a', pg_temp.booking(), '2025-06-01 12:00Z') ->> 'job_token')::uuid);
select tests.as_superuser();
select tests.fx_set('ob_job', (select id from public.jobs where public_token = tests.fx('ob')));
select public.integration_online_booking_created(tests.fx('ob_job'));
select tests.eq((select count(*) from public.notifications where kind = 'new_booking'), 3::bigint, 'new_booking once per recipient');
select tests.eq(pg_temp.msgs(tests.fx('ob_job'), 'booking_request_received'), 'sms,email', 'request received once per channel');
select tests.authenticate_as(tests.fx('u_manager_a'));
update public.jobs set status = 'scheduled' where id = tests.fx('ob_job');
select tests.as_superuser();
select tests.eq(pg_temp.msgs(tests.fx('ob_job'), 'booking_confirmed'), 'sms,email', 'confirming the request sends booking_confirmed');

-- ------------------------------------------------------------ failures never block the business write
create function pg_temp.explode() returns trigger language plpgsql as $$
begin
  raise exception 'notification service down';
end
$$;
create temp table before_fail as
  select (select count(*) from public.messages) as msgs, (select count(*) from public.notifications) as notes,
         (select amount_paid_cents from public.invoices where id = tests.fx('inv')) as paid;
create trigger zz_explode before insert on public.notifications for each row execute function pg_temp.explode();
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.lives($$select public.record_manual_payment(tests.fx('inv'), 1000, 'check')$$,
                   'the payment is recorded even though its side effects fail');
select tests.as_superuser();
select tests.eq((select amount_paid_cents from public.invoices where id = tests.fx('inv')), (select paid + 1000 from before_fail),
                'the money landed on the invoice');
select tests.eq((select count(*) from public.integration_events e join public.payments p on p.id = e.payment_id
                  where p.invoice_id = tests.fx('inv') and p.method = 'check'), 0::bigint,
                'the failed side effect left no ledger entry (a later retry is possible)');
select tests.eq((select count(*) from public.messages), (select msgs from before_fail),
                'and no half-done receipt (the side effects roll back together)');
select tests.eq((select count(*) from public.notifications), (select notes from before_fail), 'no notifications');
drop trigger zz_explode on public.notifications;

-- ------------------------------------------------------------ integration_events ledger access
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.ok(tests.row_count($$select 1 from public.integration_events$$) > 0, 'managers read their shop''s ledger');
select tests.throws($$insert into public.integration_events (shop_id, event, job_id) values (tests.fx('shop_a'), 'job_completed', tests.fx('jd'))$$,
                    '42501', 'no direct inserts');
select tests.throws($$delete from public.integration_events$$, '42501', 'no deletes');
select tests.throws($$update public.integration_events set event = event$$, '42501', 'no updates');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$select 1 from public.integration_events$$), 0::bigint, 'technicians see nothing');
select tests.authenticate_as(tests.fx('u_manager_b'));
select tests.eq(tests.row_count($$select 1 from public.integration_events$$), 0::bigint, 'another shop sees nothing');
select tests.as_superuser();
select tests.throws($$insert into public.integration_events (shop_id, event, job_id) values (tests.fx('shop_b'), 'job_completed', tests.fx('jd'))$$,
                    '23503', 'composite FK: a ledger row cannot point at another shop''s job');
select tests.throws($$insert into public.integration_events (shop_id, event, payment_id) values (tests.fx('shop_a'), 'job_completed', tests.fx('pay1'))$$,
                    '23514', 'event and subject kind must match');
select tests.throws($$insert into public.integration_events (shop_id, event, job_id, payment_id)
                      values (tests.fx('shop_a'), 'payment_succeeded', tests.fx('jd'), tests.fx('pay1'))$$,
                    '23514', 'exactly one subject');
select tests.eq((select count(*) from public.notifications where shop_id = tests.fx('shop_b')), 0::bigint,
                'nothing in shop B was notified by shop A events');
select tests.eq((select count(*) from public.messages where shop_id = tests.fx('shop_b')), 0::bigint, 'no shop B messages');

-- ------------------------------------------------------------ realtime publication
select tests.eq((select string_agg(tablename, ',' order by tablename) from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename in ('jobs', 'messages', 'notifications', 'payments', 'time_entries')),
                'jobs,messages,notifications,payments,time_entries', 'realtime publishes the five live tables');
