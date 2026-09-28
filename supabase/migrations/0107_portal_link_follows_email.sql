-- ============================================================================
-- 0107 — A customer's client-portal link follows the email on file; realtime
-- DELETE events reach filtered subscriptions.
--
-- Portal link (portal_user_id)
--   A portal account is linked to a customer only when the customer's email
--   equals the account's CONFIRMED email (portal_claim_customers 0043, the
--   online booking 0054/0102). Nothing re-checked it afterwards, so the link
--   outlived the address that justified it:
--     * staff correcting a mistyped email (the record carried bob@, Bob
--       claimed it, staff fixed it to alice@) left Bob linked — he kept the
--       customer's contact details, vehicles, jobs, quotes, invoices,
--       documents and booking tokens (cancel / pay), and could cancel the
--       customer's membership or open the Stripe billing portal
--       (portal_membership_access checks only the link) — while Alice could
--       never claim her own record (the claim needs an unlinked record);
--     * merge_customers (0074) carried the duplicate's link onto the
--       survivor (coalesce(t.portal_user_id, v_src.portal_user_id)) while
--       the survivor kept its own email: whoever claimed a lead that carried
--       their own address (a public lead form) took over the real
--       customer's portal once staff merged the "duplicate" in.
--   Same rule as create_online_booking ("an email proves nothing unless it
--   is the caller's confirmed email") and customers_comms_readdress ("the
--   old inbox may belong to someone else now"):
--   customers_25_portal_link_email (BEFORE UPDATE, every context) clears
--   portal_user_id when
--     * the email changes (case-insensitively; also to null), or
--     * a customer merge (GUC detailcrm.customer_merge = 'on', set by
--       merge_customers) gives the record another account's link,
--   unless the record's (new) email equals the linked account's confirmed
--   email (auth.users: email confirmed, not anonymous, not deleted). A
--   cleared link is claimable again by the rightful owner
--   (portal_claim_customers on their next portal visit). Other direct link
--   writes are unchanged: clients may only clear a link (0004 guard);
--   service_role / database sessions may still set one. Existing rows are
--   not rewritten.
--
-- Realtime deletes
--   Supabase Postgres Changes can only match a DELETE event against a
--   subscription filter (web useRealtime `shop_id=eq.<shop>`, the bell's
--   `user_id=eq.<uid>`, iOS JobsRealtimeHub `shop_id=eq.<shop>`) when the
--   table has REPLICA IDENTITY FULL: otherwise the old row carries only the
--   primary key and the filtered subscriber never hears about the delete
--   (a deleted task / time entry, a dismissed notification, the future
--   visits a repeat-series delete removes). Every public table in the
--   supabase_realtime publication (jobs, messages, notifications, payments,
--   time_entries — 0044 — and tasks — 0081) gets REPLICA IDENTITY FULL.
--   Row-level security still applies: Realtime sends a DELETE's old record
--   with only its primary key to subscribers of an RLS table.
--   A table added to the publication later must do the same
--   (tests/100_portal_link_realtime.sql asserts it for the whole publication).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- customers_25_portal_link_email
-- ---------------------------------------------------------------------------
create function public.customers_portal_link_follows_email() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_merge  boolean := coalesce(current_setting('detailcrm.customer_merge', true), '') = 'on';
begin
  if new.portal_user_id is null then
    return new;
  end if;
  if lower(new.email::text) is not distinct from lower(old.email::text)
     and (new.portal_user_id is not distinct from old.portal_user_id or not v_merge) then
    return new;
  end if;
  if new.email is null
     or not exists (select 1 from auth.users u
                     where u.id = new.portal_user_id
                       and u.email is not null
                       and lower(u.email) = lower(new.email::text)
                       and u.email_confirmed_at is not null
                       and not coalesce(u.is_anonymous, false)
                       and u.deleted_at is null) then
    new.portal_user_id := null;
  end if;
  return new;
end
$$;

comment on function public.customers_portal_link_follows_email() is
  'Internal (0107): clears customers.portal_user_id when the email changes (or a merge brings another account''s link) and the new email is not the linked account''s confirmed email.';
revoke execute on function public.customers_portal_link_follows_email() from public, anon, authenticated;

create trigger customers_25_portal_link_email before update of email, portal_user_id on public.customers
  for each row execute function public.customers_portal_link_follows_email();

-- ---------------------------------------------------------------------------
-- REPLICA IDENTITY FULL for every realtime-published public table
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select pt.schemaname, pt.tablename
      from pg_catalog.pg_publication_tables pt
     where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
     order by pt.tablename
  loop
    execute format('alter table %I.%I replica identity full', r.schemaname, r.tablename);
  end loop;
end
$$;
