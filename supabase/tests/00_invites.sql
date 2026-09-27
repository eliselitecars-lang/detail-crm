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
insert into public.shop_invites (shop_id, email, role, invited_by)
  values (tests.fx('shop_a'), 'invitee@test.local', 'technician', tests.fx('u_admin_a'))
  returning tests.fx_set('inv5', id);
select tests.fx_set('tok5', (select token from public.shop_invites where id = tests.fx('inv5')));
select tests.authenticate_as(tests.fx('u_invitee'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok5'))$$, '23505', '%already a member%',
                         'accepting while already active is rejected');

-- the invite table itself rejects owner invites
select tests.as_superuser();
select tests.throws($$insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'o@test.local', 'owner')$$,
                    '23514', 'owner invites impossible at table level');

-- ------------------------------------------------------------ inviter authority
-- An invite only carries authority while its inviter is an active owner/admin
-- of the shop: deactivating, removing or demoting the inviter revokes their
-- pending invites, and accept_invite re-checks the inviter.

-- Regression: an admin about to be removed invites a second address they
-- control as 'admin'; after the owner deactivates them the invite is dead.
do $$
declare
  v_inv public.shop_invites;
  v_alt uuid := tests.create_user('eve-alt@test.local');
  v_ok  boolean;
begin
  perform tests.authenticate_as(tests.fx('u_admin_a'));
  v_inv := public.invite_member(tests.fx('shop_a'), 'eve-alt@test.local', 'admin');
  perform tests.fx_set('tok_eve', v_inv.token);
  perform tests.fx_set('inv_eve', v_inv.id);
  perform tests.fx_set('u_eve_alt', v_alt);
  perform tests.authenticate_as(tests.fx('u_owner_a'));
  update public.shop_members set active = false where id = tests.fx('m_admin_a');
  perform tests.authenticate_as(v_alt);
  begin
    perform public.accept_invite(v_inv.token);
    v_ok := false;
  exception when others then
    v_ok := true;
  end;
  perform tests.as_superuser();
  perform tests.ok(v_ok and not exists (select 1 from public.shop_members m
                                         where m.shop_id = tests.fx('shop_a') and m.user_id = v_alt and m.active),
                   'an invite sent by an admin who has since been removed must not grant admin access');
end
$$;
select tests.ok((select revoked_at is not null from public.shop_invites where id = tests.fx('inv_eve')),
                'deactivating an admin revokes the invites they sent');
