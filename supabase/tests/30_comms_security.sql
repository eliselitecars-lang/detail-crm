-- 30 comms: grants and schema-level guarantees for the communication range —
-- RLS on, no anon access, no dangerous table privileges, owner of shop A
-- cannot plant rows in shop B, FK indexes, and the function privilege
-- matrix (service-only / staff / public).
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ tables
select tests.eq((select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
                   from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public' and not c.relrowsecurity
                    and c.relname in ('platform_config', 'notifications', 'message_templates', 'messages',
                                      'comms_suppressions', 'job_automation_log', 'campaigns', 'campaign_recipients')),
                '', 'RLS enabled on every comms table');
select tests.eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname = 'public'
                    and c.relname in ('platform_config', 'notifications', 'message_templates', 'messages',
                                      'comms_suppressions', 'job_automation_log', 'campaigns', 'campaign_recipients')),
                8::bigint, 'all 8 tables exist');
select tests.eq((
  select coalesce(string_agg(table_name || ':' || grantee || ':' || privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name in ('platform_config', 'notifications', 'message_templates', 'messages',
                       'comms_suppressions', 'job_automation_log', 'campaigns', 'campaign_recipients')
    and (grantee = 'anon'
         or (grantee = 'authenticated' and privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES'))
         or (grantee = 'authenticated' and table_name in ('platform_config'))
         or (grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
             and table_name in ('messages', 'comms_suppressions', 'job_automation_log', 'campaign_recipients',
                                'notifications')
             and not (privilege_type = 'DELETE' and table_name = 'notifications')))),
  '', 'no anon privileges; authenticated has no raw write access to queue/suppression/log/recipient tables');
select tests.ok(has_column_privilege('authenticated', 'public.messages', 'read_at', 'update'), 'messages.read_at is updatable');
select tests.ok(not has_column_privilege('authenticated', 'public.messages', 'status', 'update'), 'messages.status is not');
select tests.ok(has_column_privilege('authenticated', 'public.notifications', 'read_at', 'update'), 'notifications.read_at is updatable');
select tests.ok(not has_column_privilege('authenticated', 'public.notifications', 'user_id', 'update'), 'notifications.user_id is not');

-- every FK of a comms table is backed by an index on its leading columns
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_namespace n on n.oid = child.relnamespace and n.nspname = 'public'
  where con.contype = 'f'
    and child.relname in ('notifications', 'message_templates', 'messages', 'comms_suppressions', 'job_automation_log',
                          'campaigns', 'campaign_recipients')
    and not exists (
      select 1 from pg_index i
      where i.indrelid = con.conrelid
        and (select array_agg(x order by x) from unnest((i.indkey::int2[])[0:cardinality(con.conkey) - 1]) x)
            = (select array_agg(x order by x) from unnest(con.conkey) x))),
  '', 'every comms FK is backed by an index');

-- owner of A cannot plant rows in B
do $$
declare
  t       text;
  v_state text;
begin
  perform tests.authenticate_as(tests.fx('u_owner_a'));
  foreach t in array array['notifications', 'message_templates', 'messages', 'comms_suppressions', 'job_automation_log',
                           'campaigns', 'campaign_recipients'] loop
    v_state := null;
    begin
      execute format('insert into public.%I (shop_id) values ($1)', t) using tests.fx('shop_b');
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
    end;
    perform tests.eq(v_state, '42501', format('owner of A cannot insert into %s for shop B', t));
  end loop;
  perform tests.as_superuser();
end
$$;

-- service_role manages platform config and reads everything it needs
select tests.as_service();
select tests.lives($$insert into public.platform_config (key, value) values ('app_base_url', 'https://app.example.test')
                     on conflict (key) do update set value = excluded.value$$, 'service_role upserts platform config');
select tests.eq((select value from public.platform_config where key = 'app_base_url'), 'https://app.example.test',
                'service_role reads platform config');
select tests.throws($$insert into public.platform_config (key, value) values ('Bad Key', 'x')$$, '23514', 'config keys are snake_case');
select tests.as_superuser();

-- ------------------------------------------------------------ function privileges
create temp table fn_matrix (sig text, anon_ok boolean, auth_ok boolean, service_ok boolean) on commit drop;
insert into fn_matrix values
  ('public.platform_setting(text)',                                                   false, false, true),
  ('public.app_url(text)',                                                            false, false, true),
  ('public.format_money(bigint, text)',                                               false, true,  true),
  ('public.format_phone(text)',                                                       false, true,  true),
  ('public.notify_shop_staff(uuid, public.shop_role[], public.notification_kind, text, text, uuid, uuid)', false, false, true),
  ('public.mark_all_notifications_read(uuid)',                                         false, true,  true),
  ('public.default_message_templates()',                                               false, true,  true),
  ('public.reset_message_template(uuid)',                                              false, true,  true),
  ('public.render_template(text, jsonb)',                                              false, true,  true),
  ('public.comms_address_key(public.message_channel, text)',                          false, true,  true),
  ('public.comms_is_appointment_key(public.message_template_key)',                    false, true,  true),
  ('public.comms_render_parts(public.message_channel, text, text, jsonb, text)',       false, true,  true),
  ('public.comms_is_suppressed(uuid, public.message_channel, text)',                   false, false, true),
  ('public.comms_suppress(uuid, public.message_channel, text, timestamptz)',           false, false, true),
  ('public.comms_unsuppress(uuid, public.message_channel, text)',                      false, false, true),
  ('public.comms_withdraw_reason(public.messages, timestamptz)',                       false, false, true),
  ('public.comms_customer_vars(uuid, uuid)',                                           false, false, true),
  ('public.comms_job_vars(uuid)',                                                      false, false, true),
  ('public.template_vars_for_job(uuid)',                                               false, true,  true),
  ('public.enqueue_customer_template(uuid, uuid, public.message_template_key, public.message_channel, uuid, jsonb, timestamptz, uuid)',
                                                                                       false, false, true),
  ('public.enqueue_template_message(uuid, public.message_template_key, timestamptz, public.message_channel)', false, true, true),
  ('public.preview_template_message(uuid, public.message_template_key, public.message_channel)', false, true, true),
  ('public.queue_message(uuid, uuid, public.message_channel, text, text, uuid)',       false, true,  true),
  ('public.claim_queued_messages(integer, timestamptz)',                               false, false, true),
  ('public.mark_message_result(uuid, public.message_status, text, text, text, timestamptz)', false, false, true),
  ('public.update_message_status_by_provider_id(text, public.message_status, text)',  false, false, true),
  ('public.record_inbound_sms(text, text, text, text)',                                false, false, true),
  ('public.enqueue_due_automations(timestamptz)',                                      false, false, true),
  ('public.campaign_audience_valid(jsonb)',                                            false, true,  true),
  ('public.campaign_audience_customers(uuid, public.message_channel, jsonb)',          false, false, true),
  ('public.preview_campaign_audience(uuid, public.message_channel, jsonb)',            false, true,  true),
  ('public.launch_campaign(uuid, timestamptz)',                                        false, true,  true),
  ('public.cancel_campaign(uuid)',                                                     false, true,  true),
  ('public.public_unsubscribe(uuid)',                                                  true,  true,  true);

select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('anon', sig, 'execute') <> anon_ok), '', 'anon EXECUTE matrix');
select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('authenticated', sig, 'execute') <> auth_ok), '', 'authenticated EXECUTE matrix');
select tests.eq((select coalesce(string_agg(sig, ', ' order by sig), '') from fn_matrix
                  where has_function_privilege('service_role', sig, 'execute') <> service_ok), '', 'service_role EXECUTE matrix');

