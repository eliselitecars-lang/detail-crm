-- ============================================================================
-- 0106 — A customer's own cancel waits for an open payment page of the
-- booking: the database knows the job's open Checkout Sessions.
--
-- 0096 made public_cancel_booking refuse while a deposit payment row is
-- pending or processing, but a Checkout Session that is open and not yet
-- submitted has no payment row, and the customer's cancel (the /booking
-- page and the portal call public_cancel_booking directly) never went
-- through the payments edge that expires open sessions. Opening "Pay
-- deposit", cancelling in another tab, then finishing the still-open Stripe
-- page (it stays payable for 32-42 minutes) recorded a succeeded deposit on
-- the cancelled job, and staff had to notice and refund it.
--
-- The payments edge now tells the database about every Checkout Session it
-- opens for a job (a booking / quote deposit, a pay link of the job's
-- invoice), and the cancel refuses while one can still be paid:
--
--   job_checkout_holds  internal (service_role only): one row per open
--       Checkout Session of a job — its Stripe id and when Stripe expires it.
--   payments_hold_job_checkout(shop, job, session, expires_at)  service_role.
--       Called right after the session is created and BEFORE its URL is
--       handed out. Locks the job row (the lock public_cancel_booking takes)
--       and refuses a job that is closed meanwhile — cancelled, no-show or
--       completed: 55000 HINT booking_closed — so the edge expires the new
--       session instead of returning it. Past holds of the job are pruned.
--   payments_release_job_checkouts(shop, job, sessions?)  service_role.
--       Forgets the job's holds (the given sessions, or all of them); the
--       edge calls it after expiring them. A session that completes is
--       forgotten on its own: a payment row with that
--       stripe_checkout_session_id that is processing or received releases
--       it (from then on 0096's payment_pending check and the paid deposit
--       decide).
--   public_cancel_booking (0096's body; same signature, grants and other
--       errors) also refuses while the job has a hold that has not expired:
--         55000 'a payment page for this booking is still open; please close
--                it and try again in a few minutes, or call the shop'
--         HINT  'checkout_open'
--       The edge's customer cancel expires the job's open sessions, releases
--       them, then cancels; a direct call waits (at most until Stripe expires
--       the session). Staff cancellations already expire open sessions first
--       (payments cancel_open_payments) and are not affected.
-- ============================================================================

create table public.job_checkout_holds (
  stripe_checkout_session_id  text primary key
                              check (stripe_checkout_session_id ~ '^cs_[A-Za-z0-9_]+$'),
  shop_id                     uuid not null references public.shops (id) on delete cascade,
  job_id                      uuid not null,
  expires_at                  timestamptz not null,
  created_at                  timestamptz not null default now(),
  constraint job_checkout_holds_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete cascade
);
create index job_checkout_holds_job_idx on public.job_checkout_holds (shop_id, job_id, expires_at);

comment on table public.job_checkout_holds is
  'Internal (0106): the Stripe Checkout Sessions the payments edge opened for a job (deposit links, the job''s invoice pay links) that may still be paid — until expires_at, or until released (expired by the edge, or completed: a processing / received payment row with that session). While one is live the customer cannot cancel the booking online (public_cancel_booking 55000 HINT checkout_open). No client access.';
comment on column public.job_checkout_holds.expires_at is
  'When Stripe expires the session (Checkout Session expires_at): after that it can no longer be paid.';

alter table public.job_checkout_holds enable row level security;
revoke all on table public.job_checkout_holds from public, anon, authenticated;
grant select, insert, update, delete on table public.job_checkout_holds to service_role;