select tests.authenticate_as(tests.fx('u_eve_alt'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok_eve'))$$, '22023', '%revoked%',
                         'the removed admin''s invite reports revoked');
select tests.as_anon();
select tests.eq((select status from public.public_get_invite(tests.fx('tok_eve'))), 'revoked',
                'landing page shows the removed admin''s invite as revoked');

-- Reactivating the admin does not resurrect their revoked invites.
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set active = true where id = tests.fx('m_admin_a');
select tests.authenticate_as(tests.fx('u_eve_alt'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok_eve'))$$, '22023', '%revoked%',
                         'reactivating the inviter does not revive revoked invites');

-- Demotion below admin revokes too; only that inviter's invites, only in that
-- shop. Setup: admin A (also an admin of shop B) invites into A and B; the
-- owner and manager-a's peer admin invite as controls.
select tests.as_superuser();
select tests.fx_set('m_admin_a_in_b', tests.add_member(tests.fx('shop_b'), 'admin-a@test.local', 'admin'));
select tests.fx_set('m_admin2_a', tests.add_member(tests.fx('shop_a'), 'admin2-a@test.local', 'admin'));
select tests.fx_set('u_admin2_a', tests.user_id('admin2-a@test.local'));
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('inv_demote_a', (public.invite_member(tests.fx('shop_a'), 'demote-a@test.local', 'admin')).id);
select tests.fx_set('inv_demote_b', (public.invite_member(tests.fx('shop_b'), 'demote-b@test.local', 'technician')).id);
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.fx_set('inv_owner_a', (public.invite_member(tests.fx('shop_a'), 'owner-pick@test.local', 'technician')).id);
select tests.authenticate_as(tests.fx('u_admin2_a'));
select tests.fx_set('inv_admin2_a', (public.invite_member(tests.fx('shop_a'), 'peer-pick@test.local', 'manager')).id);

-- an unrelated edit of the admin's row (name/color) keeps their invites
select tests.authenticate_as(tests.fx('u_owner_a'));
update public.shop_members set display_name = 'Admin A (renamed)', calendar_color = '#112233' where id = tests.fx('m_admin_a');
select tests.ok((select revoked_at is null from public.shop_invites where id = tests.fx('inv_demote_a')),
                'editing an admin''s name/color keeps their invites');

update public.shop_members set role = 'manager' where id = tests.fx('m_admin_a');
select tests.as_superuser();
select tests.ok((select revoked_at is not null from public.shop_invites where id = tests.fx('inv_demote_a')),
                'demoting an admin to manager revokes the invites they sent in that shop');
select tests.ok((select revoked_at is null from public.shop_invites where id = tests.fx('inv_demote_b')),
                'the same person''s invites in another shop (where they are still admin) are untouched');
select tests.ok((select revoked_at is null from public.shop_invites where id = tests.fx('inv_owner_a')),
                'the owner''s invites are untouched');
select tests.ok((select revoked_at is null from public.shop_invites where id = tests.fx('inv_admin2_a')),
                'another admin''s invites are untouched');
select tests.fx_set('tok_inv_owner_a', (select token from public.shop_invites where id = tests.fx('inv_owner_a')));
select tests.fx_set('u_owner_pick', tests.create_user('owner-pick@test.local'));
select tests.authenticate_as(tests.fx('u_owner_pick'));
select tests.lives($$select public.accept_invite(tests.fx('tok_inv_owner_a'))$$,
                   'an invite from a still-valid inviter is accepted');

-- Removing (deleting) an admin membership revokes their pending invites.
select tests.authenticate_as(tests.fx('u_owner_a'));
delete from public.shop_members where id = tests.fx('m_admin2_a');
select tests.as_superuser();
select tests.ok((select revoked_at is not null from public.shop_invites where id = tests.fx('inv_admin2_a')),
                'removing an admin revokes the invites they sent');
select tests.eq((select count(*) from public.shop_invites where shop_id = tests.fx('shop_a') and invited_by = tests.fx('u_admin2_a')
                   and accepted_at is null and revoked_at is null), 0::bigint, 'no pending invites of a removed admin remain');

-- Leaving the shop (leave_shop) likewise revokes the leaver's invites.
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.fx_set('inv_leaver_b', (public.invite_member(tests.fx('shop_b'), 'leaver-pick@test.local', 'admin')).id);
select tests.lives($$select public.leave_shop(tests.fx('shop_b'))$$, 'admin of B leaves');
select tests.as_superuser();
select tests.ok((select revoked_at is not null from public.shop_invites where id = tests.fx('inv_leaver_b')),
                'an admin who leaves loses the invites they sent');

-- Ownership transfer keeps the old owner an admin: their invites survive.
select tests.authenticate_as(tests.fx('u_owner_b'));
select tests.fx_set('inv_old_owner_b', (public.invite_member(tests.fx('shop_b'), 'kept@test.local', 'technician')).id);
select tests.lives($$select public.transfer_ownership(tests.fx('shop_b'), tests.fx('m_manager_b'))$$, 'owner of B transfers ownership');
select tests.as_superuser();
select tests.ok((select revoked_at is null from public.shop_invites where id = tests.fx('inv_old_owner_b')),
                'a former owner who stays admin keeps their invites');

-- Defense in depth: an invite whose inviter is no longer an active owner/admin
-- is refused even if it was never revoked (e.g. the inviter account was
-- deleted, leaving invited_by null, or a row written without an inviter).
select tests.as_superuser();
insert into public.shop_invites (shop_id, email, role) values (tests.fx('shop_a'), 'orphan@test.local', 'admin')
  returning tests.fx_set('inv_orphan', id);
insert into public.shop_invites (shop_id, email, role, invited_by)
  values (tests.fx('shop_a'), 'by-manager@test.local', 'admin', tests.fx('u_manager_a'))
  returning tests.fx_set('inv_by_manager', id);
select tests.fx_set('tok_inv_orphan', (select token from public.shop_invites where id = tests.fx('inv_orphan')));
select tests.fx_set('tok_inv_by_manager', (select token from public.shop_invites where id = tests.fx('inv_by_manager')));
select tests.fx_set('u_orphan', tests.create_user('orphan@test.local'));
select tests.fx_set('u_by_manager', tests.create_user('by-manager@test.local'));
select tests.authenticate_as(tests.fx('u_orphan'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok_inv_orphan'))$$,
                         '22023', '%revoked%', 'an invite without a valid inviter cannot be accepted');
select tests.authenticate_as(tests.fx('u_by_manager'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok_inv_by_manager'))$$,
                         '22023', '%revoked%', 'an invite whose inviter is not owner/admin cannot be accepted');
select tests.as_anon();
select tests.eq((select status from public.public_get_invite(tests.fx('tok_inv_orphan'))),
                'revoked', 'landing page shows an inviter-less invite as revoked');
select tests.as_superuser();
select tests.eq((select count(*) from public.shop_members m where m.shop_id = tests.fx('shop_a')
                   and m.user_id in (tests.fx('u_orphan'), tests.fx('u_by_manager'))), 0::bigint,
                'no membership was created from invalid invites');

-- Deleting the inviter's account (cascades their membership, nulls
-- invited_by) leaves their invite unusable.
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.fx_set('inv_deleted_inviter', (public.invite_member(tests.fx('shop_b'), 'ghost@test.local', 'admin')).id);
select tests.as_superuser();
select tests.fx_set('tok_inv_deleted_inviter', (select token from public.shop_invites where id = tests.fx('inv_deleted_inviter')));
delete from auth.users where id = tests.fx('u_admin_a');
select tests.ok((select revoked_at is not null or invited_by is null from public.shop_invites where id = tests.fx('inv_deleted_inviter')),
                'deleting the inviter account revokes or orphans their invite');
select tests.fx_set('u_ghost', tests.create_user('ghost@test.local'));
select tests.authenticate_as(tests.fx('u_ghost'));
select tests.throws_like($$select public.accept_invite(tests.fx('tok_inv_deleted_inviter'))$$,
                         '22023', '%revoked%', 'an invite from a deleted account cannot be accepted');
select tests.as_superuser();
select tests.ok(not exists (select 1 from public.shop_members m where m.user_id = tests.fx('u_ghost')),
                'the deleted inviter''s invite granted nothing');
