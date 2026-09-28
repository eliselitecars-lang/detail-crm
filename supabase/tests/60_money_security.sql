-- 60 money: privilege matrix of the money v2 range (0060-0069) — who may
-- execute each new RPC, internal helpers kept off the API, table privileges
-- of the new tables, index-backed foreign keys, one signature per replaced
-- function, column privileges (jobs.sold_by_member_id readable,
-- gift_cards.code_hash never), and the enum values the range adds.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ staff RPCs: authenticated (role-checked inside), never anon
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.create_invoice_from_jobs(uuid, uuid[], text, text)',
    'public.unbilled_jobs(uuid)',
    'public.job_payment_summary(uuid)',
    'public.report_team(uuid, date, date, timestamp with time zone)',
    'public.report_member_earnings(uuid, uuid, date, date)',
    'public.issue_gift_card(uuid, bigint, jsonb, bigint, text, uuid, boolean)',
    'public.lookup_gift_card(uuid, text)',
    'public.redeem_gift_card(uuid, text, bigint)',
    'public.redeem_customer_credit(uuid, uuid, bigint)',
    'public.adjust_gift_card(uuid, bigint, text)',
    'public.void_gift_card(uuid, text)',
    'public.report_gift_cards(uuid, date, date)',
    'public.add_fee_line(text, uuid, uuid, text)',
    'public.convert_quote_to_job(uuid, timestamp with time zone, timestamp with time zone)',
    'public.create_membership(uuid, uuid, uuid)',
    'public.membership_usage(uuid, timestamp with time zone)',
    'public.get_or_create_referral_code(uuid)',
    'public.portal_memberships()',
    'public.portal_referrals()',
    'public.record_manual_payment(uuid, bigint, public.payment_method, bigint, text)',
    'public.refund_manual_payment(uuid, bigint)',
    'public.void_invoice(uuid, text)',
    'public.create_invoice_from_job(uuid)']) as f
  where has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('authenticated', f, 'execute')
     or not (select p.prosecdef and 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = f::regprocedure)),
  '', 'staff / portal RPCs: SECURITY DEFINER, search_path pinned, authenticated only');

-- ------------------------------------------------------------ public entry points (anon + authenticated)
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.public_validate_coupon(text, text, uuid[], uuid, timestamp with time zone, uuid, public.location_type, uuid, text)',
    'public.public_respond_quote(uuid, text, text, uuid[], text, uuid)',
    'public.public_quote_slots(uuid, date, date, public.location_type)',
    'public.public_schedule_quote(uuid, text, jsonb, timestamp with time zone)',
    'public.public_redeem_gift_card(uuid, text, bigint)',
    'public.public_gift_card_offer(text)',
    'public.public_gift_card_order_status(uuid)',
    'public.public_membership_plans(text)']) as f
  where not has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute')
     or not (select p.prosecdef and 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = f::regprocedure)),
  '', 'public_* entry points: definer, pinned search_path, open to anon');

