-- 120 (0124): staff invites and invite emails are limited in the database.
-- Round 9 counted new invites only inside the invites function's
-- send_invite: invite_member through PostgREST had no limit, resend_invite
-- of a fresh invite counted nothing, the cap was per shop (and create_shop
-- has none per person), and a lapsed shop could still invite.
\ir fixtures/two_shops.psql

-- SQLSTATE, HINT and DETAIL of a statement's error ('ok' when it succeeds).
create function pg_temp.refusal(p_sql text) returns text language plpgsql as $$
declare
  v_state  text;
  v_hint   text;
  v_detail text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_state = returned_sqlstate, v_hint = pg_exception_hint, v_detail = pg_exception_detail;
  return v_state || '|' || coalesce(v_hint, '') || '|' || coalesce(v_detail, '');
end
$$;
grant execute on function pg_temp.refusal(text) to authenticated, service_role;

create function pg_temp.invite_many(p_shop uuid, p_prefix text, p_count integer) returns void language plpgsql as $$
begin
  for i in 1..p_count loop
    perform public.invite_member(p_shop, p_prefix || i || '@example.com', 'technician');
  end loop;
end
$$;
grant execute on function pg_temp.invite_many(uuid, text, integer) to authenticated;

-- ============================================================ new invites per shop (invite_member via PostgREST)
select tests.authenticate_as(tests.fx('u_admin_a'));
select pg_temp.invite_many(tests.fx('shop_a'), 'a', 19);
-- a revoked invite still counts: revoking and re-inviting does not reset the limit
select public.revoke_invite((select id from public.shop_invites where email = 'a1@example.com'));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'a20@example.com', 'technician')$$,
                   'the 20th invite of the day is created');
select tests.eq(pg_temp.refusal($$select public.invite_member(tests.fx('shop_a'), 'a21@example.com', 'technician')$$),
                'PT429|invite_limit|86400', 'the 21st is PT429 invite_limit; DETAIL = seconds until one leaves the window');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'a22@example.com', 'manager')$$, 'PT429',
                    'another admin of the same shop is refused too (per shop)');
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'a1@example.com', 'technician')$$, 'PT429',
                    're-inviting a revoked address is a new invite');

-- the service role (operator) is not limited
select tests.as_service();
select tests.lives($$insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'ops@example.com', 'technician')$$,
                   'the service role is not limited');

-- invites older than 24 hours leave the window
select tests.as_superuser();
update public.shop_invites set created_at = now() - interval '25 hours' where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'a21@example.com', 'technician')$$,
                   'after 24 hours the shop invites again');

-- ============================================================ new invites per person (all their shops)
select tests.as_superuser();
select tests.fx_set('shop_b2', tests.make_shop('owner-b@test.local', 'shop-b2', 'Shop B2'));
select tests.authenticate_as(tests.fx('u_owner_b'));
select pg_temp.invite_many(tests.fx('shop_b'), 'b', 12);
select pg_temp.invite_many(tests.fx('shop_b2'), 'c', 8);
select tests.eq(pg_temp.refusal($$select public.invite_member(tests.fx('shop_b2'), 'c9@example.com', 'technician')$$),
                'PT429|invite_limit|86400', 'a person creates at most 20 invites a day across all their shops');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.lives($$select public.invite_member(tests.fx('shop_b'), 'b13@example.com', 'technician')$$,
                   'another admin of that shop still invites (the shop has 13 of 20)');

-- ============================================================ a lapsed shop creates no invites
select tests.as_service();
select public.set_billing_config(true, 14);
select tests.as_superuser();
update public.shop_billing set trial_ends_at = now() - interval '1 day', status = 'none', plan_id = null, comp_until = null
 where shop_id = tests.fx('shop_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(split_part(pg_temp.refusal($$select public.invite_member(tests.fx('shop_a'), 'late@example.com', 'technician')$$), '|', 1),
                'PT402', 'a lapsed shop cannot invite (PT402), even with no plan seat limit');

-- ============================================================ invite_email_permit
select tests.as_service();
select tests.eq(public.invite_email_permit(tests.fx('shop_a'), tests.fx('u_owner_a'), 'k-lapsed'),
                jsonb_build_object('allowed', false, 'reason', 'subscription_inactive',
                                   'message', public.billing_inactive_message()),
                'a lapsed shop sends no invite email');
