-- 00 foundation: shop_members (roles, owner invariants), transfer_ownership,
-- leave_shop, shop_team, member_compensation, shop_stripe_accounts,
-- shop_counters / next_document_number.
\ir fixtures/two_shops.psql

-- ------------------------------------------------------------ visibility
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count('select * from public.shop_members'), 5::bigint, 'manager sees the whole roster of own shop');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(id) from public.shop_members), array[tests.fx('m_tech_a')],
                'technician reads only their own membership row');
select tests.eq((select count(*) from public.shop_team(tests.fx('shop_a'))), 5::bigint, 'technician gets the team directory via shop_team');
select tests.ok((select bool_and(phone is null and email is null) from public.shop_team(tests.fx('shop_a'))),
                'shop_team hides contact details from technicians');
select tests.throws($$select * from public.shop_team(tests.fx('shop_b'))$$, '42501', 'shop_team denies non-members');
select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq((select email from public.shop_team(tests.fx('shop_a')) where member_id = tests.fx('m_tech_a')),
                'tech-a@test.local', 'shop_team returns emails to managers');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.eq(tests.row_count($$select 1 from public.shop_members where shop_id = tests.fx('shop_b')$$), 0::bigint,
                'owner of A cannot see B''s members');

-- ------------------------------------------------------------ inserts
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$insert into public.shop_members (shop_id, user_id, role, display_name)
                      values (tests.fx('shop_a'), tests.fx('u_outsider'), 'manager', 'X')$$, '42501',
                    'even the owner cannot insert memberships directly (invites only)');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.throws($$insert into public.shop_members (shop_id, user_id, role, display_name)
                      values (tests.fx('shop_a'), auth.uid(), 'owner', 'Me')$$, '42501',
                    'a user cannot insert themselves into another shop');

-- ------------------------------------------------------------ updates
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.lives($$update public.shop_members set role = 'manager', calendar_color = '#00FF00' where id = tests.fx('m_tech2_a')$$,
                   'admin changes a technician''s role');
select tests.eq((select role::text from public.shop_members where id = tests.fx('m_tech2_a')), 'manager', 'role changed');
select tests.lives($$update public.shop_members set active = false where id = tests.fx('m_tech2_a')$$, 'admin deactivates a member');
select tests.throws_like($$update public.shop_members set role = 'owner' where id = tests.fx('m_manager_a')$$, '42501',
                         '%transfer_ownership%', 'admin cannot promote to owner');
select tests.throws_like($$update public.shop_members set display_name = 'Boss' where id = tests.fx('m_owner_a')$$, '42501',
                         '%only the owner%', 'admin cannot modify the owner row');
select tests.throws_like($$update public.shop_members set role = 'technician' where id = tests.fx('m_owner_a')$$, '42501',
                         '%only the owner%', 'admin cannot demote the owner');
select tests.throws_like($$update public.shop_members set role = 'owner' where id = tests.fx('m_admin_a')$$, '42501',
                         '%own role%', 'admin cannot change their own role');
select tests.throws_like($$delete from public.shop_members where id = tests.fx('m_owner_a')$$, '42501',
                         '%owner membership%', 'admin cannot delete the owner row');
select tests.throws($$update public.shop_members set user_id = tests.fx('u_outsider') where id = tests.fx('m_manager_a')$$, '42501',
                    'user_id is immutable');
select tests.throws($$update public.shop_members set shop_id = tests.fx('shop_b') where id = tests.fx('m_manager_a')$$, '42501',
                    'shop_id is immutable');
select tests.eq(tests.row_count($$update public.shop_members set role = 'technician' where id = tests.fx('m_admin_b')$$), 0::bigint,
                'admin of A cannot touch B''s members');
select tests.eq(tests.row_count($$delete from public.shop_members where id = tests.fx('m_tech_b')$$), 0::bigint,
                'admin of A cannot delete B''s members');

