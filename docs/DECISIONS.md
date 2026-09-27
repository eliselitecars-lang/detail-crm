# Decisions

- 2026-09-27 — Built from scratch (not forked from the Eli's Elite CRM), multi-tenant from day one, Supabase + Stripe Connect (Express, direct charges) + Twilio + Resend; web = Vite/React/TS; iOS = SwiftUI staff app; clients use the web portal.
- 2026-09-27 — Clients and anonymous visitors never get direct table RLS access; all their reads/writes go through curated SECURITY DEFINER RPCs so internal fields (internal notes, pay rates, Stripe ids) can't leak.
- 2026-09-27 — Each domain migration seeds its own per-shop defaults with an AFTER INSERT trigger on `shops`, so domain migrations stay independent.
