-- ============================================================================
-- 0127 — Email previews show the postal-address footer marketing email
-- carries (0119).
--
-- messages_02_marketing_postal_address (0119) ends every marketing email
-- with "<shop name> · <postal address>" when it is queued, and a shop
-- without an address on file cannot send marketing email at all (a campaign
-- launch fails with 55000 HINT postal_address_required; follow-ups are not
-- queued). The previews staff look at before sending never showed either:
-- preview_campaign_message (0090) wrapped the email with the unsubscribe
-- line only, and preview_template_message (0033) likewise for the marketing
-- keys, so the preview differed from what went out and a missing address
-- surfaced only when the launch failed.
--
-- Now (same inputs, same grants):
--   * preview_campaign_message — email: the body is
--       comms_email_with_postal_address(
--         comms_email_with_unsubscribe(text, '[unsubscribe link]'),
--         shop name, comms_shop_postal_address(shop))
--     i.e. exactly the footer the queued message gets. max_body_length for
--     email now leaves room for both footers (the unsubscribe line with a
--     real link's length unless the wording places {{unsubscribe_link}},
--     and the postal line unless the wording already shows the address), so
--     truncated says when the sent text will be cut. + postal_address_missing
--     (true for an email campaign of a shop with no postal address on file:
--     it cannot be launched). SMS is unchanged (postal_address_missing false).
--   * preview_template_message — + output column postal_address_missing; a
--     marketing key's email (comms_is_marketing_key: follow_up,
--     service_followup) gets the same footers; transactional templates and
--     SMS are unchanged. DROP + CREATE (a RETURNS TABLE gains a column).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- preview_campaign_message (0090 body + the postal footer)
-- ---------------------------------------------------------------------------
create or replace function public.preview_campaign_message(
  p_shop_id  uuid,
  p_channel  public.message_channel,
  p_body     text,
  p_subject  text default null
) returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  c_footer   constant text := E'\nReply STOP to opt out.';
  c_unsub    constant text := E'\n\nTo unsubscribe from these emails, visit: ';
  v_vars     jsonb;
  v_text     text;
  v_len      integer;
  v_max      integer;
  v_footer   boolean := false;
  v_body     text;
  v_subject  text;
  v_shop     text;
  v_address  text;
  v_link_len integer;
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
    v_address := public.comms_shop_postal_address(p_shop_id);
    -- room for the footers the queued email gets (a real link is longer
    -- than the placeholder shown here)
    v_link_len := char_length(coalesce(public.app_url('/u/00000000-0000-0000-0000-000000000000'), '[unsubscribe link]'));
    v_max := 50000
             - case when strpos(v_text, '[unsubscribe link]') > 0 then 0
                    else char_length(c_unsub) + v_link_len end
             - case when v_address is null or strpos(v_text, v_address) > 0 then 0
                    else char_length(E'\n\n' || concat_ws(' · ', nullif(btrim(v_shop), ''), v_address)) end;
    v_body := case when v_text = '' then ''
                   else public.comms_email_with_postal_address(
                          public.comms_email_with_unsubscribe(v_text, '[unsubscribe link]'), v_shop, v_address) end;
    v_subject := coalesce(left(nullif(btrim(public.render_template(p_subject, v_vars)), ''), 500), v_shop);
  end if;

  return jsonb_build_object(
    'subject', v_subject,
    'body', v_body,
    'body_length', v_len,
    'max_body_length', v_max,
    'footer_added', v_footer,
    'truncated', v_len > v_max,
    'postal_address_missing', p_channel = 'email' and v_address is null);
end
$$;

comment on function public.preview_campaign_message(uuid, public.message_channel, text, text) is
  'A campaign''s text rendered as launch_campaign renders it (manager+; 0090, 0127): {subject, body, body_length, max_body_length, footer_added, truncated, postal_address_missing}. Email bodies end with the unsubscribe line and the shop''s postal-address footer (0119) exactly as queued; max_body_length leaves room for both. postal_address_missing: an email campaign of a shop with no postal address on file (it cannot be launched).';

