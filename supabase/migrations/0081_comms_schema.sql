-- ============================================================================
-- 0081 — Communication v2: schema. Every new table, column, CHECK / index
-- replacement, RLS policy, grant and backfill of the range (0080-0089), so
-- the behaviour files after it (0082-0089) can use any of them. Trigger
-- functions and RPCs live in those files; this file only attaches the
-- shared foundation triggers (prevent_shop_change, set_updated_at).
--
--   P-2  device_push_tokens, member_notification_prefs, notifications.pushed_at / push_attempts
--   P-3  followup_settings, document_followup_log, quotes / invoices .followups_paused,
--        jobs.deposit_followups_paused, messages.quote_id / invoice_id
--   P-4  message_templates.reminder_offsets_minutes (+ message_templates_offset replaced),
--        job_automation_log.reminder_offset_minutes / service_followup_id (+ key check and
--        unique indexes replaced), service_followups
--   P-5  import_batches
--   P-9  custom_fields, customers.custom_data, lead_forms, lead_submissions
--   P-10 booking_settings.meta_pixel_id / ga4_measurement_id
--   P-14 shop_sms_numbers provisioning columns
--   P-27 webhook_endpoints, webhook_deliveries
--   P-32 tasks (+ realtime publication)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- CHECK helpers (IMMUTABLE, pure)
-- ---------------------------------------------------------------------------

-- appointment_reminder offsets (P-4): null (one reminder at offset_minutes),
-- or 1..3 distinct offsets, each between -43200 (30 days before) and 0 (at
-- the start), whose largest element — the reminder nearest the
-- appointment — equals the template's offset_minutes (the single offset
-- that clients predating P-4 read and edit).
create function public.comms_reminder_offsets_valid(p_offsets integer[], p_offset integer) returns boolean
language sql immutable
set search_path = ''
as $$
  select p_offsets is null
      or (cardinality(p_offsets) between 1 and 3
          and array_position(p_offsets, null) is null
          and (select count(distinct o) = cardinality(p_offsets) and bool_and(o between -43200 and 0)
                      and max(o) = p_offset
                 from unnest(p_offsets) as o))
$$;

-- custom field options (P-9): select / multiselect need 1..50 distinct
-- options of 1..100 characters (no surrounding blanks); other types none.
create function public.comms_custom_field_options_valid(p_type public.custom_field_type, p_options text[])
returns boolean
language sql immutable
set search_path = ''
as $$
  select case
    when p_options is null then false
    when p_type in ('select', 'multiselect') then
      cardinality(p_options) between 1 and 50
      and array_position(p_options, null) is null
      and (select count(distinct o) = cardinality(p_options)
                  and bool_and(char_length(o) between 1 and 100 and o = btrim(o))
             from unnest(p_options) as o)
    else cardinality(p_options) = 0
  end
$$;

revoke execute on function
  public.comms_reminder_offsets_valid(integer[], integer),
  public.comms_custom_field_options_valid(public.custom_field_type, text[])
from public, anon;
grant execute on function
  public.comms_reminder_offsets_valid(integer[], integer),
  public.comms_custom_field_options_valid(public.custom_field_type, text[])
to authenticated, service_role;

-- ===========================================================================
-- P-2 push notifications
-- ===========================================================================

-- A device of a signed-in user (user-scoped like profiles: no shop_id). The
-- token is the APNs device token (hex). Written only by register_push_token
-- / unregister_push_token (0082) and the push worker (service_role).
create table public.device_push_tokens (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  token            text not null check (token ~ '^[0-9a-f]{64,200}$'),
  platform         text not null default 'ios' check (platform = 'ios'),
  apns_env         text not null check (apns_env in ('sandbox', 'production')),
  bundle_id        text not null check (char_length(bundle_id) between 1 and 200),
  app_version      text check (app_version is null or char_length(app_version) <= 40),
  created_at       timestamptz not null default now(),
  last_seen_at     timestamptz not null default now(),
  disabled_at      timestamptz,
  disabled_reason  text check (disabled_reason is null or char_length(disabled_reason) <= 200),
  constraint device_push_tokens_token_key unique (token)
);
create index device_push_tokens_user_idx on public.device_push_tokens (user_id) where disabled_at is null;

comment on table public.device_push_tokens is
  'APNs device tokens of signed-in users (register_push_token). Users read and delete their own; the push worker (service_role) reads them.';

alter table public.device_push_tokens enable row level security;
create policy device_push_tokens_select on public.device_push_tokens for select to authenticated
  using (user_id = auth.uid());
create policy device_push_tokens_delete on public.device_push_tokens for delete to authenticated
  using (user_id = auth.uid());
revoke all on public.device_push_tokens from anon;
revoke insert, update, truncate, references, trigger on public.device_push_tokens from authenticated;
grant select, delete on public.device_push_tokens to authenticated;

