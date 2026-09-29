-- ============================================================================
-- 0119 — Round-8 hardening: a lapsed shop's repeating jobs wait; marketing
-- email carries the shop's postal address.
--
-- 1. The nightly series extension skips lapsed shops (billing 0102).
--
-- docs/BILLING.md §8: while a shop is lapsed, creating new jobs and
-- recurring job series is paused. 0102 enforces that for the shop's own
-- staff (PT402 on insert, end users only) and gave the batch jobs a
-- shop_can_write filter — automations, service / document follow-ups and
-- campaign claims — but not generate_series_jobs, the daily pg_cron job
-- detail-crm-generate-series (service role: the PT402 guard never applies
-- to it). Every active series of a shop that stopped paying kept creating
-- new visits (with lines, fees, membership uses and assignees) out to its
-- horizon every night for as long as the shop stayed lapsed.
--
-- generate_series_jobs (0051 body) now extends only the series of shops
-- that can write (shop_can_write: always true while billing is off). Their
-- series stay active and untouched; the first run after the shop pays
-- again extends them to the horizon as usual.
--
-- 2. Every marketing email carries the shop's postal address
-- (CAN-SPAM, 15 U.S.C. 7704(a)(5)(A)(iii)).
--
-- Campaign emails and the promotional follow-up emails (comms_is_marketing_key:
-- follow_up, service_followup) are commercial email. The platform already
-- adds the opt-out to each one (comms_email_with_unsubscribe, 0033), but
-- never the sender's valid physical postal address, which the same law
-- requires, and no placeholder offered it: every marketing email went out
-- without one even though the shop's address is on file (shops.address_line1
-- … postal_code, Settings → Business profile).
--
-- A marketing email is exactly an outbound email with an unsubscribe_token
-- (the messages_unsubscribe_token contract, 0033), whichever code queues it
-- (launch_campaign 0035, enqueue_message_core 0083 for automations,
-- follow-ups and staff sends). So the rule lives on that insert:
--   * comms_shop_postal_address(shop) (internal): the shop's address on one
--     line — "line1, line2, city, region postal_code[, country]" (country
--     only outside the US) — or null when the shop has no street line or no
--     city on file.
--   * comms_email_with_postal_address(body, shop_name, address) (internal,
--     immutable): the body ended with "<shop name> · <address>" (the body is
--     cut to keep the 50000-character limit), unchanged when the wording
--     already shows the address.
--   * messages_02_marketing_postal_address (new, BEFORE INSERT, outbound
--     email with an unsubscribe_token):
--       - address on file: the footer is appended (after the unsubscribe
--         line);
--       - no address, campaign message: the insert fails
--           55000 'add your shop''s mailing address (Settings → Business
--                  profile) before sending marketing email: the law requires
--                  it in every marketing email'
--           HINT  'postal_address_required'
--         so launch_campaign refuses the whole launch (nothing is queued);
--       - no address, any other marketing email (an automation, follow-up or
--         a template sent by hand): the row is not inserted, so the queueing
--         code (enqueue_message_core) returns null — nothing was queued —
--         exactly as when no working unsubscribe link exists (0033).
-- Transactional email (confirmations, reminders, invoices, receipts) is not
-- commercial and is unchanged.
-- ============================================================================

-- ===========================================================================
-- 1. generate_series_jobs — 0051 body + shop_can_write
-- ===========================================================================
create or replace function public.generate_series_jobs(p_now timestamptz default now())
returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now    timestamptz := public.effective_now(p_now);
  v_id     uuid;
  v_total  integer := 0;
begin
  for v_id in
    select js.id from public.job_series js
     where js.active
       and public.shop_can_write(js.shop_id)      -- 0119: a lapsed shop's series wait
     order by js.created_at, js.id
  loop
    begin
      v_total := v_total + public.job_series_generate(v_id, v_now, false);
    exception when others then
      raise warning 'job series %: generation failed: % (%)', v_id, sqlerrm, sqlstate;
    end;
  end loop;
  return v_total;