-- ------------------------------------------------------------ service_role only (edge functions, internal helpers)
select tests.eq((
  select coalesce(string_agg(f, ', ' order by f), '')
  from unnest(array[
    'public.upsert_stripe_payment(uuid, text, public.payment_status, bigint, bigint, public.payment_kind, public.payment_method, uuid, uuid, uuid, uuid, text, text, text, text, timestamp with time zone, text)',
    'public.gift_card_order_prepare(text, jsonb, timestamp with time zone)',
    'public.gift_card_order_paid(uuid, text, bigint)',
    'public.gift_card_order_refunded(text, bigint)',
    'public.membership_join_prepare(text, uuid, jsonb, timestamp with time zone)',
    'public.portal_membership_access(uuid, uuid)',
    'public.sync_stripe_subscription(uuid, text, public.membership_status, timestamp with time zone, boolean, uuid, timestamp with time zone, text, bigint, public.membership_interval, integer)',
    'public.coupon_customer_reason(public.coupons, uuid, uuid)',
    'public.coupon_restriction_reason(public.coupons, uuid, jsonb, timestamp with time zone)',
    'public.coupon_restrictions_text(public.coupons)',
    'public.report_team_job_rows(uuid, timestamp with time zone, timestamp with time zone)',
    'public.gift_card_code_hash(uuid, text)',
    'public.gen_gift_card_code()',
    'public.gift_card_issue_core(uuid, text, bigint, bigint, text, uuid, uuid, text, text, text, text, timestamp with time zone, text)',
    'public.gift_card_redeem_core(public.invoices, public.gift_cards, bigint, text)',
    'public.convert_quote_to_job_core(uuid, timestamp with time zone, timestamp with time zone, public.job_status, jsonb)',
    'public.quote_effective_option(uuid, uuid)',
    'public.create_membership_core(uuid, uuid, uuid)',
    'public.membership_period_bounds(uuid, timestamp with time zone)',
    'public.membership_uses_in_period(uuid, timestamp with time zone, uuid)',
    'public.referral_code_core(uuid)',
    'public.referral_new_code(uuid)']) as f
  where has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute')),
  '', 'webhook / edge helpers and internal cores: service_role only');

-- ------------------------------------------------------------ no leftover overloads of replaced functions
select tests.eq((select string_agg(proname || ':' || n, ',' order by proname)
                   from (select p.proname, count(*) as n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                          where s.nspname = 'public'
                            and p.proname in ('public_validate_coupon', 'public_respond_quote', 'upsert_stripe_payment',
                                              'job_payment_summary', 'report_team', 'compute_document_totals',
                                              'price_services_core', 'convert_quote_to_job', 'create_membership')
                          group by p.proname) x),
                'compute_document_totals:1,convert_quote_to_job:1,create_membership:1,job_payment_summary:1,price_services_core:1,'
                || 'public_respond_quote:1,public_validate_coupon:1,report_team:1,upsert_stripe_payment:1',
                'each replaced function has exactly one signature');

-- ------------------------------------------------------------ new tables
select tests.eq((
  select coalesce(string_agg(t.table_name || ':' || t.privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges t
  where t.table_schema = 'public' and t.grantee in ('anon', 'authenticated')
    and t.table_name in ('shop_terminal_locations', 'invoice_jobs', 'coupon_redemptions', 'gift_card_settings', 'gift_cards',
                         'gift_card_transactions', 'gift_card_orders', 'gift_card_attempts', 'quote_options', 'shop_fees',
                         'referral_settings', 'referral_credits')
    and (t.grantee = 'anon' or t.privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES'))),
  '', 'new tables: nothing for anon, no TRUNCATE / TRIGGER / REFERENCES for signed-in users');
select tests.eq((
  select coalesce(string_agg(t.table_name || ':' || t.privilege_type, ', ' order by 1), '')
  from information_schema.table_privileges t
  where t.table_schema = 'public' and t.grantee = 'authenticated'
    and t.privilege_type in ('INSERT', 'UPDATE', 'DELETE')
    and t.table_name in ('shop_terminal_locations', 'invoice_jobs', 'coupon_redemptions', 'gift_cards', 'gift_card_transactions',
                         'gift_card_orders', 'gift_card_attempts', 'referral_credits')),
  '', 'server-maintained tables: no client writes');
select tests.eq((
  select string_agg(t.table_name || ':' || t.privilege_type, ', ' order by 1)
  from information_schema.table_privileges t
  where t.table_schema = 'public' and t.grantee = 'authenticated'
    and t.privilege_type in ('INSERT', 'DELETE')
    and t.table_name in ('gift_card_settings', 'referral_settings')),
  null, 'settings rows are seeded per shop: updated, never inserted or deleted by clients');
select tests.eq((select count(*) from public.gift_card_settings where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'))), 2::bigint,
                'gift card settings seeded for every shop');
select tests.eq((select count(*) from public.referral_settings where shop_id in (tests.fx('shop_a'), tests.fx('shop_b')) and not enabled),
                2::bigint, 'referral settings seeded (off) for every shop');

-- every FK of the range's new tables / columns is backed by an index on its leading columns
select tests.eq((
  select coalesce(string_agg(con.conrelid::regclass::text || '.' || con.conname, ', ' order by 1), '')
  from pg_constraint con
  join pg_class child on child.oid = con.conrelid
  join pg_namespace n on n.oid = child.relnamespace and n.nspname = 'public'
  where con.contype = 'f'
    and (child.relname in ('invoice_jobs', 'coupon_redemptions', 'gift_cards', 'gift_card_transactions', 'gift_card_orders',
                           'quote_options', 'referral_credits')
         or con.conname in ('invoice_line_items_job_fk', 'invoice_line_items_fee_fk', 'invoice_line_items_membership_fk',
                            'job_line_items_fee_fk', 'job_line_items_membership_fk', 'quote_line_items_fee_fk',
                            'quote_line_items_membership_fk', 'quote_line_items_option_fk', 'quotes_selected_option_fk',
                            'jobs_sold_by_fk', 'coupons_customer_fk', 'coupons_referrer_fk'))
    and not exists (
      select 1 from pg_index i
      where i.indrelid = con.conrelid
        and (select array_agg(x order by x) from unnest((i.indkey::int2[])[0:cardinality(con.conkey) - 1]) x)
            = (select array_agg(x order by x) from unnest(con.conkey) x))),
  '', 'every new foreign key is index-backed');

-- ------------------------------------------------------------ column privileges
select tests.ok(has_column_privilege('authenticated', 'public.jobs', 'sold_by_member_id', 'select'), 'jobs.sold_by_member_id readable');
select tests.ok(not has_column_privilege('authenticated', 'public.gift_cards', 'code_hash', 'select')
                and has_column_privilege('authenticated', 'public.gift_cards', 'balance_cents', 'select'),
                'gift_cards: every column but code_hash');
select tests.ok(not has_column_privilege('authenticated', 'public.invoices', 'public_token', 'select'),
                'invoice tokens stay private (no invoices column added by the range)');

-- ------------------------------------------------------------ enum values of the range (0060)
select tests.eq((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e where e.enumtypid = 'public.payment_method'::regtype),
                array['card', 'card_present', 'cash', 'check', 'bank_transfer', 'other', 'gift_card', 'ach_debit', 'bnpl'], 'payment methods');
select tests.ok('processing' = any (enum_range(null::public.payment_status)::text[]), 'payment status processing');
select tests.ok('week' = any (enum_range(null::public.membership_interval)::text[]), 'weekly memberships');
select tests.ok(array['gift_card_purchased', 'membership_joined'] <@ enum_range(null::public.notification_kind)::text[], 'notification kinds');
select tests.ok(array['gift_card_delivery', 'referral_reward'] <@ enum_range(null::public.message_template_key)::text[], 'template keys');
select tests.eq(enum_range(null::public.commission_kind)::text[], array['none', 'percent', 'flat'], 'commission kinds');
select tests.eq(enum_range(null::public.fee_apply_location)::text[], array['none', 'shop', 'mobile', 'both'], 'fee locations');
select tests.eq(enum_range(null::public.gift_card_status)::text[], array['active', 'depleted', 'void', 'expired'], 'gift card statuses');
select tests.eq(enum_range(null::public.gift_card_txn_kind)::text[], array['issue', 'redeem', 'refund', 'adjust', 'void', 'expire'],
                'gift card ledger kinds');

-- ------------------------------------------------------------ transactional classification of the new keys (comms default)
select tests.ok(not public.comms_is_marketing_key('gift_card_delivery') and not public.comms_is_marketing_key('referral_reward'),
                'gift card delivery and referral rewards are transactional (no marketing opt-in needed)');
