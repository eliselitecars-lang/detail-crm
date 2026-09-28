-- ============================================================================
-- 0094 — money fix forward: staff_record_quote_response honours quote
-- options (P-15).
--
-- staff_record_quote_response is defined in the committed integration
-- migration 0093. A database that already applied 0093 never re-runs it
-- (db push skips recorded files; migrations are forward-only, DEPLOY §3.2),
-- and in a from-zero run 0093 comes after the money range, so the option
-- rules have to live in a file numbered above 0093. This file replaces the
-- function (DROP of 0093's 5-argument version + CREATE with a trailing
-- p_option_id) with the same rules as the customer's own
-- public_respond_quote (0067):
--   'approve'  a quote with options needs p_option_id, one of ITS options
--              (the one the customer chose; stored as selected_option_id,
--              which staff cannot set on a sent quote any other way); a
--              quote without options refuses one (22023 either way).
--              p_selected_optional_line_ids (when not null) must be optional
--              lines of this quote that are shared or of the chosen option,
--              and becomes exactly the selected set; null keeps the current
--              selections of the shared / chosen-option lines (optional lines
--              of the other options are unselected, so they never count).
--              approved_by_name = the name the customer gave (optional,
--              ≤ 200).
--   'decline'  declined_reason (optional, ≤ 1000); p_option_id is ignored.
-- Everything else is 0093's: owner/admin/manager (42501; non-member or
-- unknown quote P0002), only sent / viewed quotes inside their validity
-- (22023), returns the updated quote; the staff notification (quote status
-- trigger, 0041) is unchanged. Named-argument callers of the 5-argument
-- version keep working.
-- ============================================================================

drop function public.staff_record_quote_response(uuid, text, uuid[], text, text);

create function public.staff_record_quote_response(
  p_quote_id                    uuid,
  p_action                      text,
  p_selected_optional_line_ids  uuid[] default null,
  p_approved_by_name            text default null,
  p_declined_reason             text default null,
  p_option_id                   uuid default null
) returns public.quotes
language plpgsql security definer
set search_path = ''
as $$
declare
  v_q      public.quotes;
  v_tz     text;
  v_action text := lower(btrim(p_action));
  v_name   text := nullif(btrim(p_approved_by_name), '');
  v_reason text := nullif(btrim(p_declined_reason), '');
  v_ids    uuid[];
  v_options boolean;
begin
  select * into v_q from public.quotes q where q.id = p_quote_id for update;
  if not found or not public.is_shop_member(v_q.shop_id) then
    raise exception 'quote not found' using errcode = 'P0002';
  end if;
  if not public.is_shop_manager(v_q.shop_id) then
    raise exception 'only owners, admins and managers can record a quote response' using errcode = '42501';
  end if;
  if v_action is null or v_action not in ('approve', 'decline') then
    raise exception 'action must be approve or decline' using errcode = '22023';
  end if;
  if v_q.status not in ('sent', 'viewed') then
    raise exception 'this quote can no longer be answered (it is %)', v_q.status using errcode = '22023';
  end if;
  select s.timezone into v_tz from public.shops s where s.id = v_q.shop_id;
  if v_q.valid_until is not null and public.quote_validity_end(v_q.valid_until, v_tz) <= now() then
    raise exception 'this quote has expired' using errcode = '22023';
  end if;

  if v_action = 'approve' then
    if char_length(v_name) > 200 then
      raise exception 'the approver''s name is too long (max 200 characters)' using errcode = '22023';
    end if;
    v_options := exists (select 1 from public.quote_options o where o.quote_id = v_q.id and o.shop_id = v_q.shop_id);
    if v_options and (p_option_id is null
                      or not exists (select 1 from public.quote_options o
                                     where o.id = p_option_id and o.quote_id = v_q.id and o.shop_id = v_q.shop_id)) then
      raise exception 'choose the option the customer approved (one of this quote''s options)' using errcode = '22023';
    end if;
    if not v_options and p_option_id is not null then
      raise exception 'this quote has no options to choose from' using errcode = '22023';
    end if;
    if p_selected_optional_line_ids is not null then
      v_ids := array(select distinct x from unnest(p_selected_optional_line_ids) as x where x is not null);
      if exists (select 1 from unnest(v_ids) as x
                 where not exists (select 1 from public.quote_line_items li
                                   where li.id = x and li.quote_id = v_q.id and li.shop_id = v_q.shop_id
                                     and li.optional
                                     and (li.option_id is null or li.option_id = p_option_id))) then
        raise exception 'selected items must be optional items of this quote (and of the chosen option)'
          using errcode = '22023';
      end if;
      update public.quote_line_items li
         set selected = (li.id = any (v_ids))
       where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional
         and li.selected is distinct from (li.id = any (v_ids));
    else
      -- keep the current selections, but only of lines that are counted
      update public.quote_line_items li
         set selected = false
       where li.quote_id = v_q.id and li.shop_id = v_q.shop_id and li.optional and li.selected
         and li.option_id is not null and li.option_id is distinct from p_option_id;
    end if;
    update public.quotes q
       set status = 'approved', approved_by_name = v_name,
           selected_option_id = case when v_options then p_option_id else q.selected_option_id end
     where q.id = v_q.id
    returning * into v_q;
  else
    if char_length(v_reason) > 1000 then
      raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
    end if;
    update public.quotes q set status = 'declined', declined_reason = v_reason where q.id = v_q.id
    returning * into v_q;
  end if;
  return v_q;
end
$$;

revoke execute on function public.staff_record_quote_response(uuid, text, uuid[], text, text, uuid) from public, anon;
grant execute on function public.staff_record_quote_response(uuid, text, uuid[], text, text, uuid)
  to authenticated, service_role;