select tests.authenticate_as(tests.fx('u_manager_a'));
select tests.eq(tests.row_count($$update public.shop_members set role = 'admin' where id = tests.fx('m_tech_a')$$), 0::bigint,
                'managers cannot change roles');
select tests.eq(tests.row_count($$delete from public.shop_members where id = tests.fx('m_tech_a')$$), 0::bigint,
                'managers cannot remove members');
select tests.throws_like($$update public.shop_members set role = 'admin' where id = tests.fx('m_manager_a')$$, '42501',
                         '%own role%', 'manager cannot self-promote');
select tests.throws_like($$update public.shop_members set active = false where id = tests.fx('m_manager_a')$$, '42501',
                         '%own active%', 'members cannot toggle their own active flag');

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.lives($$update public.shop_members set display_name = 'Tech A', phone = '+12055550111', calendar_color = '#ABCDEF'
                     where id = tests.fx('m_tech_a')$$, 'technician edits own display fields');
select tests.throws_like($$update public.shop_members set role = 'manager' where id = tests.fx('m_tech_a')$$, '42501',
                         '%own role%', 'technician cannot change own role');
select tests.throws($$update public.shop_members set calendar_color = 'blue' where id = tests.fx('m_tech_a')$$, '23514',
                    'calendar_color must be hex');
select tests.eq(tests.row_count($$update public.shop_members set display_name = 'X' where id = tests.fx('m_manager_a')$$), 0::bigint,
                'technician cannot edit others');

select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$update public.shop_members set role = 'technician' where id = tests.fx('m_admin_a')$$, 'owner changes an admin''s role');
select tests.lives($$update public.shop_members set display_name = 'The Owner' where id = tests.fx('m_owner_a')$$, 'owner edits own display name');
select tests.throws_like($$update public.shop_members set role = 'admin' where id = tests.fx('m_owner_a')$$, '42501',
                         '%own role%', 'owner cannot change own role');
select tests.throws_like($$delete from public.shop_members where id = tests.fx('m_owner_a')$$, '42501',
                         '%owner membership%', 'owner cannot delete own owner row');
select tests.lives($$delete from public.shop_members where id = tests.fx('m_tech2_a')$$, 'owner removes a member');
select tests.eq((select count(*) from public.job_assignments where member_id = tests.fx('m_tech2_a')), 0::bigint,
                'removing a member removes their assignments');
select tests.as_superuser();
select tests.lives($$update public.shop_members set role = 'admin' where id = tests.fx('m_admin_a')$$);

-- ------------------------------------------------------------ owner invariants (all contexts)
select tests.as_superuser();
select tests.throws_like($$update public.shop_members set role = 'owner' where id = tests.fx('m_admin_a')$$, '23P01', '%one_owner%',
                         'a second owner is impossible even for trusted code');
select tests.throws_like($$update public.shop_members set role = 'admin' where id = tests.fx('m_owner_a')$$, '23514',
                         '%exactly one owner%', 'removing the only owner is impossible even for trusted code');
select tests.throws($$update public.shop_members set active = false where id = tests.fx('m_owner_a')$$, '23514', 'owner must stay active');
select tests.throws_like($$delete from public.shop_members where id = tests.fx('m_owner_a')$$, '23514', '%owner membership%',
                         'owner row cannot be deleted while the shop exists');
select tests.throws_like($$delete from auth.users where id = tests.fx('u_owner_a')$$, '23514', '%owner membership%',
                         'deleting the owner''s auth account is blocked until ownership is transferred');
select tests.lives($$delete from auth.users where id = tests.fx('u_manager_b')$$, 'deleting a non-owner auth user cascades');
select tests.eq((select count(*) from public.shop_members where id = tests.fx('m_manager_b')), 0::bigint, 'membership removed with the user');

