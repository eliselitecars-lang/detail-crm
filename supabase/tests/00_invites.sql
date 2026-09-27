-- 00 foundation: invite_member, revoke_invite, public_get_invite, accept_invite.
\ir fixtures/two_shops.psql

select tests.fx_set('u_invitee', tests.create_user('Invitee@Test.Local', true, '{"full_name":"In Vitee"}'));
select tests.fx_set('u_unconfirmed', tests.create_user('unconfirmed@test.local', false));
select tests.fx_set('u_other', tests.create_user('someone-else@test.local'));

-- ------------------------------------------------------------ invite_member
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'x@test.local', 'technician')$$, '42501', 'managers cannot invite');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'x@test.local', 'technician')$$, '42501', 'technicians cannot invite');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'x@test.local', 'technician')$$, '42501',
                    'admin of B cannot invite into A');
select tests.as_anon();
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'x@test.local', 'technician')$$, '42501', 'anon cannot invite');

select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'x@test.local', 'owner')$$, '22023', 'cannot invite an owner');
select tests.throws($$select public.invite_member(tests.fx('shop_a'), 'not-an-email', 'technician')$$, '22023', 'invalid email');
select tests.throws_like($$select public.invite_member(tests.fx('shop_a'), 'TECH-A@test.local', 'manager')$$, '23505',
                         '%already a member%', 'cannot invite an existing active member (case-insensitive)');
select tests.fx_set('inv1', (public.invite_member(tests.fx('shop_a'), '  invitee@test.local ', 'manager')).id);
select tests.eq((select email::text from public.shop_invites where id = tests.fx('inv1')), 'invitee@test.local', 'email normalized');
select tests.eq((select invited_by from public.shop_invites where id = tests.fx('inv1')), tests.fx('u_admin_a'), 'invited_by recorded');
select tests.ok((select expires_at > now() + interval '6 days' from public.shop_invites where id = tests.fx('inv1')),
                'invite expires in 7 days');
-- re-inviting replaces the pending invite
select tests.fx_set('inv2', (public.invite_member(tests.fx('shop_a'), 'INVITEE@test.local', 'technician')).id);
select tests.ok((select revoked_at is not null from public.shop_invites where id = tests.fx('inv1')), 're-invite revokes the old pending invite');
select tests.eq((select count(*) from public.shop_invites where shop_id = tests.fx('shop_a') and accepted_at is null and revoked_at is null),
                1::bigint, 'one pending invite per email');
select tests.fx_set('tok1', (select token from public.shop_invites where id = tests.fx('inv1')));
select tests.fx_set('tok2', (select token from public.shop_invites where id = tests.fx('inv2')));

-- visibility
select tests.eq(tests.row_count('select * from public.shop_invites'), 2::bigint, 'admin reads own shop invites');
select tests.throws($$insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'y@test.local', 'admin')$$,
                    '42501', 'no direct invite inserts');
select tests.throws($$update public.shop_invites set role = 'admin'$$, '42501', 'no direct invite updates');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.shop_invites'), 0::bigint, 'managers cannot read invites (tokens)');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count('select * from public.shop_invites'), 0::bigint, 'admin of B cannot read A''s invites');
select tests.throws($$select public.revoke_invite(tests.fx('inv2'))$$, 'P0002', 'admin of B cannot revoke A''s invite');

-- public_get_invite
select tests.as_anon();
select tests.eq((select status from public.public_get_invite(tests.fx('tok2'))), 'pending', 'anon sees pending invite by token');
select tests.eq((select shop_name from public.public_get_invite(tests.fx('tok2'))), 'Shop A', 'invite shows shop name');
select tests.eq((select role::text from public.public_get_invite(tests.fx('tok2'))), 'technician', 'invite shows role');
select tests.eq((select status from public.public_get_invite(tests.fx('tok1'))), 'revoked', 'revoked status');
select tests.eq(tests.row_count($$select * from public.public_get_invite(gen_random_uuid())$$), 0::bigint, 'unknown token returns nothing');
select tests.throws('select * from public.shop_invites', '42501', 'anon cannot read invites table');

