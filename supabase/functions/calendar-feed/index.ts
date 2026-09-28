/**
 * calendar-feed — a member's subscribed iCal (.ics) calendar (P-19; tokens
 * and events in migration 0055). verify_jwt = false: calendar apps send no
 * Supabase JWT; the unguessable token in the URL is the credential.
 *
 *   GET /functions/v1/calendar-feed?token=<uuid>
 *     -> calendar_feed_events(token) as service_role
 *     -> 200 text/calendar (RFC 5545, instants in UTC)
 *
 *   400 validation_failed   the token is missing or not a UUID
 *   404 not_found           unknown or revoked token, or a member who is no
 *                           longer active (the subscription stops updating)
 *
 * Calendar apps poll (Apple and Google every few hours at best); responses
 * may be cached privately for 5 minutes. The database decides what the
 * member may see and leaves out prices, phone numbers, emails and notes.
 * No CORS: this is fetched by calendar apps, never by the web app.
 */
import type { Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import { buildCalendar, type IcsEvent, type IcsStatus } from "../_shared/ics.ts";
import { isUuid } from "../_shared/ids.ts";
import type { Logger } from "../_shared/log.ts";
import { adminClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  now?: () => Date;
}

/** One event of calendar_feed_events (0055). */
interface FeedEvent {
  uid?: unknown;
  starts_at?: unknown;
  ends_at?: unknown;
  summary?: unknown;
  location?: unknown;
  description?: unknown;
  status?: unknown;
  updated_at?: unknown;
}

interface Feed {
  shop?: { name?: unknown; timezone?: unknown };
  member?: { display_name?: unknown };
  events?: unknown;
}

const STATUSES: ReadonlySet<string> = new Set(["CONFIRMED", "TENTATIVE", "CANCELLED"]);

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function date(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/** Maps the RPC's events; malformed rows are skipped (and counted). */
export function toIcsEvents(raw: unknown): { events: IcsEvent[]; skipped: number } {
  const list = Array.isArray(raw) ? raw as FeedEvent[] : [];
  const events: IcsEvent[] = [];
  let skipped = 0;
  for (const row of list) {
    const uid = text(row?.uid);
    const start = date(row?.starts_at);
    const end = date(row?.ends_at);
    if (!uid || !start || !end) {
      skipped += 1;
      continue;
    }
    const status = typeof row.status === "string" && STATUSES.has(row.status)
      ? row.status as IcsStatus
      : "CONFIRMED";
    events.push({
      uid,
      start,
      end,
      summary: text(row.summary) ?? "Busy",
      location: text(row.location),
      description: text(row.description),
      status,
      updatedAt: date(row.updated_at),
    });
  }
  return { events, skipped };
}

export function calendarName(feed: Feed): string {
  const shop = text(feed.shop?.name) ?? "Detail CRM";
  const member = text(feed.member?.display_name);
  return member ? `${shop} - ${member}` : shop;
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());
  return createHandler(
    { name: "calendar-feed", env: deps.env, logger: deps.logger, methods: ["GET"], cors: false },
    async (req, ctx) => {
      const token = new URL(req.url).searchParams.get("token");
      if (!isUuid(token)) {
        throw new HttpError("validation_failed", "Some fields are missing or invalid.", {
          details: { issues: [{ path: "token", message: "must be a calendar link token" }] },
        });
      }
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const { data, error } = await admin.rpc("calendar_feed_events", {
        p_token: token.toLowerCase(),
      });
      if (error) {
        throw new Error(`calendar_feed_events failed: ${error.code ?? ""} ${error.message}`, {
          cause: error,
        });
      }
      if (data === null || typeof data !== "object") {
        throw new HttpError("not_found", "This calendar link is no longer active.");
      }
      const feed = data as Feed;
      const { events, skipped } = toIcsEvents(feed.events);
      if (skipped > 0) ctx.log.warn("calendar_feed_events_skipped", { skipped });
      const body = buildCalendar({
        name: calendarName(feed),
        timezone: text(feed.shop?.timezone),
        events,
      }, now());
      return new Response(body, {
        status: 200,
        headers: {
          "Content-Type": "text/calendar; charset=utf-8",
          "Content-Disposition": 'inline; filename="calendar.ics"',
          "Cache-Control": "private, max-age=300",
          "X-Content-Type-Options": "nosniff",
        },
      });
    },
  );
}

if (import.meta.main) Deno.serve(makeHandler());
