-- ============================================================================
-- 0070 — Field operations v2 (range 0070-0079): enum additions only.
--
-- Migrations run with psql --single-transaction, and a value added with
-- ALTER TYPE ... ADD VALUE cannot be used in the transaction that added it,
-- so nothing in this file uses the new values; 0071+ may.
--
--   inventory_movement_kind   new type: the inventory ledger (P-28)
--     receive  stock received (+), optionally with its purchase cost
--     consume  materials used by a completed job (-), written by the server
--     adjust   manual correction (+/-)
--     count    stock count: the new absolute level, stored as the delta
--   notification_kind
--     low_stock                a product fell to its reorder level (P-28)
--     inspection_acknowledged  a customer signed a pre-inspection from the
--                              job report link (P-8)
--   message_template_key
--     job_report               "your job report is ready" with {{report_link}}
--                              (P-8; transactional; wording by comms 0083)
-- ============================================================================

create type public.inventory_movement_kind as enum ('receive', 'consume', 'adjust', 'count');

alter type public.notification_kind add value if not exists 'low_stock';
alter type public.notification_kind add value if not exists 'inspection_acknowledged';

alter type public.message_template_key add value if not exists 'job_report';
