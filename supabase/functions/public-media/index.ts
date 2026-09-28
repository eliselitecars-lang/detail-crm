/**
 * public-media — short-lived signed URLs for the photos, videos and
 * documents customers may see (P-8 job reports, P-25 documents, P-30
 * videos). verify_jwt = false: two actions are public by link token, one is
 * for signed-in portal clients (JWT verified here).
 *
 *   job_report         {token}        PUBLIC (job_reports.token, the /r/<token> link)
 *                                     -> job_report_media(token)
 *   booking_documents  {token}        PUBLIC (the booking link's jobs.public_token)
 *                                     -> booking_document_media(token)
 *   portal_document    {document_id}  signed-in client -> portal_document_media
 *                                     (document id, caller) -> {url}
 *
 * The client never names a bucket or a storage path: the database decides
 * which objects the credential may see (service_role RPCs) and this function
 * only signs them (Storage API, service role) for EXPIRES_IN seconds.
 * Items whose object is missing are left out (logged).
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireUser } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { HttpError } from "../_shared/errors.ts";
import { createHandler } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { publicToken, uuid } from "../_shared/schemas.ts";
import { adminClient, type SupabaseClient } from "../_shared/supabase.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
}

/** Signed URL lifetime (seconds). */
export const EXPIRES_IN = 600;
/** Paths per Storage sign request. */
const SIGN_CHUNK = 100;

export type MediaKind = "photo" | "video" | "poster" | "mark_photo" | "document";

export interface MediaItem {
  ref_id: string;
  kind: MediaKind;
  url: string;
}

export interface MediaListResponse {
  expires_in: number;
  items: MediaItem[];
}

export interface SingleMediaResponse {
  expires_in: number;
  url: string;
}

interface MediaRow {
  ref_id: string;
  kind?: string;
  bucket: string;
  path: string;
}

const KINDS: ReadonlySet<string> = new Set(["photo", "video", "poster", "mark_photo", "document"]);

export const tokenInput = z.object({ token: publicToken }).strict();
export const portalDocumentInput = z.object({ document_id: uuid }).strict();

function dbFailure(what: string, error: { message?: string; code?: string }): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

/** Storage's signed path -> an absolute URL on the public API origin. */
function publicSignedUrl(env: Env, signedPath: string): string {
  return encodeURI(`${env.publicSupabaseUrl()}/storage/v1${signedPath}`);
}

/**
 * Signs every (bucket, path) of `rows`; returns a map "bucket\npath" -> URL.
 * Objects Storage cannot sign (deleted meanwhile) are absent from the map.
 */
async function signAll(
  admin: SupabaseClient,
  env: Env,
  rows: readonly { bucket: string; path: string }[],
  log: Logger,
): Promise<Map<string, string>> {
  const byBucket = new Map<string, Set<string>>();
  for (const row of rows) {
    const paths = byBucket.get(row.bucket) ?? new Set<string>();
    paths.add(row.path);
    byBucket.set(row.bucket, paths);
  }
  const urls = new Map<string, string>();
  for (const [bucket, pathSet] of byBucket) {
    const paths = [...pathSet];
    for (let i = 0; i < paths.length; i += SIGN_CHUNK) {
      const chunk = paths.slice(i, i + SIGN_CHUNK);
      const { data, error } = await admin.storage.from(bucket).createSignedUrls(chunk, EXPIRES_IN);
      if (error) {
        throw new Error(`storage sign (${bucket}) failed: ${error.message}`, { cause: error });
      }
      for (const datum of data ?? []) {
        const signed = (datum as { signedURL?: unknown }).signedURL;
        if (datum.path && typeof signed === "string" && !datum.error) {
          urls.set(`${bucket}\n${datum.path}`, publicSignedUrl(env, signed));
        } else if (datum.error) {
          log.warn("media_sign_skipped", { bucket, error: datum.error });
        }
      }
    }
  }
  return urls;
}

