-- 80 comms: privileges of every function the comms v2 range (0080-0089)
-- adds — who may EXECUTE what (anon only the public_* entry points; staff
-- entry points check roles inside; internal builders and worker queues are
-- service-only), no unlisted overloads, trigger functions not callable by
-- API roles, and definer hygiene for the new tables' helpers.
\ir fixtures/two_shops.psql

create temp table fn_matrix (sig text, anon_ok boolean, auth_ok boolean, service_ok boolean) on commit drop;
insert into fn_matrix values
  -- 0081 CHECK helpers (pure)
  ('public.comms_reminder_offsets_valid(integer[], integer)',                                 false, true,  true),
  ('public.comms_custom_field_options_valid(public.custom_field_type, text[])',               false, true,  true),
  -- 0082 push
  ('public.user_can_read_notification(uuid, uuid, public.notification_kind)',                 false, false, true),
  ('public.notify_member(uuid, uuid, public.notification_kind, text, text, uuid, uuid)',      false, false, true),
  ('public.comms_local_when(timestamptz, text)',                                              false, false, true),
  ('public.comms_job_services(uuid)',                                                         false, false, true),
  ('public.register_push_token(text, text, text, text)',                                      false, true,  true),
  ('public.unregister_push_token(text)',                                                      false, true,  true),
  ('public.set_notification_prefs(uuid, public.notification_kind[], timestamptz)',            false, true,  true),
  ('public.claim_push_batch(integer, timestamptz)',                                           false, false, true),
  ('public.release_push(uuid)',                                                               false, false, true),
  ('public.mark_push_token_invalid(text, text)',                                              false, false, true),
  -- 0083 templates v2
  ('public.comms_omit_lines_without(text, jsonb, text[])',                                    false, true,  true),
  ('public.comms_v2_optional_vars()',                                                         false, true,  true),
  ('public.enqueue_message_core(uuid, uuid, public.message_template_key, public.message_channel, text, text, uuid, jsonb, timestamptz, uuid, text, uuid, uuid)',
                                                                                              false, false, true),
  -- 0084 tasks
  ('public.enqueue_task_reminders(timestamptz)',                                              false, false, true),
  -- 0085 document follow-ups
  ('public.comms_quote_vars(uuid)',                                                           false, false, true),
  ('public.comms_invoice_due_cents(uuid, timestamptz)',                                       false, false, true),
  ('public.comms_invoice_vars(uuid, timestamptz)',                                            false, false, true),
  ('public.comms_deposit_due_cents(uuid)',                                                    false, false, true),
  ('public.comms_followup_candidates(timestamptz, text, uuid)',                               false, false, true),
  ('public.comms_followup_due_at(timestamptz, interval, interval, boolean, text, integer)',  false, false, true),
  ('public.comms_followup_status_json(text, uuid, timestamptz)',                              false, false, true),
  ('public.comms_followup_check(text, uuid)',                                                 false, false, true),
  ('public.enqueue_document_followups(timestamptz)',                                          false, false, true),
  ('public.document_followup_status(text, uuid)',                                             false, true,  true),
  ('public.set_document_followups_paused(text, uuid, boolean)',                               false, true,  true),
  -- 0086 reminders v2
  ('public.comms_reminder_log_covers(integer, timestamptz, integer, timestamptz, boolean)',   false, true,  true),
  ('public.comms_marketing_send_after(timestamptz, text)',                                     false, false, true),
  ('public.enqueue_service_followups(timestamptz)',                                           false, false, true),
  -- 0087 import / export
  ('public.comms_import_yes(jsonb, text)',                                                    false, true,  true),
  ('public.comms_import_flag(jsonb, text, text, boolean)',                                    false, true,  true),
  ('public.comms_import_tags(jsonb)',                                                         false, true,  true),
  ('public.comms_import_begin(uuid, text, jsonb, boolean, uuid, text)',                       false, false, true),
  ('public.comms_import_record(uuid, text, uuid, text, integer, integer, integer, integer, jsonb)', false, false, true),
  ('public.comms_grouped_invoice_job_amounts(uuid)',                                          false, false, true),
  ('public.import_customers(uuid, jsonb, boolean, uuid, text, text)',                         false, true,  true),
  ('public.import_services(uuid, jsonb, boolean, uuid, text, text)',                          false, true,  true),
  ('public.export_jobs(uuid, date, date)',                                                    false, true,  true),
  -- 0088 custom fields, leads, tracking
  ('public.comms_custom_value_error(public.custom_field_type, text[], jsonb)',                false, true,  true),
  ('public.comms_validate_custom_data(uuid, public.custom_field_entity, jsonb, jsonb)',       false, false, true),
  ('public.comms_live_lead_form(uuid)',                                                       false, false, true),
  ('public.comms_lead_form_fields(public.lead_forms)',                                        false, false, true),
  ('public.public_booking_questions(text)',                                                   true,  true,  true),
  ('public.public_get_lead_form(uuid)',                                                       true,  true,  true),
  ('public.public_submit_lead(uuid, jsonb, timestamptz)',                                     true,  true,  true),
  ('public.public_shop_profile(text)',                                                        true,  true,  true),
  -- 0089 SMS numbers and webhooks
  ('public.record_sms_number(uuid, text, text, text, text)',                                  false, false, true),
  ('public.set_sms_verification(uuid, text, text, text, jsonb)',                              false, false, true),
  ('public.release_sms_number(uuid)',                                                         false, false, true),
  ('public.sms_provisioning_status(uuid)',                                                    false, true,  true),
  ('public.claim_queued_messages(integer, timestamptz)',                                      false, false, true),
  ('public.comms_webhook_url(text)',                                                          false, true,  true),
  ('public.comms_webhook_events(text[])',                                                     false, true,  true),
  ('public.comms_webhook_secret()',                                                           false, false, true),
  ('public.comms_webhook_json(public.webhook_endpoints)',                                     false, false, true),
  ('public.comms_webhook_endpoint_for_admin(uuid)',                                           false, false, true),
  ('public.webhook_payload(uuid)',                                                            false, false, true),
  ('public.create_webhook_endpoint(uuid, text, text[], text)',                                false, true,  true),
  ('public.update_webhook_endpoint(uuid, text, text[], boolean, text)',                       false, true,  true),
  ('public.rotate_webhook_secret(uuid)',                                                      false, true,  true),
  ('public.delete_webhook_endpoint(uuid)',                                                    false, true,  true),
  ('public.send_test_webhook(uuid)',                                                          false, true,  true),
  ('public.claim_webhook_deliveries(integer, timestamptz)',                                   false, false, true),
  ('public.mark_webhook_delivery(uuid, integer, text, timestamptz)',                          false, false, true),
  -- re-defined existing functions keep their privileges
  ('public.notification_kind_for_managers(public.notification_kind)',                         false, true,  true),
  ('public.comms_uses_app_links(text)',                                                       false, true,  true),
  ('public.comms_is_marketing_key(public.message_template_key)',                              false, true,  true),
  ('public.comms_job_vars(uuid)',                                                             false, false, true),
  ('public.comms_withdraw_reason(public.messages, timestamptz)',                              false, false, true),
  ('public.default_message_templates()',                                                      false, true,  true),
  ('public.reset_message_template(uuid)',                                                     false, true,  true),
  ('public.enqueue_customer_template(uuid, uuid, public.message_template_key, public.message_channel, uuid, jsonb, timestamptz, uuid, text)',
                                                                                              false, false, true),
  ('public.enqueue_due_automations(timestamptz)',                                             false, false, true);