end
$$;

comment on function public.generate_series_jobs(timestamptz) is
  'service_role (daily cron detail-crm-generate-series): extends every active series to its horizon and returns the number of jobs created. A series that cannot be generated is skipped with a WARNING. Series of a lapsed shop (shop_can_write false, billing 0102) are skipped until it pays again (0119).';

-- ===========================================================================
-- 2. marketing email: postal address
-- ===========================================================================
create function public.comms_shop_postal_address(p_shop_id uuid) returns text
language sql stable security definer
set search_path = ''
as $$
  select case
    when nullif(btrim(s.address_line1), '') is null or nullif(btrim(s.city), '') is null then null
    else concat_ws(', ',
                   btrim(s.address_line1),
                   nullif(btrim(s.address_line2), ''),
                   btrim(s.city),
                   nullif(concat_ws(' ', nullif(btrim(s.region), ''), nullif(btrim(s.postal_code), '')), ''),
                   case when s.country <> 'US' then s.country end)
  end
  from public.shops s
  where s.id = p_shop_id
$$;

comment on function public.comms_shop_postal_address(uuid) is
  'Internal (0119): the shop''s postal address on one line ("line1, line2, city, region postal_code[, country]"; the country only outside the US), or null when the shop has no street line or city on file. Every marketing email ends with it (CAN-SPAM).';
revoke execute on function public.comms_shop_postal_address(uuid) from public, anon, authenticated;
grant execute on function public.comms_shop_postal_address(uuid) to service_role;

create function public.comms_email_with_postal_address(p_body text, p_shop_name text, p_address text) returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p_body is null or nullif(btrim(p_address), '') is null then p_body
    when strpos(left(p_body, 50000), p_address) > 0 then left(p_body, 50000)
    else left(p_body, 50000 - char_length(E'\n\n' || concat_ws(' · ', nullif(btrim(p_shop_name), ''), p_address)))
         || E'\n\n' || concat_ws(' · ', nullif(btrim(p_shop_name), ''), p_address)
  end
$$;

comment on function public.comms_email_with_postal_address(text, text, text) is
  'Internal (0119): a marketing email body (max 50000 characters) ended with "<shop name> · <postal address>" — cut to make room — unless the wording already shows the address. Unchanged when the body or address is null.';
revoke execute on function public.comms_email_with_postal_address(text, text, text) from public, anon, authenticated;
grant execute on function public.comms_email_with_postal_address(text, text, text) to service_role;

create function public.messages_marketing_postal_address() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  c_missing  constant text :=
    'add your shop''s mailing address (Settings → Business profile) before sending marketing email: '
    'the law requires it in every marketing email';
  v_name     text;
  v_address  text;
begin
  select s.name into v_name from public.shops s where s.id = new.shop_id;
  v_address := public.comms_shop_postal_address(new.shop_id);
  if v_address is not null then
    new.body := public.comms_email_with_postal_address(new.body, v_name, v_address);
    return new;
  end if;
  if new.campaign_id is not null then
    raise exception '%', c_missing using errcode = '55000', hint = 'postal_address_required';
  end if;
  -- never sent without one (as without a working unsubscribe link): the
  -- queueing code gets no row, i.e. nothing was queued
  return null;
end
$$;

comment on function public.messages_marketing_postal_address() is
  'Internal (0119): a marketing email (outbound email with an unsubscribe_token) ends with the shop''s postal address; without an address on file a campaign message fails (55000 HINT postal_address_required: the launch is refused) and any other marketing email is not inserted (never sent; the queueing code returns null).';
revoke execute on function public.messages_marketing_postal_address() from public, anon, authenticated;

create trigger messages_02_marketing_postal_address before insert on public.messages
  for each row
  when (new.direction = 'outbound' and new.channel = 'email' and new.unsubscribe_token is not null)
  execute function public.messages_marketing_postal_address();
