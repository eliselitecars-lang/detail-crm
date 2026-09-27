-- ============================================================================
-- 0035 — Campaigns (SPEC §4.7): marketing blasts to opted-in customers,
-- filtered by an audience, materialized into campaign_recipients + queued
-- messages exactly once (launch_campaign). Plus public_unsubscribe, the
-- email unsubscribe endpoint every campaign email links to.
--
-- Audience (campaigns.audience jsonb; every key optional, all combined with AND):
--   tags               ["vip", "fleet"]   customer has ANY of these tags (case-insensitive)
--   lifecycle          "lead" | "customer"
--   last_visit_before  "YYYY-MM-DD"      last completed job strictly before that date
--   last_visit_after   "YYYY-MM-DD"      last completed job on or after that date
-- Dates are local dates in the shop time zone; the last visit is the latest
-- completed job (completed_at, else scheduled_start). Customers with no
-- completed job never match a last_visit filter.
-- Recipients are active (non-archived) customers who opted in to the channel
-- (sms_opt_in / email_opt_in) and have not opted out; one message per
-- distinct address (the most recently created customer wins). Opt-outs are
-- per address: an address in comms_suppressions, or that ANY customer of
-- the shop (archived included) opted out with, is never a recipient, even
-- through a duplicate customer record.
-- Consent is re-checked when each message is sent (claim_queued_messages):
-- an opt-out, a withdrawn opt-in or a cancelled campaign stops messages that
-- are still queued, including retries of in-flight ones.
-- Compliance footers are appended automatically: SMS bodies without an
-- opt-out instruction ("Reply STOP", "Text STOP" …; merely using the word
-- "stop" does not count) get "Reply STOP to opt out." (comms_sms_with_optout,
-- 0033); emails get an unsubscribe link unless the body already places
-- {{unsubscribe_link}} (comms_email_with_unsubscribe, 0033). Each email's
-- link carries its own random unsubscribe_token (never the message id).
-- Emails of the promotional follow_up template get the same treatment
-- (enqueue_customer_template, 0033).
-- A campaign that was launched is the record of what was sent and keeps its
-- messages linked (their consent / cancellation checks depend on it): it
-- can be cancelled but never deleted. Only never-launched campaigns (drafts,
-- cancelled drafts) can be deleted.
-- launch_campaign stamps launched_at and the send time with the server
-- clock for API callers (effective_now). It refuses (55000) while
-- platform_config has no app_base_url when an email campaign needs its
-- unsubscribe links or an SMS campaign's wording uses a customer link
-- ({{booking_page_link}} …): those would go out blank. For the same reason
-- it refuses (55000) wording that uses a link that is not available to a
-- campaign (comms_unavailable_links): {{booking_page_link}} while the shop's
-- online booking is off, {{review_link}} without a review URL, and the
-- job links ({{booking_link}}, {{quote_link}}, {{invoice_link}}), which a
-- campaign never has.
-- ============================================================================

-- Pure validator used by the CHECK constraint and the RPCs.
create function public.campaign_audience_valid(p_audience jsonb) returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  v_key text;
  v_val jsonb;
  v_d   date;
