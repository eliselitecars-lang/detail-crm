-- ============================================================================
-- 0090 — Cross-surface comms (integration phase).
--
--   comms_document_vars        template variables of a quote / invoice
--                              (internal: service_role and definer code)
--   enqueue_document_message   staff send of quote_sent / invoice_sent,
--                              rendered on the server (manager+)
--   preview_document_message   what that send will say (manager+)
--   public_unsubscribe_info    shop name / logo / state for the /u/<token>
--                              page (anon)
--   inbox_threads              latest message per conversation + unread
--   inbox_unread_count         counts for the staff inbox (manager+)
--   preview_campaign_message   rendered campaign text and its length limit
--                              exactly as launch_campaign will send it
--                              (manager+)
--
-- Documents: a quote's job is its converted_job_id, an invoice's its job_id;
-- the job's variables are used only while that job belongs to the
-- document's customer (otherwise the customer-level variables). The
-- document then supplies its own link, amount and balance:
--   quote    quote_link   = /q/<token> once the quote is no longer a draft
--            amount       = the quote total, balance = null (a quote owes nothing)
--   invoice  invoice_link = /i/<token> once issued (not draft, not void)
--            amount       = the invoice total,
--            balance      = the balance due (never negative)
-- A draft quote or a draft / void invoice therefore has no link, and the
-- send queues nothing (comms_key_required_link).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- comms_document_vars — INTERNAL (no caller checks). Exactly one of the two
-- ids must be given (22023). Unknown document: P0002.
-- ---------------------------------------------------------------------------
create function public.comms_document_vars(
  p_quote_id    uuid default null,
  p_invoice_id  uuid default null
) returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_shop_id   uuid;
  v_customer  uuid;
  v_job       uuid;
  v_status    text;
  v_token     uuid;
  v_total     bigint;
  v_balance   bigint;
  v_currency  text;
  v_vars      jsonb;
begin
  if (p_quote_id is null) = (p_invoice_id is null) then
    raise exception 'give exactly one of a quote or an invoice' using errcode = '22023';
  end if;
  if p_quote_id is not null then
    select q.shop_id, q.customer_id, q.converted_job_id, q.status::text, q.public_token, q.total_cents
      into v_shop_id, v_customer, v_job, v_status, v_token, v_total
      from public.quotes q where q.id = p_quote_id;
    if not found then
      raise exception 'quote not found' using errcode = 'P0002';
    end if;
  else
    select i.shop_id, i.customer_id, i.job_id, i.status::text, i.public_token, i.total_cents, i.balance_cents
      into v_shop_id, v_customer, v_job, v_status, v_token, v_total, v_balance
      from public.invoices i where i.id = p_invoice_id;
    if not found then
      raise exception 'invoice not found' using errcode = 'P0002';
    end if;
  end if;
  select s.currency into v_currency from public.shops s where s.id = v_shop_id;

  if v_job is not null and exists (select 1 from public.jobs j
                                    where j.id = v_job and j.shop_id = v_shop_id and j.customer_id = v_customer) then
    v_vars := public.comms_job_vars(v_job);
  else
    v_vars := public.comms_customer_vars(v_shop_id, v_customer);
  end if;

  if p_quote_id is not null then
    return v_vars || jsonb_build_object(
      'quote_link', case when v_status <> 'draft' then public.app_url('/q/' || v_token::text) end,
      'amount', public.format_money(v_total, v_currency),
      'balance', null);
  end if;
  return v_vars || jsonb_build_object(
    'invoice_link', case when v_status not in ('draft', 'void') then public.app_url('/i/' || v_token::text) end,
    'amount', public.format_money(v_total, v_currency),
    'balance', public.format_money(greatest(v_balance, 0), v_currency));
end
$$;

comment on function public.comms_document_vars(uuid, uuid) is
  'Internal: template variables of one quote or invoice (job or customer variables plus the document link, amount and balance).';

-- The document's shop / customer / job (job only while it belongs to the
-- document's customer). Not found: P0002. Internal.
create function public.comms_document_target(
  p_quote_id    uuid,
  p_invoice_id  uuid,
  out shop_id      uuid,
  out customer_id  uuid,
  out job_id       uuid,
  out key          public.message_template_key
)
language plpgsql stable
set search_path = ''
as $$
#variable_conflict use_variable
begin
  if (p_quote_id is null) = (p_invoice_id is null) then
    raise exception 'give exactly one of a quote or an invoice' using errcode = '22023';
  end if;
  if p_quote_id is not null then
    select q.shop_id, q.customer_id, q.converted_job_id into shop_id, customer_id, job_id
      from public.quotes q where q.id = p_quote_id;
    if not found then
      raise exception 'quote not found' using errcode = 'P0002';
    end if;
    key := 'quote_sent';
  else
    select i.shop_id, i.customer_id, i.job_id into shop_id, customer_id, job_id
      from public.invoices i where i.id = p_invoice_id;
    if not found then
      raise exception 'invoice not found' using errcode = 'P0002';
    end if;
    key := 'invoice_sent';
  end if;
  if job_id is not null and not exists (select 1 from public.jobs j
                                         where j.id = job_id and j.shop_id = shop_id and j.customer_id = customer_id) then
    job_id := null;
  end if;
