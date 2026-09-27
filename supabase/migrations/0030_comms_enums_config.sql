-- ============================================================================
-- 0030 — Communication (SPEC §4.7): enums for the whole comms range,
-- platform_config (deploy-wide settings such as app_base_url), and the pure
-- formatting / link helpers used when rendering customer messages.
--
-- Range layout:
--   0030  enums, platform_config, formatting + link helpers
--   0031  notifications + notify_shop_staff
--   0032  message_templates (+ per-shop defaults), render_template
--   0033  messages (queue + history), customer opt-outs, template variables,
--         queue_message / enqueue_* / sender (claim, result, callbacks),
--         inbound SMS
--   0034  automations: job_automation_log + enqueue_due_automations
--   0035  campaigns + campaign_recipients, launch/cancel, email unsubscribe
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.message_channel   as enum ('sms', 'email');
create type public.message_direction as enum ('outbound', 'inbound');
-- 'cancelled' (beyond SPEC §4.7's list): queued messages withdrawn before
-- sending (cancelled campaigns, recipients who opted out after queueing).
create type public.message_status    as enum ('queued', 'sending', 'sent', 'delivered', 'failed', 'received',
                                              'cancelled');
create type public.message_template_key as enum (
  'booking_request_received', 'booking_confirmed', 'appointment_reminder', 'on_the_way', 'job_started',
  'job_completed', 'quote_sent', 'invoice_sent', 'payment_receipt', 'review_request', 'follow_up',
  'membership_welcome', 'invite');
create type public.campaign_status   as enum ('draft', 'launched', 'cancelled');
create type public.notification_kind as enum (
  'new_booking', 'booking_cancelled', 'quote_approved', 'quote_declined', 'payment_received',
  'inbound_message', 'form_signed', 'general');

-- ---------------------------------------------------------------------------
-- platform_config — deploy-wide settings (not per shop). Written by
-- service_role / postgres (setup scripts); never readable by API clients.
-- Known keys:
--   app_base_url  public web origin used for customer links, e.g.
--                 https://app.example.com (no trailing slash needed).
--                 REQUIRED: supabase/setup/cron.sql writes it through
--                 set_app_base_url; it must equal the APP_BASE_URL secret.
-- ---------------------------------------------------------------------------
create table public.platform_config (
  key         text primary key check (key ~ '^[a-z][a-z0-9_]{0,62}$'),
  value       text not null check (char_length(value) <= 2000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint platform_config_app_base_url check (key <> 'app_base_url' or value ~ '^https?://[^[:space:]/]+(/[^[:space:]]*)?$')
);

create trigger platform_config_90_set_updated_at before update on public.platform_config
  for each row execute function public.set_updated_at();

alter table public.platform_config enable row level security;
-- No policies: only service_role (BYPASSRLS) and definer code touch it.
revoke all on public.platform_config from anon, authenticated;

-- Value of a platform setting (null when unset). Internal: called from
-- SECURITY DEFINER comms functions (which run as the owner).
create function public.platform_setting(p_key text) returns text
language sql stable
set search_path = ''
as $$ select c.value from public.platform_config c where c.key = p_key $$;

-- Absolute customer-facing URL for an app path (path must start with '/'),
-- or null when app_base_url is not configured.
create function public.app_url(p_path text) returns text
language sql stable
set search_path = ''
as $$
  select case when b.base is null or p_path is null then null
              else b.base || p_path end
  from (select nullif(rtrim(public.platform_setting('app_base_url'), '/'), '') as base) b
$$;

-- Stores app_base_url (service_role / postgres). Part of the documented,
-- idempotent deploy setup (supabase/setup/cron.sql calls it with the same
-- origin as the APP_BASE_URL function secret). Without it no customer link
-- can be built, so link-bearing templates are not queued (0033), due
-- automations refuse to run (0034) and campaigns with links cannot launch
-- (0035). Trailing slashes are dropped; returns the stored value.
create function public.set_app_base_url(p_url text) returns text
language plpgsql
set search_path = ''
as $$
declare
  v_url text := rtrim(btrim(coalesce(p_url, '')), '/');
begin
  if v_url !~ '^https?://[^[:space:]/?#]+(/[^[:space:]?#]*)?$' then
    raise exception 'app_base_url must be the web app origin, e.g. https://app.example.com (got "%")', p_url
      using errcode = '22023';
  end if;
  insert into public.platform_config (key, value) values ('app_base_url', v_url)
  on conflict (key) do update set value = excluded.value
    where public.platform_config.value is distinct from excluded.value;
  return v_url;
end
$$;

-- True when a template text uses a placeholder whose value is an app link
-- (built with app_url: booking / booking page / quote / invoice /
-- unsubscribe links). Such a message is never queued while app_base_url is
-- unset: it would go out with a blank link.
create function public.comms_uses_app_links(p_text text) returns boolean
language sql immutable
set search_path = ''
as $$
  select coalesce(p_text ~ '\{\{[ \t]*(booking_link|booking_page_link|quote_link|invoice_link|unsubscribe_link)[ \t]*\}\}',
                  false)
$$;

-- ---------------------------------------------------------------------------
-- Formatting helpers (pure)
-- ---------------------------------------------------------------------------

-- Integer cents → display string in the shop currency, e.g. 123456 usd →
-- "$1,234.56", -500 → "-$5.00". Zero-decimal currencies (jpy, krw …) have no
-- minor unit: their amounts are whole units. Unknown symbols use the upper
-- ISO code: "CHF 12.00".
create function public.format_money(p_cents bigint, p_currency text default 'usd') returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_cur    text := lower(coalesce(p_currency, 'usd'));
  v_zero   boolean := v_cur = any (array['bif', 'clp', 'djf', 'gnf', 'jpy', 'kmf', 'krw', 'mga', 'pyg', 'rwf',
                                         'ugx', 'vnd', 'vuv', 'xaf', 'xof', 'xpf']);
  v_symbol text;
  v_num    text;
begin
  if p_cents is null then
    return null;
  end if;
  v_symbol := case v_cur
    when 'usd' then '$' when 'cad' then '$' when 'aud' then '$' when 'nzd' then '$'
    when 'eur' then '€' when 'gbp' then '£' when 'jpy' then '¥'
    else upper(v_cur) || ' '
  end;
  if v_zero then
    v_num := to_char(abs(p_cents), 'FM999,999,999,999,999,990');
  else
    v_num := to_char(abs(p_cents)::numeric / 100, 'FM999,999,999,999,999,990.00');
  end if;
  return case when p_cents < 0 then '-' else '' end || v_symbol || v_num;
end
$$;

-- E.164 → friendly display: NANP numbers "+12055550101" → "(205) 555-0101";
-- anything else is returned unchanged.
create function public.format_phone(p_e164 text) returns text
language sql immutable
set search_path = ''
as $$
  select case
    when p_e164 ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'
      then '(' || substr(p_e164, 3, 3) || ') ' || substr(p_e164, 6, 3) || '-' || substr(p_e164, 9, 4)
    else p_e164
  end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.platform_setting(text), public.app_url(text) from public, anon, authenticated;
grant execute on function public.platform_setting(text), public.app_url(text) to service_role;

revoke execute on function public.set_app_base_url(text) from public, anon, authenticated;
grant execute on function public.set_app_base_url(text) to service_role;

revoke execute on function public.format_money(bigint, text), public.format_phone(text),
                           public.comms_uses_app_links(text) from public, anon;
grant execute on function public.format_money(bigint, text), public.format_phone(text),
                          public.comms_uses_app_links(text) to authenticated, service_role;
