-- 120 (0123): the once-per-person trial key folds Gmail's same-inbox
-- aliases. Gmail ignores dots in the local part and treats googlemail.com
-- as gmail.com (GoTrue normalizes neither), so a lapsed owner could sign up
-- again as sh.ine.owner@gmail.com and get a new trial. Now the key drops
-- those dots and uses gmail.com (plus 0120's "+tag"); other domains keep
-- their dots. A grant recorded under the 0120 key still matches.
\ir fixtures/two_shops.psql

create function pg_temp.trial(p_shop uuid) returns boolean language sql as $$
  select trial_ends_at is not null from public.shop_billing where shop_id = p_shop $$;
grant execute on function pg_temp.trial(uuid) to service_role;

-- ============================================================ the key
select tests.as_superuser();
select tests.eq((select array_agg(public.billing_trial_email_key(e) = public.billing_trial_email_key('shineowner@gmail.com') order by o)
                   from unnest(array['shineowner@gmail.com', 'shine.owner@gmail.com', 'S.h.ine.Owner@Gmail.com ',
                                     'shineowner+2@gmail.com', 'shine.owner+x.y@googlemail.com', 'shineowner@googlemail.com',
                                     'shineowner2@gmail.com', 'shineowner@example.com'])
                                with ordinality u(e, o)),
                array[true, true, true, true, true, true, false, false], 'one Gmail inbox = one key');
select tests.eq(public.billing_trial_email_key('shine.owner@example.com') = public.billing_trial_email_key('shineowner@example.com'),
                false, 'other domains keep their dots (they may be different mailboxes)');
select tests.eq(public.billing_trial_email_key('Eve+tag@Test.local'), encode(sha256(convert_to('eve@test.local', 'UTF8')), 'hex'),
                'other domains: the 0120 key (lower-cased, +tag dropped)');
select tests.eq(public.billing_trial_email_key(''), null, 'no email: no key');

-- ============================================================ the repro
select tests.as_service();
select public.set_billing_config(true, 14);
select tests.fx_set('shine1', tests.make_shop('shineowner@gmail.com', 'shine-1', 'Shine'));
select tests.as_service();
select tests.eq(pg_temp.trial(tests.fx('shine1')), true, 'the first shop gets the trial');
select tests.fx_set('shine2', tests.make_shop('shine.owner@gmail.com', 'shine-2', 'Shine'));
select tests.as_service();
select tests.eq(pg_temp.trial(tests.fx('shine2')), false, 'a dotted variant of the same inbox: no new trial');
select tests.fx_set('shine3', tests.make_shop('shineowner@googlemail.com', 'shine-3', 'Shine'));
select tests.as_service();
select tests.eq(pg_temp.trial(tests.fx('shine3')), false, 'googlemail.com: no new trial');
select tests.fx_set('other', tests.make_shop('shineowner2@gmail.com', 'shine-other', 'Other'));
select tests.as_service();
select tests.eq(pg_temp.trial(tests.fx('other')), true, 'a different Gmail inbox gets its own trial');

-- ============================================================ grants recorded under the 0120 key
-- (an account deleted before 0123: only the old hash is left)
select tests.as_superuser();
insert into public.billing_trial_grants (user_id, email_key, trial_shop_id, trial_ends_at)
values (null, public.billing_trial_email_key_0120('old.timer@gmail.com'), gen_random_uuid(), now() - interval '30 days');
select tests.fx_set('old1', tests.make_shop('old.timer@gmail.com', 'old-timer', 'Old'));
select tests.as_service();
select tests.eq(pg_temp.trial(tests.fx('old1')), false, 'the same address as a pre-0123 grant: no new trial');

-- ============================================================ privacy
select tests.authenticate_as(tests.fx('u_owner_a'));
select tests.throws($$select public.billing_trial_email_key_0120('x@y.z')$$, '42501', 'owners cannot call the old key');
