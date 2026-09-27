/**
 * `unsubscribe` — RFC 8058 one-click unsubscribe for campaign emails
 * (PUBLIC; the unguessable message id in `token` is the credential, exactly
 * like the /u/<message id> page, which calls the same public_unsubscribe).
 *
 * Campaign emails carry
 *   List-Unsubscribe: <…/functions/v1/messaging?action=unsubscribe&token=<message id>>
 *   List-Unsubscribe-Post: List-Unsubscribe=One-Click
 *
 *   POST  (mailbox provider, body "List-Unsubscribe=One-Click")
 *         -> public_unsubscribe(token): the customer's email opt-out
 *            (idempotent); 200 {unsubscribed: true}, 404 for an unknown token
 *   GET   (a mail client opening the link in a browser) -> 303 to the
 *         web /u/<token> page, which asks for confirmation. A GET never
 *         unsubscribes (link scanners and prefetchers follow GETs).
 *
 * The /u/:token page belongs to the web app (see supabase/setup/twilio.md,
 * "Campaign email unsubscribe"); this function cannot render it, because
 * Supabase serves text/html answers to GETs on *.supabase.co as text/plain.
 */
import { errors, HttpError } from "../_shared/errors.ts";
import { publicToken } from "../_shared/schemas.ts";
import { DbError, type Services } from "./lib.ts";

/** One-click POST bodies are a few bytes; never read more than this. */
const MAX_BODY_BYTES = 4 * 1024;

function tokenOf(req: Request): string {
  const parsed = publicToken.safeParse(new URL(req.url).searchParams.get("token"));
  if (!parsed.success) {
    throw new HttpError("validation_failed", "This unsubscribe link is invalid.", {
      details: { issues: [{ path: "token", message: "must be a link token" }] },
    });
  }
  return parsed.data.toLowerCase();
}

export async function unsubscribe(svc: Services, req: Request): Promise<Response | unknown> {
  const token = tokenOf(req);
  if (req.method === "GET") {
    return new Response(null, {
      status: 303,
      headers: {
        Location: `${svc.env.appBaseUrl()}/u/${encodeURIComponent(token)}`,
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
      },
    });
  }

  // The body ("List-Unsubscribe=One-Click", form or multipart) carries no
  // information we need; the POST itself is the one-click confirmation.
  const length = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    throw new HttpError("payload_too_large", "The request body is too large.");
  }
  await req.body?.cancel();

  const { data, error } = await svc.admin.rpc("public_unsubscribe", { p_token: token });
  if (error) throw new DbError("public_unsubscribe", error);
  if (data !== true) throw errors.notFound("This unsubscribe link is not valid.");
  svc.log.info("email_unsubscribed", { message_id: token, source: "one_click" });
  return { unsubscribed: true };
}