select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('anon', sig, 'execute') <> anon_ok), '', 'anon EXECUTE matrix');
select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('authenticated', sig, 'execute') <> auth_ok), '', 'authenticated EXECUTE matrix');
select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('service_role', sig, 'execute') <> service_ok), '', 'service_role EXECUTE matrix');

-- every non-trigger function of these names is in the matrix (no stray overloads)
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prorettype <> 'trigger'::regtype
    and p.proname in (select split_part(substr(sig, 8), '(', 1) from fn_matrix)
    and p.oid not in (select sig::regprocedure::oid from fn_matrix)),
  '', 'no unlisted overloads');

-- trigger functions of the range
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prorettype = 'trigger'::regtype
    and p.proname in ('job_assignments_comms_notify', 'jobs_comms_notify_rescheduled', 'tasks_guard', 'tasks_comms_notify',
                      'service_followups_limit', 'customers_comms_custom_data', 'jobs_comms_custom_data', 'custom_fields_guard',
                      'custom_fields_normalize', 'lead_forms_validate', 'customers_comms_merge_follow',
                      'integration_events_comms_webhooks', 'message_templates_before_write', 'message_templates_sync_offset',
                      'jobs_comms_reminder_log_follow', 'shops_seed_comms')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'trigger functions are not executable by API roles');
