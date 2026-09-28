/**
 * pdf — quote and invoice PDFs (P-34). verify_jwt = false: two actions are
 * public by the document's own link token, one verifies the staff JWT.
 *
 *   quote           {token}           PUBLIC (quotes.public_token; drafts 404)
 *   invoice         {token}           PUBLIC (invoices.public_token; drafts 404)
 *   staff_document  {shop_id, kind: "quote" | "invoice", id}
 *                   staff: owner/admin/manager, or (invoices only) a technician
 *                   who may collect payment for the invoice's job
 *                   (can_collect_for_invoice). Drafts are rendered marked DRAFT.
 *
 * The public actions also answer GET ?action=quote&token=<uuid> (and
 * ?action=invoice) so a plain link opens the PDF in the browser. The data
 * is exactly what the public /q and /i pages show (money_public_quote_json /
 * money_public_invoice_json, service role); amounts are printed as returned,
 * never recomputed. The shop logo is embedded when it is a PNG or JPEG of
 * at most 1 MB in the public shop-assets bucket.
 *
 * 200 application/pdf, Content-Disposition: inline; filename="quote-<n>.pdf"
 * (or invoice-<n>.pdf), Cache-Control: private, no-store.
 */
import { z } from "zod";
import { createActionRouter, jsonAction } from "../_shared/actions.ts";
import { requireShopRole, requireUser, ROLES } from "../_shared/auth.ts";
import type { Env } from "../_shared/env.ts";
import { errors, HttpError } from "../_shared/errors.ts";
import { createHandler, validate } from "../_shared/http.ts";
import type { Logger } from "../_shared/log.ts";
import { imageKind } from "../_shared/pdf.ts";
import { publicToken, uuid } from "../_shared/schemas.ts";
import { adminClient, type SupabaseClient, userClient } from "../_shared/supabase.ts";
import { type InvoiceJson, type QuoteJson, renderInvoicePdf, renderQuotePdf } from "./render.ts";

export interface Deps {
  env?: Env;
  fetch?: typeof fetch;
  logger?: Logger;
  now?: () => Date;
}

export const MAX_LOGO_BYTES = 1024 * 1024;
const LOGO_TIMEOUT_MS = 5_000;

export const tokenInput = z.object({ token: publicToken }).strict();
export const staffDocumentInput = z.object({
  shop_id: uuid,
  kind: z.enum(["quote", "invoice"]),
  id: uuid,
}).strict();

type Kind = "quote" | "invoice";

interface DocRow {
  id: string;
  shop_id: string;
  status: string;
}

function dbFailure(what: string, error: { message?: string; code?: string }): Error {
  return new Error(`${what} failed: ${error.code ?? ""} ${error.message ?? ""}`.trim(), {
    cause: error,
  });
}

async function findDocument(
  admin: SupabaseClient,
  kind: Kind,
  column: "public_token" | "id",
  value: string,
  shopId?: string,
): Promise<DocRow | null> {
  let query = admin.from(kind === "quote" ? "quotes" : "invoices").select("id, shop_id, status")
    .eq(column, value);
  if (shopId) query = query.eq("shop_id", shopId);
  const { data, error } = await query.maybeSingle();
  if (error) throw dbFailure(`${kind} lookup`, error);
  return (data as DocRow | null) ?? null;
}

async function documentJson(
  admin: SupabaseClient,
  kind: Kind,
  id: string,
): Promise<QuoteJson | InvoiceJson> {
  const { data, error } = kind === "quote"
    ? await admin.rpc("money_public_quote_json", { p_quote_id: id })
    : await admin.rpc("money_public_invoice_json", { p_invoice_id: id });
  if (error) throw dbFailure(`money_public_${kind}_json`, error);
  if (!data || typeof data !== "object") throw errors.notFound("Document not found.");
  return data as QuoteJson | InvoiceJson;
}