-- ------------------------------------------------------------ transfer_ownership
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_admin_a'))$$, '42501', 'admin cannot transfer ownership');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_owner_a'))$$, '22023', 'cannot transfer to self');
select tests.throws($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_tech_b'))$$, 'P0002', 'cannot transfer to another shop''s member');
select tests.as_superuser();
update public.shop_members set active = false where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_tech_a'))$$, '22023', 'cannot transfer to an inactive member');
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.lives($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_manager_a'))$$, 'owner transfers ownership');
select tests.eq((select role::text from public.shop_members where id = tests.fx('m_manager_a')), 'owner', 'target is now owner');
select tests.eq((select role::text from public.shop_members where id = tests.fx('m_owner_a')), 'admin', 'previous owner is now admin');
select tests.eq((select count(*) from public.shop_members where shop_id = tests.fx('shop_a') and role = 'owner'), 1::bigint,
                'still exactly one owner');
select tests.throws($$select public.transfer_ownership(tests.fx('shop_a'), tests.fx('m_owner_a'))$$, '42501', 'former owner can no longer transfer');
select tests.eq(tests.row_count($$delete from public.shops where id = tests.fx('shop_a')$$), 0::bigint, 'former owner (now admin) cannot delete the shop');

-- ------------------------------------------------------------ leave_shop
select tests.authenticate_as(tests.fx('u_manager_a'));  -- now the owner
select tests.throws_like($$select public.leave_shop(tests.fx('shop_a'))$$, '23514', '%transfer ownership%', 'owner cannot leave');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count($$delete from public.shop_members where id = tests.fx('m_tech_a')$$), 0::bigint,
                'technicians cannot delete memberships directly (leave_shop is the way out)');
select tests.lives($$select public.leave_shop(tests.fx('shop_a'))$$, 'technician leaves');
select tests.ok(not public.is_shop_member(tests.fx('shop_a')), 'left member is no longer a member');
select tests.eq(tests.row_count('select * from public.jobs'), 0::bigint, 'left member loses job access');
select tests.eq(tests.row_count('select * from public.shops'), 0::bigint, 'left member loses shop access');
select tests.throws($$select public.leave_shop(tests.fx('shop_a'))$$, 'P0002', 'cannot leave twice');
select tests.throws($$select public.leave_shop(tests.fx('shop_b'))$$, 'P0002', 'cannot leave a shop you are not in');

-- ------------------------------------------------------------ member_compensation
select tests.as_superuser();
update public.shop_members set active = true where id = tests.fx('m_tech_a');
select tests.authenticate_as(tests.fx('u_owner_a'));  -- now admin of A
select tests.lives($$insert into public.member_compensation (shop_id, member_id, hourly_rate_cents, commission_bps)
                     values (tests.fx('shop_a'), tests.fx('m_tech_a'), 2500, 1000)$$, 'admin sets pay rates');
select tests.throws($$insert into public.member_compensation (shop_id, member_id, hourly_rate_cents)
                      values (tests.fx('shop_a'), tests.fx('m_tech_b'), 1)$$, '23503',
                    'composite FK blocks pointing at another shop''s member');
select tests.throws($$insert into public.member_compensation (shop_id, member_id, hourly_rate_cents)
                      values (tests.fx('shop_b'), tests.fx('m_tech_b'), 1)$$, '42501', 'cannot write another shop''s pay rates');
select tests.throws($$update public.member_compensation set commission_bps = 10001 where member_id = tests.fx('m_tech_a')$$, '23514',
                    'commission capped at 100%');
select tests.throws($$update public.member_compensation set hourly_rate_cents = -1 where member_id = tests.fx('m_tech_a')$$, '23514',
                    'non-negative pay');
select tests.as_superuser();
insert into public.member_compensation (shop_id, member_id, hourly_rate_cents) values (tests.fx('shop_b'), tests.fx('m_tech_b'), 3000);
insert into public.member_compensation (shop_id, member_id, hourly_rate_cents) values (tests.fx('shop_a'), tests.fx('m_admin_a'), 4000);

select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq((select array_agg(hourly_rate_cents) from public.member_compensation), array[2500::bigint],
                'technician reads only their own pay row');
select tests.eq(tests.row_count($$update public.member_compensation set hourly_rate_cents = 99999$$), 0::bigint,
                'technician cannot change pay');
select tests.throws($$insert into public.member_compensation (shop_id, member_id) values (tests.fx('shop_a'), tests.fx('m_tech_a'))$$,
                    '42501', 'technician cannot insert pay rows');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq(tests.row_count('select * from public.member_compensation'), 2::bigint, 'admin reads all pay rows of own shop only');
select tests.eq(tests.row_count($$delete from public.member_compensation where member_id = tests.fx('m_tech_b')$$), 0::bigint,
                'admin of A cannot delete B''s pay rows');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq(tests.row_count($$update public.member_compensation set hourly_rate_cents = 1 where shop_id = tests.fx('shop_a')$$),
                0::bigint, 'admin of B cannot update A''s pay rows');

-- ------------------------------------------------------------ shop_stripe_accounts
select tests.as_service();
select tests.lives($$insert into public.shop_stripe_accounts (shop_id, stripe_account_id, charges_enabled)
                     values (tests.fx('shop_a'), 'acct_1ABC', true),
                            (tests.fx('shop_b'), 'acct_2XYZ', false)$$, 'service_role writes Stripe accounts');
select tests.throws($$insert into public.shop_stripe_accounts (shop_id, stripe_account_id) values (tests.fx('shop_a'), 'nope')$$,
                    '23514', 'stripe account id format');
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.eq((select array_agg(stripe_account_id) from public.shop_stripe_accounts), array['acct_1ABC'],
                'admin reads own shop''s Stripe account only');
select tests.throws($$update public.shop_stripe_accounts set charges_enabled = false$$, '42501', 'admin cannot write Stripe status');
select tests.throws($$insert into public.shop_stripe_accounts (shop_id, stripe_account_id) values (tests.fx('shop_a'), 'acct_3')$$,
                    '42501', 'admin cannot insert Stripe accounts');
select tests.authenticate_as(tests.fx('u_outsider'));
select tests.eq(tests.row_count('select * from public.shop_stripe_accounts'), 0::bigint, 'outsider sees no Stripe accounts');
select tests.authenticate_as(tests.fx('u_tech_a'));
select tests.eq(tests.row_count('select * from public.shop_stripe_accounts'), 0::bigint, 'technician cannot read Stripe account');
select tests.authenticate_as(tests.fx('u_admin_b'));
select tests.eq((select array_agg(stripe_account_id) from public.shop_stripe_accounts), array['acct_2XYZ'], 'isolation for shop B admin');

-- ------------------------------------------------------------ counters
select tests.authenticate_as(tests.fx('u_admin_a'));
select tests.throws('select * from public.shop_counters', '42501', 'no client access to counters');
select tests.throws($$select public.next_document_number(tests.fx('shop_a'), 'invoice')$$, '42501',
                    'clients cannot burn document numbers');
select tests.as_service();
select tests.eq(public.next_document_number(tests.fx('shop_a'), 'invoice'), 1001::bigint, 'first invoice number is 1001');
select tests.eq(public.next_document_number(tests.fx('shop_a'), 'invoice'), 1002::bigint, 'numbers increase');
select tests.eq(public.next_document_number(tests.fx('shop_a'), 'quote'), 1001::bigint, 'kinds are independent');
select tests.eq(public.next_document_number(tests.fx('shop_b'), 'invoice'), 1001::bigint, 'shops are independent');
select tests.as_superuser();
delete from public.shop_counters where shop_id = tests.fx('shop_b') and kind = 'quote';
select tests.eq(public.next_document_number(tests.fx('shop_b'), 'quote'), 1001::bigint, 'missing counter row self-heals at 1001');
select tests.throws($$select public.next_document_number(gen_random_uuid(), 'job')$$, '23503', 'unknown shop rejected');