-- Which notification kinds a member wants PUSHED to their devices (the
-- in-app bell is unaffected) and an optional mute. One row per membership,
-- written by the member themselves (set_notification_prefs or directly);
-- managers cannot edit other members' preferences. No row = every kind.
create table public.member_notification_prefs (
  member_id    uuid primary key,
  shop_id      uuid not null references public.shops (id) on delete cascade,
  push_kinds   public.notification_kind[] not null default enum_range(null::public.notification_kind),
  muted_until  timestamptz,
  updated_at   timestamptz not null default now(),
  constraint member_notification_prefs_member_fk foreign key (shop_id, member_id)
    references public.shop_members (shop_id, id) on delete cascade,
  constraint member_notification_prefs_kinds check (array_position(push_kinds, null) is null)
);
create index member_notification_prefs_shop_member_idx on public.member_notification_prefs (shop_id, member_id);

comment on table public.member_notification_prefs is
  'Per-member push preferences: push_kinds = kinds that may be pushed (default all), muted_until pauses pushes. Own row only.';

create trigger member_notification_prefs_05_prevent_shop_change before update on public.member_notification_prefs
  for each row execute function public.prevent_shop_change();
create trigger member_notification_prefs_90_set_updated_at before update on public.member_notification_prefs
  for each row execute function public.set_updated_at();

alter table public.member_notification_prefs enable row level security;
create policy member_notification_prefs_select on public.member_notification_prefs for select to authenticated
  using (public.is_own_member(member_id) and public.is_shop_member(shop_id));
create policy member_notification_prefs_insert on public.member_notification_prefs for insert to authenticated
  with check (public.is_own_member(member_id) and public.is_shop_member(shop_id));
create policy member_notification_prefs_update on public.member_notification_prefs for update to authenticated
  using (public.is_own_member(member_id) and public.is_shop_member(shop_id))
  with check (public.is_own_member(member_id) and public.is_shop_member(shop_id));
revoke all on public.member_notification_prefs from anon;
revoke delete, truncate, references, trigger on public.member_notification_prefs from authenticated;
grant select, insert, update on public.member_notification_prefs to authenticated;

-- notifications: the push queue. pushed_at null = still to be pushed
-- (claim_push_batch); push_attempts counts claims. History that existed
-- before push was introduced is never pushed. Column privileges are
-- unchanged: clients may still only UPDATE read_at.
alter table public.notifications
  add column pushed_at      timestamptz,
  add column push_attempts  smallint not null default 0 check (push_attempts between 0 and 10);
update public.notifications set pushed_at = created_at where pushed_at is null;
create index notifications_push_queue_idx on public.notifications (created_at) where pushed_at is null;

comment on column public.notifications.pushed_at is
  'When the push worker handled this notification (pushed or skipped); null = waiting for claim_push_batch.';

-- ===========================================================================
-- P-3 document follow-ups
-- ===========================================================================

