-- ============================================================================
-- 0096 — A customer's own cancellation waits for a payment that is still
-- going through.
--
-- Every staff path that cancels or declines a job first releases the job's
-- open card attempts (payments edge `cancel_open_payments`) and stops while
-- one is still in progress: nobody may pay for a cancelled appointment. The
-- customer's own cancel on /booking/<token> (public_cancel_booking, 0042)
-- only checked the status and the cancel window, so a deposit Checkout or
-- an ACH / pay-later deposit still clearing (P-31) landed on the cancelled
-- job afterwards and someone had to notice and refund it.
--
-- public_cancel_booking (0042's body; same signature, grants and other
-- errors) now refuses while the booking page reports deposit.payment_pending
-- (booking_public_json, 0064: a card attempt still 'pending', or a payment
-- in flight — 'processing' for days — on the job or on its grouped invoice):
--   55000 'a payment for this booking is still going through; please try
--          again once it has finished, or call the shop'
--   HINT  'payment_in_progress'
-- The check reads exactly what the page shows, so a client that hides the
-- cancel button while deposit.payment_pending is true never offers a cancel
-- the server refuses. Once the payment settles (succeeded: the deposit is
-- paid and the customer may cancel as before, deposits are not refunded
-- automatically; an ACH debit that failed; a card attempt released as
-- 'cancelled' by the shop or the stale-attempt sweep — a declined card
-- attempt stays 'pending' because it can still be retried, 0012) the cancel
-- works. A Checkout Session that is open but not yet submitted has no
-- payment row, so it is not seen here: the payments edge still has to
-- expire the job's open sessions when it is cancelled.
-- ============================================================================

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
  -- 0096: never while money is on its way to this booking (see the header)
  if coalesce((public.booking_public_json(v_job.id, v_now) #>> '{deposit,payment_pending}')::boolean, false) then
    raise exception 'a payment for this booking is still going through; please try again once it has finished, or call the shop'
      using errcode = '55000', hint = 'payment_in_progress';
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
  'Customer self-cancellation by booking token (0042 rules: requested / scheduled / confirmed, until allow_client_cancel_hours before the start; technicians 42501). 0096: 55000 HINT payment_in_progress while deposit.payment_pending (a payment of the booking is still going through).';
