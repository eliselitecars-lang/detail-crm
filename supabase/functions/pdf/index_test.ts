import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { pdfText } from "../_shared/testing/pdf_text.ts";
import { emptyRequest, jsonRequest, responseJson } from "../_shared/testing/requests.ts";
import { LOGO_PNG } from "../_shared/testing/images.ts";
import { makeHandler } from "./index.ts";
import { INVOICE_JSON, QUOTE_JSON, SHOP_JSON } from "./test_fixtures.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OTHER_SHOP = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const MANAGER = "10000000-0000-4000-8000-000000000001";
const TECH = "10000000-0000-4000-8000-000000000002";
const OUTSIDER = "10000000-0000-4000-8000-000000000003";
const QUOTE = "20000000-0000-4000-8000-000000000001";
const DRAFT_QUOTE = "20000000-0000-4000-8000-000000000002";
const INVOICE = "30000000-0000-4000-8000-000000000001";
const DRAFT_INVOICE = "30000000-0000-4000-8000-000000000002";
const QUOTE_TOKEN = "40000000-0000-4000-8000-000000000001";
const DRAFT_QUOTE_TOKEN = "40000000-0000-4000-8000-000000000002";
const INVOICE_TOKEN = "40000000-0000-4000-8000-000000000003";
const DRAFT_INVOICE_TOKEN = "40000000-0000-4000-8000-000000000004";
const LOGO_URL = "https://fake-project.supabase.co/storage/v1/object/public/shop-assets/*";

function member(id: string, userId: string, role: string, shopId = SHOP): Row {
  return { id, shop_id: shopId, user_id: userId, role, display_name: role, active: true };
}

interface Setup {
  logoPath?: string | null;
  logo?: () => Response;
  techCanCollect?: boolean;
}

function setup(options: Setup = {}) {
  const shop = { ...SHOP_JSON, logo_path: options.logoPath ?? null };
  const db = new FakeSupabase({
    users: {
      "tok-manager": { id: MANAGER, email: "m@example.com" },
      "tok-tech": { id: TECH, email: "t@example.com" },
      "tok-outsider": { id: OUTSIDER, email: "o@example.com" },
    },
    tables: {
      shop_members: [
        member("50000000-0000-4000-8000-000000000001", MANAGER, "manager"),
        member("50000000-0000-4000-8000-000000000002", TECH, "technician"),
        member("50000000-0000-4000-8000-000000000003", OUTSIDER, "owner", OTHER_SHOP),
      ],
      quotes: [
        { id: QUOTE, shop_id: SHOP, status: "sent", public_token: QUOTE_TOKEN },
        { id: DRAFT_QUOTE, shop_id: SHOP, status: "draft", public_token: DRAFT_QUOTE_TOKEN },
      ],
      invoices: [
        { id: INVOICE, shop_id: SHOP, status: "open", public_token: INVOICE_TOKEN },
        { id: DRAFT_INVOICE, shop_id: SHOP, status: "draft", public_token: DRAFT_INVOICE_TOKEN },
      ],
    },
    rpc: {
      money_public_quote_json: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        const status = args.p_quote_id === DRAFT_QUOTE ? "draft" : "sent";
        return { ...QUOTE_JSON, shop, quote: { ...QUOTE_JSON.quote, status } };
      },
      money_public_invoice_json: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        const status = args.p_invoice_id === DRAFT_INVOICE ? "draft" : "open";
        return { ...INVOICE_JSON, shop, invoice: { ...INVOICE_JSON.invoice, status } };
      },
      can_collect_for_invoice: (args, ctx) => {
        // runs as the caller (RLS helper reading auth.uid())
        assertEquals(ctx.role, "authenticated");
        return ctx.userId === TECH && options.techCanCollect === true &&
          args.p_invoice_id === INVOICE;
      },
    },
  });
  if (options.logo) db.http.on("GET", LOGO_URL, options.logo);
  const log = memoryLogger();
  const handler = makeHandler({
    env: db.env(),
    fetch: db.http.fetch,
    logger: log.logger,
    now: () => new Date("2026-06-03T00:00:00Z"),
  });
  return { db, handler, log };
}

const post = (body: Record<string, unknown>, token?: string) =>
  jsonRequest("pdf", body, { origin: "https://app.example.com", ...(token ? { token } : {}) });

async function expectPdf(res: Response, filename: string): Promise<string> {
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "application/pdf");
  assertEquals(res.headers.get("content-disposition"), `inline; filename="${filename}"`);
  assertEquals(res.headers.get("cache-control"), "private, no-store");
  const bytes = new Uint8Array(await res.arrayBuffer());
  assertEquals(new TextDecoder().decode(bytes.slice(0, 5)), "%PDF-");
  return await pdfText(bytes);
}

Deno.test("pdf: public quote by token (POST and GET)", async () => {
  const { handler } = setup();
  const text = await expectPdf(
    await handler(post({ action: "quote", token: QUOTE_TOKEN })),
    "quote-1042.pdf",
  );
  assert(text.includes("$433.00"));
  assertEquals(text.includes("DRAFT"), false);
  const viaGet = await handler(
    emptyRequest("pdf", { query: { action: "quote", token: QUOTE_TOKEN } }),
  );
  await expectPdf(viaGet, "quote-1042.pdf");
});