-- every comms function (and trigger function) is covered by the matrix above
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prorettype <> 'trigger'::regtype
    and p.proname in ('platform_setting', 'app_url', 'format_money', 'format_phone', 'notify_shop_staff',
                      'mark_all_notifications_read', 'default_message_templates', 'reset_message_template',
                      'render_template', 'comms_address_key', 'comms_is_appointment_key', 'comms_render_parts',
                      'comms_is_suppressed', 'comms_suppress', 'comms_unsuppress', 'comms_withdraw_reason',
                      'comms_customer_vars', 'comms_job_vars', 'template_vars_for_job',
                      'enqueue_customer_template', 'enqueue_template_message', 'preview_template_message',
                      'queue_message', 'claim_queued_messages', 'mark_message_result',
                      'update_message_status_by_provider_id', 'record_inbound_sms', 'enqueue_due_automations',
                      'campaign_audience_valid', 'campaign_audience_customers', 'preview_campaign_audience',
                      'launch_campaign', 'cancel_campaign', 'public_unsubscribe')
    and p.oid not in (select sig::regprocedure::oid from fn_matrix)),
  '', 'no unlisted overloads');
select tests.eq((
  select coalesce(string_agg(p.oid::regprocedure::text, ', ' order by 1), '')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prorettype = 'trigger'::regtype
    and p.proname in ('message_templates_before_write', 'message_templates_sync_offset', 'shops_seed_comms',
                      'customers_comms_guard', 'customers_attach_inbound_messages', 'customers_comms_suppressed',
                      'customers_comms_optout_sync', 'jobs_comms_sync_queued', 'campaigns_client_guard',
                      'campaigns_normalize')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  '', 'comms trigger functions are not executable by API roles');