begin
  if p_audience is null or jsonb_typeof(p_audience) <> 'object' then
    return false;
  end if;
  for v_key, v_val in select e.key, e.value from jsonb_each(p_audience) e loop
    case v_key
      when 'tags' then
        if jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) > 50
           or exists (select 1 from jsonb_array_elements(v_val) t
                      where jsonb_typeof(t) <> 'string' or char_length(btrim(t #>> '{}')) not between 1 and 100) then
          return false;
        end if;
      when 'lifecycle' then
        if jsonb_typeof(v_val) <> 'string' or (v_val #>> '{}') not in ('lead', 'customer') then
          return false;
        end if;
      when 'last_visit_before', 'last_visit_after' then
        if jsonb_typeof(v_val) <> 'string' or (v_val #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
          return false;
        end if;
        begin
          v_d := (v_val #>> '{}')::date;
        exception when others then
          return false;
        end;
      else
        return false;
    end case;
  end loop;
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- campaigns
-- ---------------------------------------------------------------------------
create table public.campaigns (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops (id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 1 and 200),
  channel          public.message_channel not null,
  subject          text,
  body             text not null,
  audience         jsonb not null default '{}'::jsonb check (public.campaign_audience_valid(audience)),
  status           public.campaign_status not null default 'draft',
  scheduled_at     timestamptz,
  launched_at      timestamptz,
  launched_by      uuid references auth.users (id) on delete set null,
  cancelled_at     timestamptz,
  recipient_count  integer not null default 0 check (recipient_count >= 0),
  created_by       uuid references auth.users (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint campaigns_shop_id_id_key unique (shop_id, id),
  constraint campaigns_body check (
    char_length(btrim(body)) >= 1
    and char_length(body) <= case channel when 'sms' then 1600 else 50000 end),
  constraint campaigns_subject check (
    case channel when 'sms' then subject is null
                 else subject is null or char_length(btrim(subject)) between 1 and 200 end),
  constraint campaigns_draft_stamps check (status <> 'draft' or (launched_at is null and cancelled_at is null)),
  constraint campaigns_launched_stamp check (status <> 'launched' or launched_at is not null),
  constraint campaigns_cancel_stamp check ((status = 'cancelled') = (cancelled_at is not null))
);
create index campaigns_shop_status_idx on public.campaigns (shop_id, status, created_at desc);
create index campaigns_launched_by_idx on public.campaigns (launched_by);
create index campaigns_created_by_idx on public.campaigns (created_by);

-- Direct writes: drafts only. Launch / cancel happen through the RPCs.
create function public.campaigns_client_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not public.is_client_context() then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    if old.status = 'launched' then
      raise exception 'a launched campaign cannot be deleted; cancel it instead' using errcode = '42501';
    end if;
    if old.launched_at is not null then
      raise exception 'a campaign that was launched is kept as the record of what was sent; it cannot be deleted'
        using errcode = '42501';
    end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.launched_at := null;
    new.launched_by := null;
    new.cancelled_at := null;
    new.recipient_count := 0;
    new.created_by := auth.uid();
    return new;
  end if;
  if old.status <> 'draft' then
    raise exception 'only draft campaigns can be edited' using errcode = '42501';
  end if;
  if new.status <> old.status or new.launched_at is distinct from old.launched_at
     or new.launched_by is distinct from old.launched_by or new.cancelled_at is distinct from old.cancelled_at
     or new.recipient_count <> old.recipient_count then
    raise exception 'use launch_campaign / cancel_campaign to change a campaign''s status' using errcode = '42501';
  end if;
  new.created_by := old.created_by;
  return new;
end
$$;

create function public.campaigns_normalize() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  new.subject := nullif(btrim(new.subject), '');
  new.body := btrim(new.body, E' \t\r\n');
  return new;
end
$$;

create trigger campaigns_05_prevent_shop_change before update on public.campaigns
  for each row execute function public.prevent_shop_change();
create trigger campaigns_10_client_guard before insert or update or delete on public.campaigns
  for each row execute function public.campaigns_client_guard();
create trigger campaigns_20_normalize before insert or update on public.campaigns
  for each row execute function public.campaigns_normalize();
create trigger campaigns_90_set_updated_at before update on public.campaigns
  for each row execute function public.set_updated_at();

-- messages.campaign_id (declared in 0033) gets its composite FK. NO ACTION:
-- a campaign with messages cannot be deleted (unlinking them would turn a
-- cancelled campaign's in-flight message, or one to a customer who withdrew
-- marketing consent, into an ordinary message that a retry re-sends);
-- deleting the whole shop still works (both sides go in one statement).
alter table public.messages
  add constraint messages_campaign_fk foreign key (shop_id, campaign_id)
    references public.campaigns (shop_id, id);

-- ---------------------------------------------------------------------------
-- campaign_recipients — materialized once at launch.
-- ---------------------------------------------------------------------------
create table public.campaign_recipients (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  campaign_id  uuid not null,
  customer_id  uuid not null,
  message_id   uuid,
  to_address   text not null check (char_length(to_address) <= 320),
  created_at   timestamptz not null default now(),
  constraint campaign_recipients_shop_id_id_key unique (shop_id, id),
  constraint campaign_recipients_once unique (campaign_id, customer_id),
  constraint campaign_recipients_campaign_fk foreign key (shop_id, campaign_id)
    references public.campaigns (shop_id, id) on delete cascade,
  constraint campaign_recipients_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint campaign_recipients_message_fk foreign key (shop_id, message_id)
    references public.messages (shop_id, id) on delete set null (message_id)
);
create index campaign_recipients_shop_campaign_idx on public.campaign_recipients (shop_id, campaign_id);
create index campaign_recipients_shop_customer_idx on public.campaign_recipients (shop_id, customer_id);
create index campaign_recipients_shop_message_idx on public.campaign_recipients (shop_id, message_id);

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.campaigns           enable row level security;
alter table public.campaign_recipients enable row level security;

create policy campaigns_select on public.campaigns for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy campaigns_insert on public.campaigns for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy campaigns_update on public.campaigns for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy campaigns_delete on public.campaigns for delete to authenticated
  using (public.is_shop_manager(shop_id));

create policy campaign_recipients_select on public.campaign_recipients for select to authenticated
  using (public.is_shop_manager(shop_id));

revoke all on public.campaigns, public.campaign_recipients from anon;
revoke truncate, references, trigger on public.campaigns from authenticated;
revoke insert, update, delete, truncate, references, trigger on public.campaign_recipients from authenticated;

-- ---------------------------------------------------------------------------
-- Audience resolution (internal; runs inside the definer RPCs below).
-- ---------------------------------------------------------------------------
create function public.campaign_audience_customers(
  p_shop_id   uuid,
  p_channel   public.message_channel,
  p_audience  jsonb
) returns table (customer_id uuid, to_address text)
language sql stable
set search_path = ''
as $$
  with shop as (
    select s.id, s.timezone from public.shops s where s.id = p_shop_id
  ), f as (
    select case when p_audience ? 'tags'
                then (select array_agg(lower(btrim(t))) from jsonb_array_elements_text(p_audience -> 'tags') t)
           end as tags,
           p_audience ->> 'lifecycle' as lifecycle,
           ((p_audience ->> 'last_visit_before')::date)::timestamp at time zone (select timezone from shop) as before_ts,
           ((p_audience ->> 'last_visit_after')::date)::timestamp at time zone (select timezone from shop) as after_ts
  ), opted_out as (
    -- addresses that must never get marketing: suppressed, or opted out on
    -- any customer record of the shop
    select s.address from public.comms_suppressions s
     where s.shop_id = p_shop_id and s.channel = p_channel
    union
    select public.comms_address_key(p_channel, case p_channel when 'sms' then c.phone else c.email::text end)
      from public.customers c
     where c.shop_id = p_shop_id
       and case p_channel when 'sms' then c.phone is not null and c.sms_opted_out_at is not null
                          else c.email is not null and c.email_opted_out_at is not null end
  ), candidates as (
    select c.id, c.created_at,
           case p_channel when 'sms' then c.phone else c.email::text end as addr
      from public.customers c, f
     where c.shop_id = p_shop_id
       and c.archived_at is null
       and case p_channel
             when 'sms' then c.phone is not null and c.sms_opt_in and c.sms_opted_out_at is null
             else c.email is not null and c.email_opt_in and c.email_opted_out_at is null
           end
       and public.comms_address_key(p_channel, case p_channel when 'sms' then c.phone else c.email::text end)
             not in (select o.address from opted_out o where o.address is not null)
       and (f.tags is null or cardinality(f.tags) = 0
            or exists (select 1 from unnest(c.tags) ct where lower(btrim(ct)) = any (f.tags)))
       and (f.lifecycle is null or c.lifecycle::text = f.lifecycle)
       and (f.before_ts is null and f.after_ts is null
            or exists (
              select 1
                from (select max(coalesce(j.completed_at, j.scheduled_start)) as last_visit
                        from public.jobs j
                       where j.shop_id = c.shop_id and j.customer_id = c.id and j.status = 'completed') lv
               where lv.last_visit is not null
                 and (f.before_ts is null or lv.last_visit < f.before_ts)
                 and (f.after_ts is null or lv.last_visit >= f.after_ts)))
  )
  select distinct on (public.comms_address_key(p_channel, addr)) id, addr
    from candidates
   order by public.comms_address_key(p_channel, addr), created_at desc, id
$$;

-- Number of customers a campaign audience would reach (manager+).
create function public.preview_campaign_audience(
  p_shop_id   uuid,
  p_channel   public.message_channel,
  p_audience  jsonb default '{}'::jsonb
) returns integer
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can run campaigns' using errcode = '42501';
  end if;
  if p_channel is null or not public.campaign_audience_valid(coalesce(p_audience, '{}'::jsonb)) then
    raise exception 'invalid audience filter' using errcode = '22023';
  end if;
  return (select count(*)::integer
            from public.campaign_audience_customers(p_shop_id, p_channel, coalesce(p_audience, '{}'::jsonb)));
end
$$;

-- ---------------------------------------------------------------------------
-- launch_campaign (manager+). Materializes recipients and queues one message
-- each, exactly once: the campaign row is locked and must still be a draft.
-- Messages are sent at scheduled_at (or now when unset / in the past).
-- "now" is the server clock for API callers; p_now is honoured only for
-- trusted callers (tests, direct sessions) per effective_now.
-- ---------------------------------------------------------------------------
create function public.launch_campaign(p_campaign_id uuid, p_now timestamptz default now())
returns public.campaigns
language plpgsql security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v_c        public.campaigns;
  v_shop     public.shops;
  v_body     text;
  v_send     timestamptz;
  v_r        record;
  v_vars     jsonb;
  v_msg_id   uuid;
  v_token    uuid;
  v_unsub    text;
  v_text     text;
  v_missing  text[];
  v_count    integer := 0;
begin
  select * into v_c from public.campaigns c where c.id = p_campaign_id for update;
  if not found or not public.is_shop_member(v_c.shop_id) then
    raise exception 'campaign not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_c.shop_id) then
    raise exception 'only owners, admins and managers can launch campaigns' using errcode = '42501';
  end if;
  if v_c.status <> 'draft' then
    raise exception 'this campaign was already %', v_c.status using errcode = '55000';
  end if;
  select * into v_shop from public.shops s where s.id = v_c.shop_id;

  v_body := v_c.body;
  if v_c.channel = 'sms' then
    if v_shop.sms_from_number is null then
      raise exception 'text messaging is not set up for this shop' using errcode = '55000';
    end if;
    if public.comms_uses_app_links(v_body) and public.app_url('/') is null then
      raise exception 'customer links are not set up on this platform yet, so this campaign cannot be sent'
        using errcode = '55000', hint = 'The platform operator must set app_base_url (supabase/setup/cron.sql).';
    end if;
  else
    if v_c.subject is null then
      raise exception 'an email campaign needs a subject' using errcode = '22023';
    end if;
    if public.app_url('/') is null then
      raise exception 'email campaigns need the app URL configured for unsubscribe links' using errcode = '55000';
    end if;
  end if;
  -- every link the wording uses must be available (the shop-level links are
  -- the same for every recipient)
  v_missing := public.comms_unavailable_links(
                 v_body || case when v_c.channel = 'email' then E'\n' || coalesce(v_c.subject, '') else '' end,
                 public.comms_customer_vars(v_c.shop_id, null));
  if cardinality(v_missing) > 0 then
    raise exception 'this campaign uses a link that is not available: %',
      (select string_agg('{{' || x || '}}', ', ' order by x) from unnest(v_missing) x)
      using errcode = '55000',
            hint = '{{booking_page_link}} needs online booking turned on, {{review_link}} needs the shop''s review link, '
                   'and job links ({{booking_link}}, {{quote_link}}, {{invoice_link}}) cannot be used in campaigns.';
  end if;
  v_send := greatest(coalesce(v_c.scheduled_at, v_now), v_now);

  for v_r in
    select a.customer_id, a.to_address
      from public.campaign_audience_customers(v_c.shop_id, v_c.channel, v_c.audience) a
     order by a.to_address
  loop
    v_msg_id := gen_random_uuid();
    v_token := case when v_c.channel = 'email' then gen_random_uuid() end;
    v_unsub := case when v_token is not null then public.app_url('/u/' || v_token::text) end;
    v_vars := public.comms_customer_vars(v_c.shop_id, v_r.customer_id)
              || case when v_unsub is not null then jsonb_build_object('unsubscribe_link', v_unsub)
                      else '{}'::jsonb end;
    v_text := nullif(btrim(public.render_template(v_body, v_vars), E' \t\r\n'), '');
    continue when v_text is null;
    if v_c.channel = 'sms' then
      v_text := public.comms_sms_with_optout(v_text);
    else
      v_text := public.comms_email_with_unsubscribe(v_text, v_unsub);
    end if;

    insert into public.messages (id, shop_id, customer_id, campaign_id, direction, channel, to_address,
                                 subject, body, status, send_after, sent_by, unsubscribe_token)
    values (v_msg_id, v_c.shop_id, v_r.customer_id, v_c.id, 'outbound', v_c.channel, v_r.to_address,
            case when v_c.channel = 'email'
                 then coalesce(left(nullif(btrim(public.render_template(v_c.subject, v_vars)), ''), 500), v_shop.name) end,
            v_text, 'queued', v_send, auth.uid(), v_token);
    insert into public.campaign_recipients (shop_id, campaign_id, customer_id, message_id, to_address)
    values (v_c.shop_id, v_c.id, v_r.customer_id, v_msg_id, v_r.to_address);
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'no opted-in customers match this campaign''s audience' using errcode = '22023';
  end if;

  update public.campaigns c
     set status = 'launched', launched_at = v_now, launched_by = auth.uid(), recipient_count = v_count
   where c.id = v_c.id
  returning * into v_c;
  return v_c;
end
$$;

-- cancel_campaign (manager+): a draft is cancelled outright; a launched
-- campaign has its not-yet-sent messages withdrawn (already sent ones stay).
-- A message in flight at that moment is sent at most once: if the provider
-- asks for a retry, mark_message_result cancels it instead of re-queueing
-- (and the claim never hands out a cancelled campaign's messages).
create function public.cancel_campaign(p_campaign_id uuid) returns public.campaigns
language plpgsql security definer
set search_path = ''
as $$
declare
  v_c public.campaigns;
begin
  select * into v_c from public.campaigns c where c.id = p_campaign_id for update;
  if not found or not public.is_shop_member(v_c.shop_id) then
    raise exception 'campaign not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_c.shop_id) then
    raise exception 'only owners, admins and managers can cancel campaigns' using errcode = '42501';
  end if;
  if v_c.status = 'cancelled' then
    raise exception 'this campaign is already cancelled' using errcode = '55000';
  end if;
  update public.messages m
     set status = 'cancelled', error = 'the campaign was cancelled'
   where m.shop_id = v_c.shop_id and m.campaign_id = v_c.id and m.status = 'queued';
  update public.campaigns c
     set status = 'cancelled', cancelled_at = now()
   where c.id = v_c.id
  returning * into v_c;
  return v_c;
end
$$;

-- ---------------------------------------------------------------------------
-- public_unsubscribe (anyone holding an email's unsubscribe link: /u/<token>,
-- token = that marketing email's messages.unsubscribe_token — random, set
-- only on campaign emails and marketing template emails, and never the
-- message id, which staff RPCs such as enqueue_template_message return to
-- technicians). The token is resolved through comms_unsubscribe_tokens
-- (0033), which outlives the message, so the link keeps working after its
-- customer (and the message with them) was deleted. Records the email
-- opt-out of the ADDRESS the email went to (comms_suppress: every customer
-- of the shop with it, now or later, and queued email to it withdrawn) and,
-- while the message exists, of its customer. Returns true when the link was
-- valid.
-- ---------------------------------------------------------------------------
create function public.public_unsubscribe(p_token uuid) returns boolean
language plpgsql security definer
set search_path = ''
as $$
declare
  v_tok public.comms_unsubscribe_tokens;
begin
  if p_token is null then
    return false;
  end if;
  select * into v_tok from public.comms_unsubscribe_tokens t where t.token = p_token;
  if not found then
    return false;
  end if;
  perform public.comms_suppress(v_tok.shop_id, 'email', v_tok.address, now());
  update public.customers c
     set email_opted_out_at = coalesce(c.email_opted_out_at, now()), email_opt_in = false
    from public.messages m
   where m.id = v_tok.message_id and m.shop_id = v_tok.shop_id
     and c.id = m.customer_id and c.shop_id = m.shop_id
     and (c.email_opted_out_at is null or c.email_opt_in);
  return true;
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.campaigns_client_guard(), public.campaigns_normalize()
  from public, anon, authenticated;

revoke execute on function public.campaign_audience_customers(uuid, public.message_channel, jsonb)
  from public, anon, authenticated;
grant execute on function public.campaign_audience_customers(uuid, public.message_channel, jsonb) to service_role;

revoke execute on function
  public.campaign_audience_valid(jsonb),
  public.preview_campaign_audience(uuid, public.message_channel, jsonb),
  public.launch_campaign(uuid, timestamptz),
  public.cancel_campaign(uuid)
from public, anon;
grant execute on function
  public.campaign_audience_valid(jsonb),
  public.preview_campaign_audience(uuid, public.message_channel, jsonb),
  public.launch_campaign(uuid, timestamptz),
  public.cancel_campaign(uuid)
to authenticated, service_role;

revoke execute on function public.public_unsubscribe(uuid) from public;
grant execute on function public.public_unsubscribe(uuid) to anon, authenticated, service_role;
