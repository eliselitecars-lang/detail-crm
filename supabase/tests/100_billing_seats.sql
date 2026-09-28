-- 100 billing: seat limits — pending unexpired invites count, re-inviting an
-- address takes no new seat, deactivation frees one and re-activation needs
-- one, accepting an invite never fails for seats (even after a downgrade),
-- expired / revoked invites free their seat, the singular wording, no limit
-- without a plan, while comped or with billing off, and the service role /
-- operator are not limited.
\ir fixtures/two_shops.psql

select tests.as_service();
select public.set_billing_config(true, 0);
select tests.fx_set('plan_6', public.billing_upsert_plan('price_Seat6', 'prod_Seat', 'Crew', null, 9900, 'usd', 'month', 1, 6,
                                                         '{}', 0, true));
select tests.fx_set('plan_1', public.billing_upsert_plan('price_Seat1', 'prod_Solo', 'Solo', null, 2900, 'usd', 'month', 1, 1,
                                                         '{}', 0, true));
update public.shop_billing set status = 'active', plan_id = tests.fx('plan_6'), current_period_end = now() + interval '20 days'
 where shop_id = tests.fx('shop_a');
-- shop B: in its trial, no plan yet
update public.shop_billing set trial_ends_at = now() + interval '5 days' where shop_id = tests.fx('shop_b');

create function pg_temp.seats(p_shop uuid) returns integer language sql as $$
  select (public.shop_entitlement(p_shop) ->> 'members_used')::integer $$;
create function pg_temp.token(p_email text) returns uuid language sql as $$
  select token from public.shop_invites where shop_id = tests.fx('shop_a') and email = p_email
     and accepted_at is null and revoked_at is null $$;
grant execute on function pg_temp.seats(uuid), pg_temp.token(text) to authenticated, service_role;
select tests.as_superuser();
select tests.fx_set('u_seat1', tests.create_user('seat1@test.local'));
select tests.fx_set('u_seat2', tests.create_user('seat2@test.local'));

-- ============================================================ invites count
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.seats(tests.fx('shop_a')), 5, 'five active members');
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat1@test.local', 'technician')$$, 'the sixth seat: invite');
select tests.eq(pg_temp.seats(tests.fx('shop_a')), 6, 'the pending invite takes it');
select tests.throws_like($$select public.invite_member(tests.fx('shop_a'), 'seat2@test.local', 'technician')$$, 'PT402',
                         'This shop''s plan allows 6 team members.', 'full: the next invite is refused (neutral wording)');
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'SEAT1@test.local', 'manager')$$,
                   're-inviting the same address takes no new seat');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.invite_member(tests.fx('shop_a'), 'seat2@test.local', 'technician')$$, 'PT402',
                         '%allows 6 team members%', 'admins are limited too');

-- deactivating frees a seat; re-activating needs one
select tests.eq(tests.row_count($$update public.shop_members set active = false where id = tests.fx('m_tech2_a')$$), 1::bigint,
                'an admin deactivates a technician');
select tests.eq(pg_temp.seats(tests.fx('shop_a')), 5, 'a seat is free again');
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat2@test.local', 'technician')$$, 'so an invite fits');
select tests.throws_like($$update public.shop_members set active = true where id = tests.fx('m_tech2_a')$$, 'PT402',
                         '%allows 6 team members%', 're-activating a member needs a free seat');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$update public.shop_members set active = true where id = tests.fx('m_tech2_a')$$), 0::bigint,
                'a technician cannot re-activate anyone (RLS, before any seat check)');

-- ============================================================ accepting never fails for seats
select tests.as_service();
select public.billing_upsert_plan('price_Seat6', 'prod_Seat', 'Crew', null, 9900, 'usd', 'month', 1, 5, '{}', 0, true);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq((select jsonb_build_array(e -> 'members_used', e -> 'max_members') from public.shop_entitlement(tests.fx('shop_a')) e),
                '[6, 5]'::jsonb, 'after a downgrade the shop is over its limit');
select tests.as_superuser();
select tests.fx_set('tok1', pg_temp.token('seat1@test.local'));
select tests.fx_set('tok2', pg_temp.token('seat2@test.local'));
select tests.authenticate_as(tests.fx('u_seat1'));
select tests.lives($$select public.accept_invite(tests.fx('tok1'))$$, 'an invitee still joins: the invite held the seat');
select tests.authenticate_as(tests.fx('u_seat2'));
select tests.lives($$select public.accept_invite(tests.fx('tok2'))$$, 'the second one too');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.seats(tests.fx('shop_a')), 6, 'invites turned into members: still six');
select tests.throws_like($$select public.invite_member(tests.fx('shop_a'), 'seat3@test.local', 'technician')$$, 'PT402',
                         'This shop''s plan allows 5 team members.', 'no new invite over the limit');

-- ============================================================ the operator is not limited
select tests.as_superuser();
select tests.lives($$select tests.add_member(tests.fx('shop_a'), 'seat4@test.local', 'technician')$$,
                   'direct / service writes are not limited');
select tests.as_service();
select tests.lives($$insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'seat5@test.local', 'technician')$$,
                   'nor service-role invites');
delete from public.shop_invites where shop_id = tests.fx('shop_a') and email = 'seat5@test.local';

-- ============================================================ expired and revoked invites free their seat
select public.billing_upsert_plan('price_Seat6', 'prod_Seat', 'Crew', null, 9900, 'usd', 'month', 1, 8, '{}', 0, true);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(pg_temp.seats(tests.fx('shop_a')), 7, 'seven members');
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat6@test.local', 'technician')$$, 'the eighth seat');
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'seat7@test.local', 'technician')$$, 'PT402', 'full');
select tests.as_superuser();
update public.shop_invites set expires_at = now() - interval '1 second' where shop_id = tests.fx('shop_a') and email = 'seat6@test.local';
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat7@test.local', 'technician')$$, 'an expired invite frees its seat');
select public.revoke_invite((select id from public.shop_invites where shop_id = tests.fx('shop_a') and email = 'seat7@test.local'
                               and revoked_at is null));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat8@test.local', 'technician')$$, 'a revoked one too');

-- ============================================================ no limit: comped, billing off, no plan
select tests.as_service();
select public.billing_set_comp(tests.fx('shop_a'), 'infinity');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat9@test.local', 'technician')$$, 'comped: no seat limit');
select tests.as_service();
select public.billing_set_comp(tests.fx('shop_a'), null);
select public.set_billing_config(false, 0);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.invite_member(tests.fx('shop_a'), 'seat10@test.local', 'technician')$$, 'billing off: no seat limit');
select tests.as_service();
select public.set_billing_config(true, 0);
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.lives($$select public.invite_member(tests.fx('shop_b'), 'b1@test.local', 'technician')$$, 'no plan (trial): no seat limit');

-- ============================================================ one seat: singular wording
select tests.as_service();
update public.shop_billing set status = 'active', plan_id = tests.fx('plan_1') where shop_id = tests.fx('shop_b');
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.throws_like($$select public.invite_member(tests.fx('shop_b'), 'b2@test.local', 'technician')$$, 'PT402',
                         'This shop''s plan allows 1 team member.', 'singular');