Deno.test("pdf: public invoice by token includes payments and balance", async () => {
  const { handler } = setup();
  const text = await expectPdf(
    await handler(post({ action: "invoice", token: INVOICE_TOKEN })),
    "invoice-2001.pdf",
  );
  assert(text.includes("Payments received"));
  assert(text.includes("Balance due"));
});

Deno.test("pdf: drafts and unknown tokens are 404 on the public actions", async () => {
  const { handler } = setup();
  for (
    const body of [
      { action: "quote", token: DRAFT_QUOTE_TOKEN },
      { action: "invoice", token: DRAFT_INVOICE_TOKEN },
      { action: "quote", token: "99999999-0000-4000-8000-000000000001" },
      { action: "invoice", token: QUOTE_TOKEN },
    ]
  ) {
    const res = await handler(post(body));
    assertEquals(res.status, 404, JSON.stringify(body));
    assertEquals((await responseJson<ErrorBody>(res)).code, "not_found");
  }
});

Deno.test("pdf: validation (strict bodies, GET only for public documents)", async () => {
  const { handler } = setup();
  assertEquals((await handler(post({ action: "quote", token: "nope" }))).status, 400);
  assertEquals(
    (await handler(post({ action: "quote", token: QUOTE_TOKEN, id: QUOTE }))).status,
    400,
  );
  assertEquals((await handler(emptyRequest("pdf", { query: { action: "quote" } }))).status, 400);
  assertEquals(
    (await handler(emptyRequest("pdf", { query: { action: "staff_document" } }))).status,
    405,
  );
});

Deno.test("pdf: staff_document renders drafts marked DRAFT for managers", async () => {
  const { handler } = setup();
  const text = await expectPdf(
    await handler(post(
      { action: "staff_document", shop_id: SHOP, kind: "quote", id: DRAFT_QUOTE },
      "tok-manager",
    )),
    "quote-1042.pdf",
  );
  assert(text.includes("DRAFT"));
  const invoice = await expectPdf(
    await handler(post(
      { action: "staff_document", shop_id: SHOP, kind: "invoice", id: DRAFT_INVOICE },
      "tok-manager",
    )),
    "invoice-2001.pdf",
  );
  assert(invoice.includes("DRAFT"));
});

Deno.test("pdf: staff_document role rules", async () => {
  const { handler } = setup({ techCanCollect: true });
  const doc = (kind: string, id: string, token?: string, shopId = SHOP) =>
    handler(post({ action: "staff_document", shop_id: shopId, kind, id }, token));
  assertEquals((await doc("quote", QUOTE)).status, 401);
  assertEquals((await doc("quote", QUOTE, "tok-outsider")).status, 403);
  assertEquals((await doc("quote", QUOTE, "tok-tech")).status, 403);
  await expectPdf(await doc("invoice", INVOICE, "tok-tech"), "invoice-2001.pdf");
  assertEquals((await doc("invoice", DRAFT_INVOICE, "tok-tech")).status, 403);
  // an id of another shop (or none) is not found, never rendered
  assertEquals(
    (await doc("invoice", "99999999-0000-4000-8000-000000000001", "tok-manager")).status,
    404,
  );
  const { handler: noCollect } = setup({ techCanCollect: false });
  const res = await noCollect(
    post({ action: "staff_document", shop_id: SHOP, kind: "invoice", id: INVOICE }, "tok-tech"),
  );
  assertEquals(res.status, 403);
});

Deno.test("pdf: the shop logo is embedded when it is a small PNG/JPEG", async () => {
  const withLogo = setup({
    logoPath: `${SHOP}/logo.png`,
    logo: () =>
      new Response(LOGO_PNG as Uint8Array<ArrayBuffer>, {
        headers: { "content-type": "image/png" },
      }),
  });
  const res = await withLogo.handler(post({ action: "quote", token: QUOTE_TOKEN }));
  const bytes = new Uint8Array(await res.arrayBuffer());
  assert(new TextDecoder("latin1").decode(bytes).includes("/Subtype /Image"));
  const call = withLogo.db.http.calls.find((c) => c.url.pathname.includes("shop-assets"));
  assertEquals(call?.url.pathname, `/storage/v1/object/public/shop-assets/${SHOP}/logo.png`);

  for (
    const logo of [
      () => new Response("<svg/>", { headers: { "content-type": "image/svg+xml" } }),
      () => new Response(new Uint8Array(1024 * 1024 + 10)),
      () => new Response("missing", { status: 404 }),
    ]
  ) {
    const s = setup({ logoPath: `${SHOP}/logo.png`, logo });
    const r = await s.handler(post({ action: "quote", token: QUOTE_TOKEN }));
    assertEquals(r.status, 200);
    const b = new TextDecoder("latin1").decode(new Uint8Array(await r.arrayBuffer()));
    assertEquals(b.includes("/Subtype /Image"), false);
  }
});
