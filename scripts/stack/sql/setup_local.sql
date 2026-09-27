-- ============================================================================
-- LOCAL real-stack platform setup (scripts/stack/up.sh substitutes
-- __APP_BASE_URL__). The local counterpart of supabase/setup/cron.sql, which
-- refuses non-https URLs and is meant for hosted projects.
--
-- * app_base_url: every customer link is built from it (SPEC; migration 0030).
-- * pg_cron / pg_net: created so the harness proves they exist on the real
--   image. Jobs are NOT scheduled: suites drive process_queue / purge / sweeps
--   explicitly (deterministic), and scripts/stack/verify_stack.mjs proves a
--   pg_net call reaches the functions with the cron secret.
-- Idempotent.
-- ============================================================================
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

select public.set_app_base_url('__APP_BASE_URL__');