-- ---------------------------------------------------------------------------
-- preview_template_message (0033 body + the postal footer / flag)
-- ---------------------------------------------------------------------------
drop function public.preview_template_message(uuid, public.message_template_key, public.message_channel);

create function public.preview_template_message(
  p_job_id   uuid,
  p_key      public.message_template_key,
  p_channel  public.message_channel default 'sms'
) returns table (enabled boolean, to_address text, subject text, body text, postal_address_missing boolean)
language plpgsql stable security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_job  public.jobs;
  v_role public.shop_role;
  v_tpl  public.message_templates;
  v_cust public.customers;
  v_vars jsonb;
  v_body text;
  v_mkt  boolean := p_channel = 'email' and public.comms_is_marketing_key(p_key);
  v_shop text;
  v_addr text;
begin
  select * into v_job from public.jobs j where j.id = p_job_id;
  if not found then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if auth.uid() is not null then
    v_role := public.shop_role_of(v_job.shop_id);
    if v_role is null then
      raise exception 'job not found' using errcode = 'P0002';
    end if;
    if v_role = 'technician' and (not public.is_assigned_to_job(v_job.id)
                                  or p_key not in ('on_the_way', 'job_started', 'job_completed')) then
      raise exception 'not allowed to preview this message' using errcode = '42501';
    end if;
  end if;
  select * into v_tpl from public.message_templates t
   where t.shop_id = v_job.shop_id and t.key = p_key and t.channel = p_channel;
  if not found then
    raise exception 'template not found' using errcode = 'P0002';
  end if;
  select * into v_cust from public.customers c where c.id = v_job.customer_id and c.shop_id = v_job.shop_id;
  v_vars := public.comms_job_vars(v_job.id);
  -- Technicians send these messages but may not act as the customer: the
  -- job / quote / invoice tokens inside the link variables are customer
  -- credentials (0042 hides jobs.public_token from them), so a technician's
  -- preview shows a label where a link will go.
  if v_role = 'technician' then
    v_vars := v_vars || coalesce((select jsonb_object_agg(e.key, '[' || replace(e.key, '_', ' ') || ']')
                                    from jsonb_each(v_vars) e
                                   where e.key in ('booking_link', 'quote_link', 'invoice_link')
                                     and jsonb_typeof(e.value) = 'string'), '{}'::jsonb);
  end if;
  -- a marketing email gets its own unsubscribe link when queued; the preview
  -- shows where it goes (and the footer when the wording does not place it)
  if v_mkt then
    v_vars := v_vars || jsonb_build_object('unsubscribe_link', '[unsubscribe link]');
  end if;
  -- lines with a missing optional value are left out exactly as when the
  -- message is queued; lines whose only gap is a link are kept (blank)
  v_body := btrim(public.render_template(public.comms_omit_unavailable_values(v_tpl.body, v_vars, false), v_vars),
                  E' \t\r\n');
  if v_mkt then
    select s.name into v_shop from public.shops s where s.id = v_job.shop_id;
    v_addr := public.comms_shop_postal_address(v_job.shop_id);
    -- 0127: and the shop's postal-address footer (0119), as queued
    v_body := public.comms_email_with_postal_address(
                public.comms_email_with_unsubscribe(v_body, '[unsubscribe link]'), v_shop, v_addr);
  end if;
  return query select v_tpl.enabled,
                      case p_channel when 'sms' then v_cust.phone else v_cust.email::text end,
                      public.render_template(public.comms_omit_unavailable_values(v_tpl.subject, v_vars, false), v_vars),
                      v_body,
                      v_mkt and v_addr is null;
end
$$;

comment on function public.preview_template_message(uuid, public.message_template_key, public.message_channel) is
  '@nullable: to_address, subject';
revoke execute on function public.preview_template_message(uuid, public.message_template_key, public.message_channel)
  from public, anon;
grant execute on function public.preview_template_message(uuid, public.message_template_key, public.message_channel)
  to authenticated, service_role;