-- ---------------------------------------------------------------------------
-- payments_hold_job_checkout — the edge opened a session for the job
-- ---------------------------------------------------------------------------
create function public.payments_hold_job_checkout(
  p_shop_id     uuid,
  p_job_id      uuid,
  p_session_id  text,
  p_expires_at  timestamptz
) returns void
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_job public.jobs;
begin
  if p_shop_id is null or p_job_id is null or p_session_id is null or p_expires_at is null then
    raise exception 'shop, job, session and expiry are required' using errcode = '22023';
  end if;
  if p_session_id !~ '^cs_[A-Za-z0-9_]+$' then
    raise exception 'invalid Checkout Session id' using errcode = '22023';
  end if;
  -- the row lock public_cancel_booking takes: a cancel either sees this hold
  -- or has already closed the job (and the hold is refused)
  select * into v_job from public.jobs j where j.id = p_job_id and j.shop_id = p_shop_id for update;
  if not found then
    raise exception 'job not found' using errcode = 'P0002';
  end if;
  if v_job.status in ('cancelled', 'no_show', 'completed') then
    raise exception 'this booking is no longer taking payments' using errcode = '55000', hint = 'booking_closed';
  end if;
  delete from public.job_checkout_holds h
   where h.shop_id = p_shop_id and h.job_id = p_job_id and h.expires_at <= now();
  insert into public.job_checkout_holds (stripe_checkout_session_id, shop_id, job_id, expires_at)
  values (p_session_id, p_shop_id, p_job_id, p_expires_at)
  on conflict (stripe_checkout_session_id) do update
     set expires_at = greatest(public.job_checkout_holds.expires_at, excluded.expires_at)
   where public.job_checkout_holds.shop_id = excluded.shop_id
     and public.job_checkout_holds.job_id = excluded.job_id;
  if not found then
    raise exception 'Checkout Session % is held for another job', p_session_id using errcode = '22023';
  end if;
end
$$;

comment on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz) is
  'service_role (payments edge, 0106): record an open Checkout Session of a job until p_expires_at, before handing out its URL. Locks the job; 55000 HINT booking_closed when the job is cancelled / no-show / completed (the edge then expires the session). Idempotent per session.';