/** The shop logo when it is a small PNG/JPEG in the public bucket; null otherwise. */
async function loadLogo(
  env: Env,
  fetchFn: typeof fetch,
  logoPath: string | null | undefined,
  log: Logger,
): Promise<Uint8Array | null> {
  if (!logoPath || logoPath.includes("..")) return null;
  const path = logoPath.split("/").map(encodeURIComponent).join("/");
  const url = `${env.supabase().url}/storage/v1/object/public/shop-assets/${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), LOGO_TIMEOUT_MS);
  try {
    const response = await fetchFn(url, { signal: controller.signal });
    if (!response.ok || !response.body) {
      await response.body?.cancel();
      return null;
    }
    const declared = Number(response.headers.get("content-length") ?? "0");
    if (declared > MAX_LOGO_BYTES) {
      await response.body.cancel();
      return null;
    }
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_LOGO_BYTES) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return imageKind(bytes) ? bytes : null;
  } catch (err) {
    log.warn("pdf_logo_unavailable", { error: err });
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function pdfResponse(bytes: Uint8Array, filename: string): Response {
  return new Response(bytes as Uint8Array<ArrayBuffer>, {
    status: 200,
    headers: {
      "Content-Type": "application/pdf",
      "Content-Disposition": `inline; filename="${filename}"`,
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export function makeHandler(deps: Deps = {}): (req: Request) => Promise<Response> {
  const now = deps.now ?? (() => new Date());

  const render = async (
    admin: SupabaseClient,
    env: Env,
    log: Logger,
    kind: Kind,
    doc: DocRow,
    draft: boolean,
  ): Promise<Response> => {
    const data = await documentJson(admin, kind, doc.id);
    const logo = await loadLogo(env, deps.fetch ?? fetch, data.shop?.logo_path, log);
    const options = { draft, logo, now: now() };
    const bytes = kind === "quote"
      ? await renderQuotePdf(data as QuoteJson, options)
      : await renderInvoicePdf(data as InvoiceJson, options);
    const number = kind === "quote"
      ? (data as QuoteJson).quote?.number
      : (data as InvoiceJson).invoice?.number;
    return pdfResponse(bytes, `${kind}-${typeof number === "number" ? number : "document"}.pdf`);
  };

  const publicDocument = async (
    kind: Kind,
    token: string,
    ctx: { env: Env; log: Logger },
  ): Promise<Response> => {
    const admin = adminClient({ env: deps.env, fetch: deps.fetch });
    const doc = await findDocument(admin, kind, "public_token", token.toLowerCase());
    // A draft has no public link yet (the /q and /i pages answer the same).
    if (!doc || doc.status === "draft") {
      throw errors.notFound(kind === "quote" ? "Quote not found." : "Invoice not found.");
    }
    return await render(admin, ctx.env, ctx.log, kind, doc, false);
  };

  const router = createActionRouter({
    quote: jsonAction(tokenInput, (input, ctx) => publicDocument("quote", input.token, ctx)),
    invoice: jsonAction(tokenInput, (input, ctx) => publicDocument("invoice", input.token, ctx)),
    staff_document: jsonAction(staffDocumentInput, async (input, ctx) => {
      const admin = adminClient({ env: deps.env, fetch: deps.fetch });
      const caller = await requireUser(ctx.req, { admin });
      const membership = await requireShopRole(admin, caller, input.shop_id, ROLES.anyStaff);
      const doc = await findDocument(admin, input.kind, "id", input.id, input.shop_id);
      if (!doc) {
        throw errors.notFound(input.kind === "quote" ? "Quote not found." : "Invoice not found.");
      }
      const manager = (ROLES.managerPlus as readonly string[]).includes(membership.role);
      if (!manager) {
        if (input.kind === "quote") {
          throw errors.forbidden("Your role does not allow viewing quotes.");
        }
        // Technicians: only invoices they may collect on (their job, shop setting on).
        const user = userClient(ctx.req, { env: deps.env, fetch: deps.fetch });
        const { data, error } = await user.rpc("can_collect_for_invoice", {
          p_shop_id: input.shop_id,
          p_invoice_id: doc.id,
        });
        if (error) throw dbFailure("can_collect_for_invoice", error);
        if (data !== true) throw errors.forbidden("You can only open invoices for your jobs.");
      }
      return await render(admin, ctx.env, ctx.log, input.kind, doc, doc.status === "draft");
    }),
  });

  return createHandler(
    { name: "pdf", env: deps.env, logger: deps.logger, methods: ["GET", "POST"] },
    (req, ctx) => {
      if (req.method === "GET") {
        const params = new URL(req.url).searchParams;
        const action = params.get("action");
        if (action !== "quote" && action !== "invoice") {
          throw new HttpError("method_not_allowed", "Method not allowed.", {
            headers: { Allow: "POST, OPTIONS" },
          });
        }
        const input = validate(tokenInput, { token: params.get("token") ?? undefined });
        return publicDocument(action, input.token, ctx);
      }
      return router(req, ctx);
    },
  );
}

if (import.meta.main) Deno.serve(makeHandler());