select tests.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.prorettype = 'trigger'::regtype
                    and p.proname in ('job_assignments_comms_notify', 'jobs_comms_notify_rescheduled', 'tasks_guard', 'tasks_comms_notify',
                                      'service_followups_limit', 'customers_comms_custom_data', 'jobs_comms_custom_data',
                                      'custom_fields_guard', 'custom_fields_normalize', 'lead_forms_validate',
                                      'customers_comms_merge_follow', 'integration_events_comms_webhooks')),
                12::bigint, 'the range''s trigger functions exist');

-- guards that must see the caller run as SECURITY INVOKER
select tests.ok(not (select prosecdef from pg_proc where oid = 'public.tasks_guard()'::regprocedure),
                'tasks_guard runs as the caller (is_client_context)');

-- the new tables: RLS on, anon nothing, tenant keys
select tests.eq((select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public'
                    and c.relname in ('device_push_tokens', 'member_notification_prefs', 'followup_settings', 'document_followup_log',
                                      'service_followups', 'import_batches', 'custom_fields', 'lead_forms', 'lead_submissions',
                                      'webhook_endpoints', 'webhook_deliveries', 'tasks')
                    and (not c.relrowsecurity or has_table_privilege('anon', c.oid, 'select'))), '',
                'RLS on and no anon access for every new table');
select tests.eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public'
                    and c.relname in ('device_push_tokens', 'member_notification_prefs', 'followup_settings', 'document_followup_log',
                                      'service_followups', 'import_batches', 'custom_fields', 'lead_forms', 'lead_submissions',
                                      'webhook_endpoints', 'webhook_deliveries', 'tasks')), 12::bigint, 'all twelve exist');

-- the new message_template_key / notification_kind values
select tests.ok(array['quote_reminder', 'deposit_reminder', 'invoice_reminder', 'invoice_overdue', 'service_followup', 'lead_received']
                  <@ enum_range(null::public.message_template_key)::text[], 'template keys');
select tests.ok(array['job_assigned', 'job_rescheduled', 'new_lead', 'task_assigned', 'task_due', 'sms_number_status', 'webhook_failing']
                  <@ enum_range(null::public.notification_kind)::text[], 'notification kinds');
select tests.ok('import' = any (enum_range(null::public.customer_source)::text[]), 'customer source import');
select tests.eq((select array_agg(k::text order by k) from unnest(enum_range(null::public.message_template_key)) k
                  where public.comms_is_marketing_key(k)), array['follow_up', 'service_followup'], 'the marketing keys');
select tests.ok(public.comms_uses_app_links('{{deposit_link}}') and public.comms_uses_app_links('{{ rebook_link }}')
                and public.comms_uses_app_links('{{report_link}}') and not public.comms_uses_app_links('{{review_link}}'),
                'the new link placeholders count as app links');
select tests.eq(public.comms_omit_lines_without(E'Hi\n\n{{gift_message}}\n\nCode: {{gift_card_code}}', '{"gift_card_code": "X"}',
                                                array['gift_message', 'gift_card_code']),
                E'Hi\n\nCode: {{gift_card_code}}', 'a line with a missing optional value is left out with its blank line');