-- Per-shop follow-up schedule (one row per shop, seeded by shops_seed_comms
-- and backfilled below). All off by default. Attempt n of a document is due
-- at  base + first_after + (n - 1) * repeat_every  (quotes: sent_at;
-- deposits: when the appointment was set; invoice reminders: sent_at;
-- overdue: due_at, in days).
create table public.followup_settings (
  shop_id                     uuid primary key references public.shops (id) on delete cascade,
  quote_enabled               boolean not null default false,
  quote_first_after_hours     integer not null default 48 check (quote_first_after_hours between 1 and 2160),
  quote_repeat_every_hours    integer not null default 72 check (quote_repeat_every_hours between 1 and 2160),
  quote_max_attempts          smallint not null default 2 check (quote_max_attempts between 0 and 10),
  deposit_enabled             boolean not null default false,
  deposit_first_after_hours   integer not null default 24 check (deposit_first_after_hours between 1 and 2160),
  deposit_repeat_every_hours  integer not null default 48 check (deposit_repeat_every_hours between 1 and 2160),
  deposit_max_attempts        smallint not null default 2 check (deposit_max_attempts between 0 and 10),
  invoice_enabled             boolean not null default false,
  invoice_first_after_hours   integer not null default 72 check (invoice_first_after_hours between 1 and 2160),
  invoice_repeat_every_hours  integer not null default 168 check (invoice_repeat_every_hours between 1 and 2160),
  invoice_max_attempts        smallint not null default 2 check (invoice_max_attempts between 0 and 10),
  overdue_enabled             boolean not null default false,
  overdue_first_after_days    smallint not null default 1 check (overdue_first_after_days between 0 and 90),
  overdue_repeat_every_days   smallint not null default 7 check (overdue_repeat_every_days between 1 and 90),
  overdue_max_attempts        smallint not null default 3 check (overdue_max_attempts between 0 and 10),
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

comment on table public.followup_settings is
  'Automatic follow-ups for unapproved quotes, unpaid deposits, unpaid invoices and overdue invoices (0085). One row per shop; admins edit.';

create trigger followup_settings_05_prevent_shop_change before update on public.followup_settings
  for each row execute function public.prevent_shop_change();
create trigger followup_settings_90_set_updated_at before update on public.followup_settings
  for each row execute function public.set_updated_at();

alter table public.followup_settings enable row level security;
create policy followup_settings_select on public.followup_settings for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy followup_settings_update on public.followup_settings for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
revoke all on public.followup_settings from anon;
revoke insert, delete, truncate, references, trigger on public.followup_settings from authenticated;
grant select, update on public.followup_settings to authenticated;

insert into public.followup_settings (shop_id) select s.id from public.shops s on conflict (shop_id) do nothing;

-- Per-document pause switches (staff-writable through the documents' own
-- policies / set_document_followups_paused).
alter table public.quotes add column followups_paused boolean not null default false;
alter table public.invoices add column followups_paused boolean not null default false;
alter table public.jobs add column deposit_followups_paused boolean not null default false;
-- invoices and jobs use column-level SELECT grants (their tokens are hidden)
grant select (followups_paused) on public.invoices to authenticated;
grant select (deposit_followups_paused) on public.jobs to authenticated;

comment on column public.quotes.followups_paused is 'Staff paused the automatic quote follow-ups of this quote.';
comment on column public.invoices.followups_paused is 'Staff paused the automatic reminders (and overdue notices) of this invoice.';
comment on column public.jobs.deposit_followups_paused is 'Staff paused the automatic deposit reminders of this job.';

-- The document a message is about (follow-ups, quote / invoice sends).
alter table public.messages
  add column quote_id    uuid,
  add column invoice_id  uuid,
  add constraint messages_quote_fk foreign key (shop_id, quote_id)
    references public.quotes (shop_id, id) on delete set null (quote_id),
  add constraint messages_invoice_fk foreign key (shop_id, invoice_id)
    references public.invoices (shop_id, id) on delete set null (invoice_id);
create index messages_shop_quote_idx on public.messages (shop_id, quote_id) where quote_id is not null;
create index messages_shop_invoice_idx on public.messages (shop_id, invoice_id) where invoice_id is not null;

-- One row per follow-up attempt ever processed: the idempotency marker of
-- enqueue_document_followups (claimed with ON CONFLICT DO NOTHING before
-- anything is queued). doc_id is the quote (quote), job (deposit) or
-- invoice (invoice, invoice_overdue) id.
create table public.document_followup_log (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops (id) on delete cascade,
  doc_kind      text not null check (doc_kind in ('quote', 'deposit', 'invoice', 'invoice_overdue')),
  doc_id        uuid not null,
  attempt       smallint not null check (attempt between 1 and 10),
  due_at        timestamptz not null,
  processed_at  timestamptz not null,
  outcome       text not null check (outcome in ('queued', 'skipped')),
  message_ids   uuid[] not null default '{}',
  created_at    timestamptz not null default now(),
  constraint document_followup_log_shop_id_id_key unique (shop_id, id),
  constraint document_followup_log_once unique (doc_kind, doc_id, attempt),
  constraint document_followup_log_outcome check ((outcome = 'queued') = (cardinality(message_ids) > 0))
);
create index document_followup_log_shop_doc_idx on public.document_followup_log (shop_id, doc_kind, doc_id);

comment on table public.document_followup_log is
  'One row per document follow-up attempt processed (0085): the idempotency marker. Managers read it.';

alter table public.document_followup_log enable row level security;
create policy document_followup_log_select on public.document_followup_log for select to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.document_followup_log from anon;
revoke insert, update, delete, truncate, references, trigger on public.document_followup_log from authenticated;

-- ===========================================================================
-- P-4 multiple appointment reminders + per-service follow-ups
-- ===========================================================================

-- Up to 3 reminders per appointment (e.g. a week, a day and an hour before).
-- Null = one reminder at offset_minutes (the pre-P-4 behaviour). All
-- channels of the key share the array (0086 message_templates_* triggers).
alter table public.message_templates add column reminder_offsets_minutes integer[];

comment on column public.message_templates.reminder_offsets_minutes is
  'appointment_reminder only: 1..3 distinct offsets (minutes, -43200..0), sorted descending; offset_minutes is the largest (nearest the start). Null = single reminder at offset_minutes.';

alter table public.message_templates drop constraint message_templates_offset;
alter table public.message_templates add constraint message_templates_offset check (
  case key
    when 'appointment_reminder' then offset_minutes is not null and offset_minutes between -43200 and 0
                                     and public.comms_reminder_offsets_valid(reminder_offsets_minutes, offset_minutes)
    when 'review_request'       then offset_minutes is not null and offset_minutes between 0 and 525600
    when 'follow_up'            then offset_minutes is not null and offset_minutes between 0 and 525600
    else offset_minutes is null
  end
  and (key = 'appointment_reminder' or reminder_offsets_minutes is null));
-- the gift card code is only ever delivered by email (money 0066)
alter table public.message_templates add constraint message_templates_gift_card_email
  check (key <> 'gift_card_delivery' or channel = 'email');

-- Per-service maintenance follow-ups ("time for your next ceramic top-up"):
-- up to 4 per service and channel, sent offset_days after a completed job
-- that included the service (0086). Marketing: the customer's opt-in on the
-- channel is required (and re-checked at send time).
create table public.service_followups (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  service_id   uuid not null,
  channel      public.message_channel not null,
  offset_days  integer not null check (offset_days between 1 and 1095),
  subject      text,
  body         text not null,
  enabled      boolean not null default true,
  sort         integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint service_followups_shop_id_id_key unique (shop_id, id),
  constraint service_followups_service_fk foreign key (shop_id, service_id)
    references public.services (shop_id, id) on delete cascade,
  constraint service_followups_subject check (
    case channel when 'sms' then subject is null
                 else subject is not null and char_length(btrim(subject)) between 1 and 200 end),
  constraint service_followups_body check (
    char_length(btrim(body)) >= 1 and char_length(body) <= case channel when 'sms' then 1600 else 20000 end)
);
create index service_followups_shop_service_idx on public.service_followups (shop_id, service_id);

comment on table public.service_followups is
  'Per-service follow-up messages (P-4): offset_days after a completed job with the service. Wording uses the template placeholders plus {{rebook_link}}.';

create trigger service_followups_05_prevent_shop_change before update on public.service_followups
  for each row execute function public.prevent_shop_change();
create trigger service_followups_90_set_updated_at before update on public.service_followups
  for each row execute function public.set_updated_at();

alter table public.service_followups enable row level security;
create policy service_followups_select on public.service_followups for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy service_followups_insert on public.service_followups for insert to authenticated
  with check (public.is_shop_manager(shop_id));
create policy service_followups_update on public.service_followups for update to authenticated
  using (public.is_shop_manager(shop_id)) with check (public.is_shop_manager(shop_id));
create policy service_followups_delete on public.service_followups for delete to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.service_followups from anon;
revoke truncate, references, trigger on public.service_followups from authenticated;
grant select, insert, update, delete on public.service_followups to authenticated;

-- job_automation_log v2: reminders are logged per offset, per-service
-- follow-ups per (job, follow-up row). A shop with a single reminder (and
-- every row logged before P-4) has a null reminder_offset_minutes.
alter table public.job_automation_log
  add column reminder_offset_minutes  integer check (reminder_offset_minutes is null
                                                     or reminder_offset_minutes between -43200 and 0),
  add column service_followup_id      uuid,
  add constraint job_automation_log_service_followup_fk foreign key (shop_id, service_followup_id)
    references public.service_followups (shop_id, id) on delete cascade;
alter table public.job_automation_log drop constraint job_automation_log_key_check;
alter table public.job_automation_log add constraint job_automation_log_key_check
  check (key in ('appointment_reminder', 'review_request', 'follow_up', 'service_followup'));
alter table public.job_automation_log add constraint job_automation_log_service_followup
  check ((key = 'service_followup') = (service_followup_id is not null));
alter table public.job_automation_log add constraint job_automation_log_reminder_offset
  check (key = 'appointment_reminder' or reminder_offset_minutes is null);
drop index public.job_automation_log_once;
create unique index job_automation_log_once on public.job_automation_log (job_id, key)
  where key in ('review_request', 'follow_up');
drop index public.job_automation_log_reminder_once;
create unique index job_automation_log_reminder_once
  on public.job_automation_log (job_id, scheduled_for, customer_id, reminder_offset_minutes) nulls not distinct
  where key = 'appointment_reminder';
create unique index job_automation_log_service_followup_once on public.job_automation_log (job_id, service_followup_id)
  where key = 'service_followup';
create index job_automation_log_shop_service_followup_idx on public.job_automation_log (shop_id, service_followup_id)
  where service_followup_id is not null;

comment on column public.job_automation_log.reminder_offset_minutes is
  'appointment_reminder: which reminder offset this row is for (null = a single-reminder shop / logged before P-4; see comms_reminder_log_covers, 0086).';

-- ===========================================================================
-- P-5 CSV import
-- ===========================================================================
create table public.import_batches (
  id             uuid primary key default gen_random_uuid(),
  shop_id        uuid not null references public.shops (id) on delete cascade,
  kind           text not null check (kind in ('customers', 'services')),
  status         text not null check (status in ('committed', 'failed')),
  file_name      text check (file_name is null or char_length(file_name) <= 255),
  row_count      integer not null default 0 check (row_count >= 0),
  created_count  integer not null default 0 check (created_count >= 0),
  updated_count  integer not null default 0 check (updated_count >= 0),
  skipped_count  integer not null default 0 check (skipped_count >= 0),
  error_count    integer not null default 0 check (error_count >= 0),
  errors         jsonb not null default '[]'
                   check (jsonb_typeof(errors) = 'array' and jsonb_array_length(errors) <= 1000),
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint import_batches_shop_id_id_key unique (shop_id, id)
);
create index import_batches_shop_created_idx on public.import_batches (shop_id, created_at desc);
create index import_batches_created_by_idx on public.import_batches (created_by);

comment on table public.import_batches is
  'One row per committed CSV import (import_customers / import_services, 0087); chunks of the same file accumulate. Managers read it.';

create trigger import_batches_05_prevent_shop_change before update on public.import_batches
  for each row execute function public.prevent_shop_change();
create trigger import_batches_90_set_updated_at before update on public.import_batches
  for each row execute function public.set_updated_at();

alter table public.import_batches enable row level security;
create policy import_batches_select on public.import_batches for select to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.import_batches from anon;
revoke insert, update, delete, truncate, references, trigger on public.import_batches from authenticated;

-- ===========================================================================
-- P-9 custom fields, booking questions, lead forms
-- ===========================================================================
create table public.custom_fields (
  id                 uuid primary key default gen_random_uuid(),
  shop_id            uuid not null references public.shops (id) on delete cascade,
  entity             public.custom_field_entity not null,
  key                text not null check (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  label              text not null check (char_length(btrim(label)) between 1 and 120),
  type               public.custom_field_type not null,
  options            text[] not null default '{}',
  help_text          text check (help_text is null or char_length(help_text) <= 300),
  required           boolean not null default false,
  show_in_booking    boolean not null default false,
  show_in_lead_form  boolean not null default false,
  location_scope     public.location_type,
  sort               integer not null default 0,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint custom_fields_shop_id_id_key unique (shop_id, id),
  constraint custom_fields_shop_entity_key_key unique (shop_id, entity, key),
  constraint custom_fields_options check (public.comms_custom_field_options_valid(type, options)),
  constraint custom_fields_booking_job check (not show_in_booking or entity = 'job'),
  constraint custom_fields_lead_form_customer check (not show_in_lead_form or entity = 'customer'),
  constraint custom_fields_location_scope_job check (location_scope is null or entity = 'job')
);

comment on table public.custom_fields is
  'Shop-defined fields of customers / jobs (values in customers.custom_data / jobs.custom_data, validated by 0088). Job fields with show_in_booking are online booking questions.';

create trigger custom_fields_05_prevent_shop_change before update on public.custom_fields
  for each row execute function public.prevent_shop_change();
create trigger custom_fields_90_set_updated_at before update on public.custom_fields
  for each row execute function public.set_updated_at();

alter table public.custom_fields enable row level security;
-- technicians render job custom data, so every member reads the definitions
create policy custom_fields_select on public.custom_fields for select to authenticated
  using (public.is_shop_member(shop_id));
create policy custom_fields_insert on public.custom_fields for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy custom_fields_update on public.custom_fields for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy custom_fields_delete on public.custom_fields for delete to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.custom_fields from anon;
revoke truncate, references, trigger on public.custom_fields from authenticated;
grant select, insert, update, delete on public.custom_fields to authenticated;

-- customers.custom_data: {field key: value} of the shop's customer fields
-- (validated by customers_85_custom_data, 0088). jobs.custom_data exists
-- since sched 0050.
alter table public.customers
  add column custom_data jsonb not null default '{}'
    constraint customers_custom_data_object check (jsonb_typeof(custom_data) = 'object');

comment on column public.customers.custom_data is
  'Values of the shop''s customer custom fields {key: value} (validated against custom_fields, 0088).';

-- Public lead-capture forms (/lead/<token>).
create table public.lead_forms (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops (id) on delete cascade,
  token            uuid not null default gen_random_uuid(),
  name             text not null check (char_length(btrim(name)) between 1 and 120),
  headline         text check (headline is null or char_length(headline) <= 200),
  intro            text check (intro is null or char_length(intro) <= 2000),
  default_source   public.customer_source not null default 'other',
  field_ids        uuid[] not null default '{}'
                     check (cardinality(field_ids) <= 30 and array_position(field_ids, null) is null),
  ask_vehicle      boolean not null default true,
  ask_message      boolean not null default true,
  success_message  text check (success_message is null or char_length(success_message) <= 500),
  notify_staff     boolean not null default true,
  auto_reply       boolean not null default false,
  active           boolean not null default true,
  archived_at      timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint lead_forms_shop_id_id_key unique (shop_id, id),
  constraint lead_forms_token_key unique (token)
);

comment on table public.lead_forms is
  'Public lead-capture forms (public_get_lead_form / public_submit_lead by token). field_ids = customer custom fields asked on the form.';

create trigger lead_forms_05_prevent_shop_change before update on public.lead_forms
  for each row execute function public.prevent_shop_change();
create trigger lead_forms_90_set_updated_at before update on public.lead_forms
  for each row execute function public.set_updated_at();

alter table public.lead_forms enable row level security;
create policy lead_forms_select on public.lead_forms for select to authenticated
  using (public.is_shop_manager(shop_id));
create policy lead_forms_insert on public.lead_forms for insert to authenticated
  with check (public.is_shop_admin(shop_id));
create policy lead_forms_update on public.lead_forms for update to authenticated
  using (public.is_shop_admin(shop_id)) with check (public.is_shop_admin(shop_id));
create policy lead_forms_delete on public.lead_forms for delete to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.lead_forms from anon;
revoke truncate, references, trigger on public.lead_forms from authenticated;
grant select, insert, update, delete on public.lead_forms to authenticated;

-- Every submission of a lead form (written only by public_submit_lead).
-- vehicle_info keeps the vehicle the visitor described ({year, make,
-- model}) also when they matched an existing customer, whose records a
-- public form never changes (vehicle_id is set only for a new customer).
create table public.lead_submissions (
  id                uuid primary key default gen_random_uuid(),
  shop_id           uuid not null references public.shops (id) on delete cascade,
  lead_form_id      uuid,
  customer_id       uuid not null,
  vehicle_id        uuid,
  vehicle_info      jsonb check (vehicle_info is null or jsonb_typeof(vehicle_info) = 'object'),
  answers           jsonb not null default '{}' check (jsonb_typeof(answers) = 'object'),
  message           text check (message is null or char_length(message) <= 5000),
  matched_existing  boolean not null,
  signer_ip         inet,
  created_at        timestamptz not null default now(),
  constraint lead_submissions_shop_id_id_key unique (shop_id, id),
  constraint lead_submissions_form_fk foreign key (shop_id, lead_form_id)
    references public.lead_forms (shop_id, id) on delete set null (lead_form_id),
  constraint lead_submissions_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete cascade,
  constraint lead_submissions_vehicle_fk foreign key (shop_id, vehicle_id)
    references public.vehicles (shop_id, id) on delete set null (vehicle_id)
);
create index lead_submissions_shop_form_idx on public.lead_submissions (shop_id, lead_form_id, created_at desc);
create index lead_submissions_shop_customer_idx on public.lead_submissions (shop_id, customer_id);
create index lead_submissions_shop_vehicle_idx on public.lead_submissions (shop_id, vehicle_id) where vehicle_id is not null;
create index lead_submissions_shop_created_idx on public.lead_submissions (shop_id, created_at desc);

comment on table public.lead_submissions is
  'Lead form submissions (public_submit_lead). Managers read them; a matched existing customer is never modified by a submission.';

alter table public.lead_submissions enable row level security;
create policy lead_submissions_select on public.lead_submissions for select to authenticated
  using (public.is_shop_manager(shop_id));
revoke all on public.lead_submissions from anon;
revoke insert, update, delete, truncate, references, trigger on public.lead_submissions from authenticated;

-- ===========================================================================
-- P-10 booking page tracking (no PII; public_shop_profile returns them
-- while online booking is on)
-- ===========================================================================
alter table public.booking_settings
  add column meta_pixel_id       text check (meta_pixel_id is null or meta_pixel_id ~ '^[0-9]{5,20}$'),
  add column ga4_measurement_id  text check (ga4_measurement_id is null or ga4_measurement_id ~ '^G-[A-Z0-9]{4,16}$');

comment on column public.booking_settings.meta_pixel_id is 'Meta (Facebook) Pixel id loaded on the public booking page.';
comment on column public.booking_settings.ga4_measurement_id is 'Google Analytics 4 measurement id (G-XXXX) loaded on the public booking page.';

-- ===========================================================================
-- P-14 self-serve SMS numbers: provisioning state of shop_sms_numbers
-- (0033). RLS unchanged: owners/admins read their rows, service_role writes.
-- A row with twilio_number_sid is a number the platform bought for the shop
-- (at most one per shop); null = bound by support by hand.
-- ===========================================================================
alter table public.shop_sms_numbers
  add column twilio_number_sid      text check (twilio_number_sid is null or twilio_number_sid ~ '^PN[0-9a-fA-F]{32}$'),
  add column messaging_service_sid  text check (messaging_service_sid is null or messaging_service_sid ~ '^MG[0-9a-fA-F]{32}$'),
  add column kind                   text check (kind is null or kind in ('tollfree', 'local')),
  add column verification_status    text not null default 'not_started'
                                      check (verification_status in ('not_started', 'pending', 'in_review', 'approved', 'rejected')),
  add column verification_sid       text check (verification_sid is null or char_length(verification_sid) <= 64),
  add column rejection_reason       text check (rejection_reason is null or char_length(rejection_reason) <= 1000),
  add column business_info          jsonb not null default '{}'
                                      check (jsonb_typeof(business_info) = 'object' and octet_length(business_info::text) <= 20000),
  add column last_checked_at        timestamptz,
  add column updated_at             timestamptz not null default now();
alter table public.shop_sms_numbers add constraint shop_sms_numbers_twilio_number_sid_key unique (twilio_number_sid);
create unique index shop_sms_numbers_one_provisioned on public.shop_sms_numbers (shop_id) where twilio_number_sid is not null;

comment on column public.shop_sms_numbers.business_info is
  'Business details submitted for toll-free / 10DLC verification (legal name, website, address, contact, use case, sample message, opt-in description). Never secrets.';

create trigger shop_sms_numbers_90_set_updated_at before update on public.shop_sms_numbers
  for each row execute function public.set_updated_at();

-- ===========================================================================
-- P-27 outbound webhooks
-- ===========================================================================
create table public.webhook_endpoints (
  id                    uuid primary key default gen_random_uuid(),
  shop_id               uuid not null references public.shops (id) on delete cascade,
  url                   text not null check (url ~ '^https://[^[:space:]]+$' and char_length(url) <= 2000),
  description           text check (description is null or char_length(description) <= 200),
  events                text[] not null
                          check (cardinality(events) between 1 and 8 and array_position(events, null) is null
                                 and events <@ array['booking_created', 'booking_confirmed', 'on_the_way', 'job_completed',
                                                     'payment_succeeded', 'form_signed', 'membership_activated']),
  secret                text not null check (secret ~ '^whsec_[0-9a-f]{64}$'),
  active                boolean not null default true,
  consecutive_failures  integer not null default 0 check (consecutive_failures >= 0),
  disabled_at           timestamptz,
  created_by            uuid references auth.users (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint webhook_endpoints_shop_id_id_key unique (shop_id, id)
);
create index webhook_endpoints_shop_idx on public.webhook_endpoints (shop_id);
create index webhook_endpoints_created_by_idx on public.webhook_endpoints (created_by);

comment on table public.webhook_endpoints is
  'Outbound webhook endpoints (0089). The signing secret is never readable by API clients (shown once by create / rotate).';

create trigger webhook_endpoints_05_prevent_shop_change before update on public.webhook_endpoints
  for each row execute function public.prevent_shop_change();
create trigger webhook_endpoints_90_set_updated_at before update on public.webhook_endpoints
  for each row execute function public.set_updated_at();

alter table public.webhook_endpoints enable row level security;
create policy webhook_endpoints_select on public.webhook_endpoints for select to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.webhook_endpoints from anon, authenticated;
grant select (id, shop_id, url, description, events, active, consecutive_failures, disabled_at, created_by,
              created_at, updated_at) on public.webhook_endpoints to authenticated;

create table public.webhook_deliveries (
  id                    uuid primary key default gen_random_uuid(),
  shop_id               uuid not null references public.shops (id) on delete cascade,
  endpoint_id           uuid not null,
  integration_event_id  uuid,
  event                 text not null
                          check (event in ('booking_created', 'booking_confirmed', 'on_the_way', 'job_completed',
                                           'payment_succeeded', 'form_signed', 'membership_activated', 'test')),
  payload               jsonb not null check (jsonb_typeof(payload) = 'object'),
  status                text not null default 'pending' check (status in ('pending', 'delivering', 'succeeded', 'dead')),
  attempts              smallint not null default 0 check (attempts between 0 and 100),
  next_attempt_at       timestamptz not null default now(),
  last_status_code      integer check (last_status_code is null or last_status_code between 0 and 999),
  last_error            text check (last_error is null or char_length(last_error) <= 1000),
  delivered_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint webhook_deliveries_shop_id_id_key unique (shop_id, id),
  constraint webhook_deliveries_once unique (endpoint_id, integration_event_id),
  constraint webhook_deliveries_endpoint_fk foreign key (shop_id, endpoint_id)
    references public.webhook_endpoints (shop_id, id) on delete cascade,
  constraint webhook_deliveries_event_fk foreign key (shop_id, integration_event_id)
    references public.integration_events (shop_id, id) on delete cascade
);
create index webhook_deliveries_due_idx on public.webhook_deliveries (next_attempt_at) where status = 'pending';
create index webhook_deliveries_delivering_idx on public.webhook_deliveries (updated_at) where status = 'delivering';
create index webhook_deliveries_shop_endpoint_idx on public.webhook_deliveries (shop_id, endpoint_id, created_at desc);
create index webhook_deliveries_shop_event_idx on public.webhook_deliveries (shop_id, integration_event_id)
  where integration_event_id is not null;

comment on table public.webhook_deliveries is
  'One delivery per (endpoint, integration event) + test deliveries; claimed and settled by the webhooks worker (service_role).';

create trigger webhook_deliveries_05_prevent_shop_change before update on public.webhook_deliveries
  for each row execute function public.prevent_shop_change();
create trigger webhook_deliveries_90_set_updated_at before update on public.webhook_deliveries
  for each row execute function public.set_updated_at();

alter table public.webhook_deliveries enable row level security;
create policy webhook_deliveries_select on public.webhook_deliveries for select to authenticated
  using (public.is_shop_admin(shop_id));
revoke all on public.webhook_deliveries from anon;
revoke insert, update, delete, truncate, references, trigger on public.webhook_deliveries from authenticated;

-- ===========================================================================
-- P-32 staff tasks
-- ===========================================================================
create table public.tasks (
  id                  uuid primary key default gen_random_uuid(),
  shop_id             uuid not null references public.shops (id) on delete cascade,
  title               text not null check (char_length(btrim(title)) between 1 and 200),
  notes               text check (notes is null or char_length(notes) <= 5000),
  assignee_member_id  uuid,
  due_at              timestamptz,
  customer_id         uuid,
  job_id              uuid,
  done_at             timestamptz,
  done_by             uuid references auth.users (id) on delete set null,
  due_notified_at     timestamptz,
  created_by          uuid references auth.users (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint tasks_shop_id_id_key unique (shop_id, id),
  constraint tasks_assignee_fk foreign key (shop_id, assignee_member_id)
    references public.shop_members (shop_id, id) on delete set null (assignee_member_id),
  constraint tasks_customer_fk foreign key (shop_id, customer_id)
    references public.customers (shop_id, id) on delete set null (customer_id),
  constraint tasks_job_fk foreign key (shop_id, job_id)
    references public.jobs (shop_id, id) on delete set null (job_id)
);
create index tasks_shop_assignee_idx on public.tasks (shop_id, assignee_member_id) where done_at is null;
create index tasks_shop_customer_idx on public.tasks (shop_id, customer_id) where customer_id is not null;
create index tasks_shop_job_idx on public.tasks (shop_id, job_id) where job_id is not null;
create index tasks_shop_created_idx on public.tasks (shop_id, created_at desc);
create index tasks_due_idx on public.tasks (due_at) where done_at is null and due_notified_at is null and due_at is not null;
create index tasks_created_by_idx on public.tasks (created_by);
create index tasks_done_by_idx on public.tasks (done_by);

comment on table public.tasks is
  'Staff to-dos with an optional assignee, due time, customer and job (0084). Managers see all; others their own / assigned.';

create trigger tasks_05_prevent_shop_change before update on public.tasks
  for each row execute function public.prevent_shop_change();
create trigger tasks_90_set_updated_at before update on public.tasks
  for each row execute function public.set_updated_at();

alter table public.tasks enable row level security;
create policy tasks_select on public.tasks for select to authenticated
  using (public.is_shop_manager(shop_id)
         or (public.is_shop_member(shop_id)
             and (public.is_own_member(assignee_member_id) or created_by = auth.uid())));
-- non-managers: tasks for themselves (or nobody), no customer, and only
-- jobs they work (tasks_80_guard stamps created_by before this runs)
create policy tasks_insert on public.tasks for insert to authenticated
  with check (public.is_shop_manager(shop_id)
              or (public.is_shop_member(shop_id)
                  and (assignee_member_id is null or public.is_own_member(assignee_member_id))
                  and customer_id is null
                  and (job_id is null or public.is_assigned_to_job(job_id))));
create policy tasks_update on public.tasks for update to authenticated
  using (public.is_shop_manager(shop_id)
         or (public.is_shop_member(shop_id)
             and (public.is_own_member(assignee_member_id) or created_by = auth.uid())))
  with check (public.is_shop_manager(shop_id)
              or (public.is_shop_member(shop_id)
                  and (public.is_own_member(assignee_member_id) or created_by = auth.uid())));
create policy tasks_delete on public.tasks for delete to authenticated
  using (public.is_shop_manager(shop_id) or (public.is_shop_member(shop_id) and created_by = auth.uid()));
revoke all on public.tasks from anon;
revoke truncate, references, trigger on public.tasks from authenticated;
grant select, insert, update, delete on public.tasks to authenticated;

-- Realtime: task lists update live (subscribers only receive rows their
-- RLS lets them read). Idempotent.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_catalog.pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tasks') then
    alter publication supabase_realtime add table public.tasks;
  end if;
end
$$;