end
$$;

-- Staff access to a document: owner/admin/manager of its shop. Another
-- shop's (or an unknown) document is "not found" (P0002); a technician of
-- the shop gets 42501. Trusted callers without a user (service_role) pass.
create function public.comms_document_check_access(p_shop_id uuid, p_what text) returns void
language plpgsql stable
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return;
  end if;
  if not public.is_shop_member(p_shop_id) then
    raise exception '% not found', p_what using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can send quotes and invoices' using errcode = '42501';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- enqueue_document_message — staff "send quote / invoice" (quote_sent /
-- invoice_sent template, rendered and queued on the server). Returns the
-- message id, or null when nothing was queued (template off, no address,
-- opted out, no SMS number, or the document has no link yet: a draft quote,
-- a draft or void invoice). Raises 55000 when the wording needs customer
-- links and app_base_url is not configured. p_request_nonce as in 0033.
-- ---------------------------------------------------------------------------
create function public.enqueue_document_message(
  p_quote_id       uuid default null,
  p_invoice_id     uuid default null,
  p_channel        public.message_channel default 'sms',
  p_request_nonce  text default null
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_t public.message_template_key;
  v_shop uuid;
  v_customer uuid;
  v_job uuid;
begin
  if p_channel is null then
    raise exception 'choose sms or email' using errcode = '22023';
  end if;
  select t.shop_id, t.customer_id, t.job_id, t.key into v_shop, v_customer, v_job, v_t
    from public.comms_document_target(p_quote_id, p_invoice_id) t;
  perform public.comms_document_check_access(v_shop, case when p_quote_id is not null then 'quote' else 'invoice' end);
  if public.app_url('/') is null and exists (
       select 1 from public.message_templates t
        where t.shop_id = v_shop and t.key = v_t and t.channel = p_channel and t.enabled
          and (public.comms_uses_app_links(t.body)
               or (p_channel = 'email' and public.comms_uses_app_links(t.subject)))) then
    raise exception 'customer links are not set up on this platform yet, so this message cannot be sent'
      using errcode = '55000',
            hint = 'The platform operator must set app_base_url (supabase/setup/cron.sql).';
  end if;
  return public.enqueue_customer_template(v_shop, v_customer, v_t, p_channel, v_job,
                                          public.comms_document_vars(p_quote_id, p_invoice_id),
                                          null, auth.uid(), p_request_nonce);
end
$$;

-- ---------------------------------------------------------------------------
-- preview_document_message — what enqueue_document_message will send
-- (rendered like preview_template_message: lines with a missing optional
-- value are left out). The document link is always rendered from its token,
-- as it will read once the document is marked sent / issued. Missing
-- template: P0002.
-- ---------------------------------------------------------------------------
create function public.preview_document_message(
  p_quote_id    uuid default null,
  p_invoice_id  uuid default null,
  p_channel     public.message_channel default 'sms'
) returns table (enabled boolean, to_address text, subject text, body text)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_t        public.message_template_key;
  v_shop     uuid;
  v_customer uuid;
  v_job      uuid;
  v_tpl      public.message_templates;
  v_cust     public.customers;
  v_vars     jsonb;
  v_token    uuid;
begin
  if p_channel is null then
    raise exception 'choose sms or email' using errcode = '22023';
  end if;
  select t.shop_id, t.customer_id, t.job_id, t.key into v_shop, v_customer, v_job, v_t
    from public.comms_document_target(p_quote_id, p_invoice_id) t;
  perform public.comms_document_check_access(v_shop, case when p_quote_id is not null then 'quote' else 'invoice' end);
  select * into v_tpl from public.message_templates t
   where t.shop_id = v_shop and t.key = v_t and t.channel = p_channel;
  if not found then
    raise exception 'template not found' using errcode = 'P0002';
  end if;
  select * into v_cust from public.customers c where c.id = v_customer and c.shop_id = v_shop;
  v_vars := public.comms_document_vars(p_quote_id, p_invoice_id);
  if p_quote_id is not null then
    select q.public_token into v_token from public.quotes q where q.id = p_quote_id;
    v_vars := v_vars || jsonb_build_object('quote_link', public.app_url('/q/' || v_token::text));
  else
    select i.public_token into v_token from public.invoices i where i.id = p_invoice_id;
    v_vars := v_vars || jsonb_build_object('invoice_link', public.app_url('/i/' || v_token::text));
  end if;
  return query select v_tpl.enabled,
                      case p_channel when 'sms' then v_cust.phone else v_cust.email::text end,
                      case when p_channel = 'email'
                           then coalesce(left(nullif(btrim(public.render_template(
                                  public.comms_omit_unavailable_values(v_tpl.subject, v_vars, false), v_vars)), ''), 500),
                                  (select s.name from public.shops s where s.id = v_shop)) end,
                      btrim(public.render_template(public.comms_omit_unavailable_values(v_tpl.body, v_vars, false), v_vars),
                            E' \t\r\n');
end
$$;

comment on function public.preview_document_message(uuid, uuid, public.message_channel) is
  'What enqueue_document_message will send for a quote or invoice (manager+). @nullable: to_address, subject';

-- ---------------------------------------------------------------------------
-- public_unsubscribe_info — what the /u/<token> page shows before the
-- visitor confirms (public_unsubscribe does the opt-out). Curated keys only:
-- {shop_name, shop_logo_path, unsubscribed}; never the address, customer or
-- message. Unknown / null token: PT404 (HTTP 404; see 0042's header).
-- ---------------------------------------------------------------------------
create function public.public_unsubscribe_info(p_token uuid) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_tok public.comms_unsubscribe_tokens;
  v_shop public.shops;
begin
  if p_token is not null then
    select * into v_tok from public.comms_unsubscribe_tokens t where t.token = p_token;
  end if;
  if v_tok.token is null then
    raise exception 'unsubscribe link not found' using errcode = 'PT404';
  end if;
  select * into v_shop from public.shops s where s.id = v_tok.shop_id;
  if not found then
    raise exception 'unsubscribe link not found' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'shop_name', v_shop.name,
    'shop_logo_path', v_shop.logo_path,
    'unsubscribed', public.comms_is_suppressed(v_shop.id, 'email', v_tok.address));
end
$$;

-- ---------------------------------------------------------------------------
-- Inbox. A conversation (thread) is every message of one customer
-- ('c:<customer_id>'), or — for messages without a customer, e.g. a text
-- from an unknown number — of one address ('a:<address key>': the sender of
-- an inbound message, the recipient of an outbound one;
-- comms_address_key). inbox_threads returns each thread's newest message
-- (body cut to 280 characters) with the number of unread inbound messages,
-- newest thread first; keyset paging passes the last row's last_created_at
-- as p_before. Owner/admin/manager only (technicians: 42501).
-- ---------------------------------------------------------------------------
create index messages_unread_customer_idx on public.messages (shop_id, customer_id)
  where direction = 'inbound' and read_at is null;

create function public.inbox_threads(
  p_shop_id  uuid,
  p_limit    integer default 50,
  p_before   timestamptz default null
) returns table (
  thread_key           text,
  customer_id          uuid,
  from_address         text,
  customer_first_name  text,
  customer_last_name   text,
  customer_company     text,
  last_message_id      uuid,
  last_direction       public.message_direction,
  last_channel         public.message_channel,
  last_status          public.message_status,
  last_body            text,
  last_created_at      timestamptz,
  unread_count         integer
)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can read the inbox' using errcode = '42501';
  end if;
  return query
  with keyed as (
    select m.id, m.customer_id, m.direction, m.channel, m.status, m.body, m.created_at, m.read_at,
           case when m.direction = 'inbound' then m.from_address else m.to_address end as counterpart,
           case when m.customer_id is not null then 'c:' || m.customer_id::text
                else 'a:' || public.comms_address_key(m.channel,
                               case when m.direction = 'inbound' then m.from_address else m.to_address end)
           end as tk
      from public.messages m
     where m.shop_id = p_shop_id
  ), latest as (
    select distinct on (k.tk) k.*
      from keyed k
     order by k.tk, k.created_at desc, k.id desc
  ), page as (
    select l.*
      from latest l
     where p_before is null or l.created_at < p_before
     order by l.created_at desc, l.id desc
     limit v_limit
  ), unread as (
    select k.tk, count(*)::integer as n
      from keyed k
     where k.direction = 'inbound' and k.read_at is null
     group by k.tk
  )
  select p.tk,
         p.customer_id,
         p.counterpart,
         c.first_name,
         c.last_name,
         c.company,
         p.id,
         p.direction,
         p.channel,
         p.status,
         left(p.body, 280),
         p.created_at,
         coalesce(u.n, 0)
    from page p
    left join unread u on u.tk = p.tk
    left join public.customers c on c.id = p.customer_id and c.shop_id = p_shop_id
   order by p.created_at desc, p.id desc;
end
$$;

create function public.inbox_unread_count(p_shop_id uuid) returns integer
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can read the inbox' using errcode = '42501';
  end if;
  return (select count(*)::integer from public.messages m
           where m.shop_id = p_shop_id and m.direction = 'inbound' and m.read_at is null);
end
$$;

comment on function public.inbox_threads(uuid, integer, timestamptz) is
  'Staff inbox: newest message per conversation with unread counts (keyset paging on last_created_at). @nullable: customer_id, from_address, customer_first_name, customer_last_name, customer_company';

-- ---------------------------------------------------------------------------
-- preview_campaign_message — a campaign's text rendered exactly as
-- launch_campaign renders it, with placeholder names for the recipient, and
-- the length the body may have:
--   sms    max_body_length = 1600, or 1600 − the opt-out line when the
--          wording carries no opt-out instruction (footer_added: the line
--          comms_sms_with_optout appends); body is the final text
--   email  max_body_length = 50000; the unsubscribe footer is shown with
--          '[unsubscribe link]' (footer_added stays false: every marketing
--          email carries it)
-- body_length is the rendered length before any footer; truncated says the
-- sent text will be cut. A body over 50000 characters: 22023.
-- ---------------------------------------------------------------------------
create function public.preview_campaign_message(
  p_shop_id  uuid,
  p_channel  public.message_channel,
  p_body     text,
  p_subject  text default null
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c_footer constant text := E'\nReply STOP to opt out.';
  v_vars     jsonb;
  v_text     text;
  v_len      integer;
  v_max      integer;
  v_footer   boolean := false;
  v_body     text;
  v_subject  text;
  v_shop     text;
begin
  if not public.is_shop_manager(p_shop_id) then
    raise exception 'only owners, admins and managers can preview campaigns' using errcode = '42501';
  end if;
  if p_channel is null then
    raise exception 'choose sms or email' using errcode = '22023';
  end if;
  if char_length(coalesce(p_body, '')) > 50000 then
    raise exception 'the message is too long (max 50000 characters)' using errcode = '22023';
  end if;
  if p_subject is not null and char_length(p_subject) > 500 then
    raise exception 'the subject is too long (max 500 characters)' using errcode = '22023';
  end if;
  select s.name into v_shop from public.shops s where s.id = p_shop_id;
  v_vars := public.comms_customer_vars(p_shop_id, null)
            || jsonb_build_object('customer_first_name', '[first name]', 'customer_name', '[name]');
  if p_channel = 'email' then
    v_vars := v_vars || jsonb_build_object('unsubscribe_link', '[unsubscribe link]');
  end if;
  v_text := coalesce(btrim(public.render_template(coalesce(p_body, ''), v_vars), E' \t\r\n'), '');
  v_len := char_length(v_text);

  if p_channel = 'sms' then
    v_footer := v_text <> ''
                and left(v_text, 1600) !~* '\m(reply|text|txt|send)[[:space:]]+["''“‘]?stop\M';
    v_max := case when v_footer then 1600 - char_length(c_footer) else 1600 end;
    v_body := coalesce(public.comms_sms_with_optout(v_text), '');
  else
    v_max := 50000;
    v_body := case when v_text = '' then '' else public.comms_email_with_unsubscribe(v_text, '[unsubscribe link]') end;
    v_subject := coalesce(left(nullif(btrim(public.render_template(p_subject, v_vars)), ''), 500), v_shop);
  end if;

  return jsonb_build_object(
    'subject', v_subject,
    'body', v_body,
    'body_length', v_len,
    'max_body_length', v_max,
    'footer_added', v_footer,
    'truncated', v_len > v_max);
end
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function
  public.comms_document_vars(uuid, uuid),
  public.comms_document_target(uuid, uuid),
  public.comms_document_check_access(uuid, text)
from public, anon, authenticated;
grant execute on function
  public.comms_document_vars(uuid, uuid),
  public.comms_document_target(uuid, uuid),
  public.comms_document_check_access(uuid, text)
to service_role;

revoke execute on function
  public.enqueue_document_message(uuid, uuid, public.message_channel, text),
  public.preview_document_message(uuid, uuid, public.message_channel),
  public.inbox_threads(uuid, integer, timestamptz),
  public.inbox_unread_count(uuid),
  public.preview_campaign_message(uuid, public.message_channel, text, text)
from public, anon;
grant execute on function
  public.enqueue_document_message(uuid, uuid, public.message_channel, text),
  public.preview_document_message(uuid, uuid, public.message_channel),
  public.inbox_threads(uuid, integer, timestamptz),
  public.inbox_unread_count(uuid),
  public.preview_campaign_message(uuid, public.message_channel, text, text)
to authenticated, service_role;

revoke execute on function public.public_unsubscribe_info(uuid) from public;
grant execute on function public.public_unsubscribe_info(uuid) to anon, authenticated, service_role;