revoke execute on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.payments_hold_job_checkout(uuid, uuid, text, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- payments_release_job_checkouts — the edge expired the job's sessions
-- ---------------------------------------------------------------------------
create function public.payments_release_job_checkouts(
  p_shop_id      uuid,
  p_job_id       uuid,
  p_session_ids  text[] default null
) returns integer
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  if p_shop_id is null or p_job_id is null then
    raise exception 'shop and job are required' using errcode = '22023';
  end if;
  delete from public.job_checkout_holds h
   where h.shop_id = p_shop_id and h.job_id = p_job_id
     and (p_session_ids is null or h.stripe_checkout_session_id = any (p_session_ids));
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

comment on function public.payments_release_job_checkouts(uuid, uuid, text[]) is
  'service_role (payments edge, 0106): forget the job''s open Checkout Session holds — p_session_ids, or all of them when null — once the edge expired them. Returns how many were released.';
revoke execute on function public.payments_release_job_checkouts(uuid, uuid, text[]) from public, anon, authenticated;
grant execute on function public.payments_release_job_checkouts(uuid, uuid, text[]) to service_role;

-- ---------------------------------------------------------------------------
-- A completed session releases its hold: its payment row exists and is
-- processing or received (a card attempt still pending, or one that failed,
-- leaves the session payable — Checkout lets the customer retry).
-- ---------------------------------------------------------------------------
create function public.payments_release_checkout_hold() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  delete from public.job_checkout_holds h where h.stripe_checkout_session_id = new.stripe_checkout_session_id;
  return null;
end
$$;

comment on function public.payments_release_checkout_hold() is
  'Internal (0106): a payment of a Checkout Session that is processing or received releases that session''s job_checkout_holds row.';
revoke execute on function public.payments_release_checkout_hold() from public, anon, authenticated;

create trigger payments_release_checkout_hold after insert or update of status, stripe_checkout_session_id
  on public.payments
  for each row
  when (new.stripe_checkout_session_id is not null
        and new.status in ('processing', 'succeeded', 'partially_refunded', 'refunded'))
  execute function public.payments_release_checkout_hold();

-- ---------------------------------------------------------------------------
-- public_cancel_booking (0096) + the open-session check
-- ---------------------------------------------------------------------------
create or replace function public.public_cancel_booking(p_token uuid, p_reason text default null,
                                                        p_now timestamptz default now())
returns jsonb
language plpgsql volatile security definer
set search_path = ''
as $$
declare
  v_now      timestamptz := public.effective_now(p_now);
  v_job      public.jobs;
  v_hours    integer;
  v_deadline timestamptz;
  v_reason   text := nullif(btrim(coalesce(p_reason, ''), E' \t\r\n'), '');
  v_vars     jsonb;
begin
  select * into v_job from public.jobs j where j.public_token = p_token for update;
  if not found then
    raise exception 'booking not found' using errcode = 'PT404';
  end if;
  if auth.uid() is not null and public.is_shop_member(v_job.shop_id) and not public.is_shop_manager(v_job.shop_id)
     and not exists (select 1 from public.customers c
                      where c.id = v_job.customer_id and c.shop_id = v_job.shop_id and c.portal_user_id = auth.uid()) then
    raise exception 'only owners, admins and managers can cancel appointments' using errcode = '42501';
  end if;
  if v_job.status not in ('requested', 'scheduled', 'confirmed') then
    raise exception 'this booking can no longer be cancelled online (it is %)', replace(v_job.status::text, '_', ' ')
      using errcode = '22023';
  end if;
  if char_length(v_reason) > 1000 then
    raise exception 'reason is too long (max 1000 characters)' using errcode = '22023';
  end if;
  select b.allow_client_cancel_hours into v_hours from public.booking_settings b where b.shop_id = v_job.shop_id;
  if v_job.scheduled_start is not null then
    v_deadline := v_job.scheduled_start - make_interval(hours => coalesce(v_hours, 0));
    if v_now > v_deadline then
      raise exception 'online cancellation closed % hours before the appointment; please call the shop', coalesce(v_hours, 0)
        using errcode = '22023';
    end if;
  end if;
  -- 0096: never while money is on its way to this booking
  if coalesce((public.booking_public_json(v_job.id, v_now) #>> '{deposit,payment_pending}')::boolean, false) then
    raise exception 'a payment for this booking is still going through; please try again once it has finished, or call the shop'
      using errcode = '55000', hint = 'payment_in_progress';
  end if;
  -- 0106: nor while a payment page of it can still be paid (wall clock:
  -- Stripe expires sessions in real time)
  if exists (select 1 from public.job_checkout_holds h
              where h.shop_id = v_job.shop_id and h.job_id = v_job.id and h.expires_at > now()) then
    raise exception 'a payment page for this booking is still open; please close it and try again in a few minutes, or call the shop'
      using errcode = '55000', hint = 'checkout_open';
  end if;

  update public.jobs j
     set status = 'cancelled',
         cancel_reason = coalesce(v_reason, 'Cancelled by the customer online')
   where j.id = v_job.id
  returning * into v_job;

  begin
    v_vars := public.comms_job_vars(v_job.id);
    perform public.notify_shop_staff(
      v_job.shop_id, array['owner', 'admin', 'manager']::public.shop_role[], 'booking_cancelled',
      'Booking cancelled by ' || public.integration_customer_label(v_job.shop_id, v_job.customer_id),
      concat_ws(' · ', 'Job #' || v_job.number::text,
                nullif(concat_ws(' at ', v_vars ->> 'job_date', v_vars ->> 'job_time'), ''), v_reason),
      v_job.id, null, p_customer_id => v_job.customer_id);
  exception when others then
    raise warning 'booking cancellation notification failed for job %: % (%)', v_job.id, sqlerrm, sqlstate;
  end;

  return public.booking_public_json(v_job.id, v_now);
end
$$;

comment on function public.public_cancel_booking(uuid, text, timestamptz) is
  'Customer self-cancellation by booking token (0042 rules: requested / scheduled / confirmed, until allow_client_cancel_hours before the start; technicians 42501). 55000 HINT payment_in_progress while deposit.payment_pending (0096), 55000 HINT checkout_open while a Checkout Session of the job can still be paid (0106: job_checkout_holds; the payments edge expires and releases them before cancelling).';
