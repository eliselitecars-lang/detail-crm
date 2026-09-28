-- ============================================================================
-- 0080 — Communication v2 (range 0080-0089): enum types and enum values.
--
--   0080  enums (this file)
--   0081  schema: every new table, column, CHECK / index replacement, RLS
--         policy, grant and backfill of the range (+ tasks in the realtime
--         publication)
--   0082  push notifications for the staff app (P-2): device tokens,
--         per-member push preferences, notify_member, job assigned /
--         rescheduled notifications, the push claim queue
--   0083  templates v2: enqueue_message_core (the generalised enqueue core),
--         wording for EVERY template key (incl. money's gift_card_delivery /
--         referral_reward and ops' job_report), seeding + backfill
--   0084  staff tasks (P-32)
--   0085  document follow-ups: quotes, deposits, invoices, overdue (P-3)
--   0086  up to 3 appointment reminders + per-service follow-ups (P-4);
--         enqueue_due_automations v2
--   0087  CSV import (customers / vehicles / services) + job export (P-5)
--   0088  custom fields, booking questions, lead forms, customer-merge
--         follow-up, booking tracking ids (P-9, P-10)
--   0089  self-serve SMS numbers (P-14) and outbound webhooks (P-27)
--
-- Migrations run with psql --single-transaction, and a value added with
-- ALTER TYPE ... ADD VALUE cannot be used in the transaction that added it,
-- so nothing in this file uses the new values (0081 onward may). New enum
-- TYPES are created here too.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- New types (P-9)
-- ---------------------------------------------------------------------------
-- custom_fields.entity: which record a shop-defined field belongs to.
create type public.custom_field_entity as enum ('customer', 'job');

-- custom_fields.type: how a value is entered and validated.
create type public.custom_field_type as enum ('text', 'textarea', 'number', 'select', 'multiselect', 'checkbox', 'date');

comment on type public.custom_field_entity is
  'custom_fields.entity: customer (customers.custom_data, lead forms) | job (jobs.custom_data, booking questions).';
comment on type public.custom_field_type is
  'custom_fields.type: text (<= 2000) | textarea (<= 10000) | number | select (one option) | multiselect (options) | checkbox (boolean) | date (YYYY-MM-DD).';

-- ---------------------------------------------------------------------------
-- New values of existing types
-- ---------------------------------------------------------------------------
-- staff notifications
--   job_assigned, job_rescheduled   P-2 (readable by every member: 0082)
--   new_lead                        P-9 lead form submitted (managers+)
--   task_assigned, task_due         P-32 (readable by every member: 0082)
--   sms_number_status               P-14 SMS number verification changed (managers+; sent to admins)
--   webhook_failing                 P-27 an endpoint was disabled after repeated failures (managers+; sent to admins)
alter type public.notification_kind add value if not exists 'job_assigned';
alter type public.notification_kind add value if not exists 'job_rescheduled';
alter type public.notification_kind add value if not exists 'new_lead';
alter type public.notification_kind add value if not exists 'task_assigned';
alter type public.notification_kind add value if not exists 'task_due';
alter type public.notification_kind add value if not exists 'sms_number_status';
alter type public.notification_kind add value if not exists 'webhook_failing';

-- customer messages (wording, seeding and classification in 0083)
--   quote_reminder, deposit_reminder, invoice_reminder, invoice_overdue
--                     P-3 document follow-ups (transactional)
--   service_followup  P-4 per-service maintenance follow-up (marketing)
--   lead_received     P-9 lead form auto-reply (transactional)
alter type public.message_template_key add value if not exists 'quote_reminder';
alter type public.message_template_key add value if not exists 'deposit_reminder';
alter type public.message_template_key add value if not exists 'invoice_reminder';
alter type public.message_template_key add value if not exists 'invoice_overdue';
alter type public.message_template_key add value if not exists 'service_followup';
alter type public.message_template_key add value if not exists 'lead_received';

-- customers created by a CSV import (P-5)
alter type public.customer_source add value if not exists 'import';