/** Is there a live report for this token? (job_report_media alone cannot tell "none".) */
async function liveReport(admin: SupabaseClient, token: string): Promise<boolean> {
  const { data, error } = await admin
    .from("job_reports")
    .select("id")
    .eq("token", token)
    .is("revoked_at", null)
    .limit(1);
  if (error) throw dbFailure("job_reports", error);
  return Array.isArray(data) && data.length > 0;
}

/** Does a booking link with this token exist? */
async function knownBooking(admin: SupabaseClient, token: string): Promise<boolean> {
  const { data, error } = await admin.from("jobs").select("id").eq("public_token", token).limit(1);
  if (error) throw dbFailure("jobs", error);
  return Array.isArray(data) && data.length > 0;
}

/** Media rows of job_report_media / booking_document_media. */
function mediaRows(data: unknown): MediaRow[] {
  return ((Array.isArray(data) ? data : []) as MediaRow[]).filter((row) =>
    typeof row.ref_id === "string" && typeof row.bucket === "string" &&
    typeof row.path === "string" && row.path !== ""
  );
}

/** Signs the rows' objects; `kindOf` names each item (documents: always "document"). */
async function signedList(
  admin: SupabaseClient,
  env: Env,
  rows: MediaRow[],
  kindOf: (row: MediaRow) => string,
  log: Logger,
): Promise<MediaListResponse> {
  const urls = await signAll(admin, env, rows, log);
  const items: MediaItem[] = [];
  for (const row of rows) {
    const url = urls.get(`${row.bucket}\n${row.path}`);
    const kind = kindOf(row);
    if (!url || !KINDS.has(kind)) continue;
    items.push({ ref_id: row.ref_id, kind: kind as MediaKind, url });
  }
  return { expires_in: EXPIRES_IN, items };
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const router = createActionRouter({
    job_report: jsonAction(tokenInput, async (input, ctx): Promise<MediaListResponse> => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const token = input.token.toLowerCase();
      if (!(await liveReport(admin, token))) {
        throw new HttpError("not_found", "This report link is no longer available.");
      }
      const { data, error } = await admin.rpc("job_report_media", { p_token: token });
      if (error) throw dbFailure("job_report_media", error);
      return await signedList(admin, ctx.env, mediaRows(data), (row) => row.kind ?? "", ctx.log);
    }),

    booking_documents: jsonAction(tokenInput, async (input, ctx): Promise<MediaListResponse> => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const token = input.token.toLowerCase();
      if (!(await knownBooking(admin, token))) {
        throw new HttpError("not_found", "Booking not found.");
      }
      const { data, error } = await admin.rpc("booking_document_media", { p_token: token });
      if (error) throw dbFailure("booking_document_media", error);
      return await signedList(admin, ctx.env, mediaRows(data), () => "document", ctx.log);
    }),

    portal_document: jsonAction(
      portalDocumentInput,
      async (input, ctx): Promise<SingleMediaResponse> => {
        const admin = adminClient({ env: deps.env, fetch: deps.fetch });
        const caller = await requireUser(ctx.req, { admin });
        const { data, error } = await admin.rpc("portal_document_media", {
          p_document_id: input.document_id,
          p_user_id: caller.id,
        });
        if (error) throw dbFailure("portal_document_media", error);
        const media = data as { bucket?: unknown; path?: unknown } | null;
        if (!media || typeof media.bucket !== "string" || typeof media.path !== "string") {
          throw new HttpError("not_found", "Document not found.");
        }
        const urls = await signAll(
          admin,
          ctx.env,
          [{ bucket: media.bucket, path: media.path }],
          ctx.log,
        );
        const url = urls.get(`${media.bucket}\n${media.path}`);
        if (!url) throw new HttpError("not_found", "Document not found.");
        return { expires_in: EXPIRES_IN, url };
      },
    ),
  });

  return createHandler(
    { name: "public-media", env: deps.env, logger: deps.logger },
    (req, ctx) => router(req, ctx),
  );
}

if (import.meta.main) Deno.serve(makeHandler());