-- ------------------------------------------------------------ accept_invite
select tests.as_anon();
select tests.throws($$select public.accept_invite(tests.fx('tok2'))$$, '42501', 'anon cannot accept');
select tests.authenticate_as(tests.fx('u_other'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok2'))$$, '42501', '%different email%', 'wrong email cannot accept');
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok1'))$$, '22023', '%revoked%', 'revoked invite cannot be accepted');
select tests.throws($$select public.accept_invite(gen_random_uuid())$$, 'P0002', 'unknown token');
-- expired
select tests.as_superuser();
update public.shop_invites set expires_at = now() - interval '1 second' where id = tests.fx('inv2');
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok2'))$$, '22023', '%expired%', 'expired invite cannot be accepted');
select tests.eq((select status from public.public_get_invite(tests.fx('tok2'))), 'expired', 'expired status');
select tests.as_superuser();
update public.shop_invites set expires_at = now() + interval '1 day' where id = tests.fx('inv2');
-- email must be confirmed
update auth.users set email_confirmed_at = null where id = tests.fx('u_invitee');
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok2'))$$, '42501', '%confirm your email%', 'unconfirmed email cannot accept');
select tests.as_superuser();
update auth.users set email_confirmed_at = now() where id = tests.fx('u_invitee');
-- happy path (email differs only by case)
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.fx_set('m_invitee', (public.accept_invite(tests.fx('tok2'))).id);
select tests.eq((select role::text from public.shop_members where id = tests.fx('m_invitee')), 'technician', 'membership created with invite role');
select tests.eq((select display_name from public.shop_members where id = tests.fx('m_invitee')), 'In Vitee', 'display name from profile');
select tests.ok(public.is_shop_member(tests.fx('shop_a')), 'invitee is now a member');
select tests.throws_like($$select public.accept_invite(tests.fx('tok2'))$$, '22023', '%already used%', 'invite cannot be reused');
select tests.eq((select status from public.public_get_invite(tests.fx('tok2'))), 'accepted', 'accepted status');
select tests.as_superuser();
select tests.eq((select accepted_by from public.shop_invites where id = tests.fx('inv2')), tests.fx('u_invitee'), 'accepted_by recorded');
select tests.throws($$select public.revoke_invite(tests.fx('inv2'))$$, 'P0002', 'superuser has no shop role (revoke is admin-only)');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws_like($$select public.revoke_invite(tests.fx('inv2'))$$, '22023', '%already accepted%', 'accepted invite cannot be revoked');

-- an unconfirmed account cannot accept even with the right email
select tests.fx_set('inv3', (public.invite_member(tests.fx('shop_a'), 'unconfirmed@test.local', 'technician')).id);
select tests.fx_set('tok3', (select token from public.shop_invites where id = tests.fx('inv3')));
select tests.authenticate_as(tests.fx('u_unconfirmed'));
select tests.throws($$select public.accept_invite(tests.fx('tok3'))$$, '42501', 'never-confirmed account cannot accept');

-- revoke works
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$select public.revoke_invite(tests.fx('inv3'))$$, 'admin revokes');
select tests.lives($$select public.revoke_invite(tests.fx('inv3'))$$, 'revoking twice is a no-op');

-- a deactivated member is reactivated by accepting a new invite
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_invitee');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('inv4', (public.invite_member(tests.fx('shop_a'), 'invitee@test.local', 'manager')).id);
select tests.fx_set('tok4', (select token from public.shop_invites where id = tests.fx('inv4')));
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.eq((public.accept_invite(tests.fx('tok4'))).id, tests.fx('m_invitee'), 'same membership row reactivated');
select tests.eq((select role::text || '/' || active from public.shop_members where id = tests.fx('m_invitee')), 'manager/true',
                'reactivated with the new role');

-- already an active member (e.g. invited twice through a race)
select tests.as_superuser();
insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'invitee@test.local', 'technician')
  returning tests.fx_set('inv5', id);
select tests.fx_set('tok5', (select token from public.shop_invites where id = tests.fx('inv5')));
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok5'))$$, '23505', '%already a member%',
                         'accepting while already active is rejected');

-- the invite table itself rejects owner invites
select tests.as_superuser();
select tests.throws($$insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'o@test.local', 'owner')$$,
                    '23514', 'owner invites impossible at table level');