-- counts are scoped to this file's shops: on the real stack the table already
-- holds rows from invites sent outside the test (verify_stack.mjs)
select tests.eq((select count(*) from public.shop_invite_emails
                  where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'), tests.fx('shop_b2')))::integer, 0,
                'nothing recorded for a refusal');

-- shop B: on its trial -> the default wording only
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'k-b-1'),
                '{"allowed": true, "custom_wording": false}'::jsonb, 'a trial shop: allowed, default wording');
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'k-b-1'),
                '{"allowed": true, "custom_wording": false}'::jsonb, 'the same key again is allowed');
select tests.eq((select count(*) from public.shop_invite_emails where shop_id = tests.fx('shop_b'))::integer, 1,
                'and counted once (Resend sends one email per key)');
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), null),
                '{"allowed": true, "custom_wording": false}'::jsonb, 'a null key only checks');
select tests.eq((select count(*) from public.shop_invite_emails
                  where shop_id in (tests.fx('shop_a'), tests.fx('shop_b'), tests.fx('shop_b2')))::integer, 1,
                'a check records nothing');

-- a paying shop: its own wording
select tests.as_superuser();
update public.shop_billing set status = 'active', trial_ends_at = null where shop_id = tests.fx('shop_b');
select tests.as_service();
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_admin_b'), 'k-b-2') ->> 'custom_wording',
                'true', 'a subscribed shop uses its own invite wording');

-- 30 invite emails per shop a day, whoever asks
do $$
begin
  for i in 3..30 loop
    perform public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_manager_b'), 'k-b-' || i);
  end loop;
end
$$;
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_admin_b'), 'k-b-31'),
                '{"allowed": false, "reason": "invite_limit", "scope": "shop", "limit": 30, "retry_after_seconds": 86400}'::jsonb,
                'the 31st invite email of the day is refused');
select tests.eq((public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_admin_b'), null)) ->> 'allowed', 'false',
                'a check past the limit is refused too');
select tests.eq((public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'k-b-5')) ->> 'allowed', 'true',
                'an email already recorded is still allowed (retry of the same send)');

-- 30 per person across shops: the 30 emails were all owner B's, in shop B2
select tests.as_superuser();
update public.shop_invite_emails set shop_id = tests.fx('shop_b2'), sent_by = tests.fx('u_owner_b')
 where shop_id = tests.fx('shop_b');
select tests.as_service();
select tests.eq((select count(*) from public.shop_invite_emails where shop_id = tests.fx('shop_b'))::integer, 0,
                'shop B has sent nothing today now');
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'k-b-40') - 'retry_after_seconds',
                '{"allowed": false, "reason": "invite_limit", "scope": "user", "limit": 30}'::jsonb,
                'one person sends at most 30 invite emails a day across all their shops');
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_admin_b'), 'k-b-41') ->> 'allowed', 'true',
                'another admin of the shop still can');

-- rows older than a day do not count, older than two days are pruned
select tests.as_superuser();
update public.shop_invite_emails set created_at = now() - interval '3 days' where sent_by = tests.fx('u_owner_b');
select tests.as_service();
select tests.eq(public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'k-b-42') ->> 'allowed', 'true',
                'after 24 hours the person sends again');
select tests.eq((select count(*) from public.shop_invite_emails where sent_by = tests.fx('u_owner_b'))::integer, 1,
                'their rows older than 2 days were pruned');
select tests.throws($$select public.invite_email_permit(gen_random_uuid(), null, null)$$, 'P0002', 'unknown shop');

-- ============================================================ privacy
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws($$select public.invite_email_permit(tests.fx('shop_b'), tests.fx('u_owner_b'), 'x')$$, '42501',
                    'owners cannot call invite_email_permit');
select tests.throws($$select count(*) from public.shop_invite_emails$$, '42501', 'nor read the email log');
select tests.as_anon();
select tests.throws($$select public.invite_email_permit(tests.fx('shop_b'), null, null)$$, '42501', 'nor anonymous callers');
