-- ============================================================================
-- 0131 — The platform's offer states its free trial.
--
-- public_billing_plans (0101) returns only the plans, so /pricing and the
-- shop-setup page could not say how long the in-app trial runs: the length
-- lives in platform_config billing_trial_days, which clients cannot read.
--
-- public_billing_offer() (anon + authenticated, new) returns
--   {plans: [...], trial_days, trial_available}
--   * plans: exactly public_billing_plans() (the same array and item shape;
--     [] while billing is off). public_billing_plans itself is unchanged.
--   * trial_days: billing_trial_days() while billing is on, else 0. It is the
--     trial a person's FIRST shop gets (0120: once per person, by user id and
--     email key), so pages word it "N-day free trial for your first shop".
--   * trial_available: for a signed-in caller, whether a shop they create
--     now would get that trial (billing on, trial_days > 0, and never given
--     one: billing_trial_already_given); null signed out (unknown). It is
--     about the caller only.
-- Nothing else changes.
-- ============================================================================

create function public.public_billing_offer() returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'plans', public.public_billing_plans(),
           'trial_days', d.days,
           'trial_available',
             case when auth.uid() is null then null
                  else d.days > 0 and not public.billing_trial_already_given(auth.uid()) end)
    from (select case when public.billing_enabled() then public.billing_trial_days() else 0 end
                   as days) d
$$;

comment on function public.public_billing_offer() is
  'anon + authenticated (0131): {plans (public_billing_plans), trial_days (billing_trial_days while billing is on, else 0; the trial of a person''s first shop — once per person, 0120), trial_available (signed in: whether a shop created now gets that trial; null signed out)}. Never Stripe ids.';

revoke execute on function public.public_billing_offer() from public;
grant execute on function public.public_billing_offer() to anon, authenticated, service_role;
