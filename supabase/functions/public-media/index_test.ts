import { assert, assertEquals } from "@std/assert";
import type { ErrorBody } from "../_shared/http.ts";
import { jsonResponse } from "../_shared/testing/fake_fetch.ts";
import { FakeRpcError, FakeSupabase, type Row } from "../_shared/testing/fake_supabase.ts";
import { memoryLogger } from "../_shared/testing/logger.ts";
import { jsonRequest, preflightRequest, responseJson } from "../_shared/testing/requests.ts";
import { EXPIRES_IN, makeHandler, type MediaListResponse } from "./index.ts";

const SHOP = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const JOB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const REPORT_TOKEN = "11111111-1111-4111-8111-111111111111";
const REVOKED_TOKEN = "22222222-2222-4222-8222-222222222222";
const BOOKING_TOKEN = "33333333-3333-4333-8333-333333333333";
const CLIENT = "44444444-4444-4444-8444-444444444444";
const DOC = "55555555-5555-4555-8555-555555555555";
const PHOTO = "66666666-6666-4666-8666-666666666666";
const VIDEO = "77777777-7777-4777-8777-777777777777";
const MARK = "88888888-8888-4888-8888-888888888888";
const SIGN_URL = "https://fake-project.supabase.co/storage/v1/object/sign/:bucket";

const REPORT_MEDIA: Row[] = [
  { ref_id: PHOTO, kind: "photo", bucket: "job-photos", path: `${SHOP}/${JOB}/before 1.jpg` },
  { ref_id: VIDEO, kind: "video", bucket: "job-media", path: `${SHOP}/${JOB}/v-walk.mp4` },
  { ref_id: VIDEO, kind: "poster", bucket: "job-photos", path: `${SHOP}/${JOB}/v-walk.jpg` },
  { ref_id: MARK, kind: "mark_photo", bucket: "job-photos", path: `${SHOP}/${JOB}/gone.jpg` },
  { ref_id: DOC, kind: "document", bucket: "documents", path: `${SHOP}/jobs/${JOB}/care.pdf` },
];

function setup(env: Record<string, string | undefined> = {}) {
  const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
  const db = new FakeSupabase({
    env,
    users: { "tok-client": { id: CLIENT, email: "c@example.com" } },
    tables: {
      job_reports: [
        { id: crypto.randomUUID(), token: REPORT_TOKEN, revoked_at: null },
        { id: crypto.randomUUID(), token: REVOKED_TOKEN, revoked_at: "2026-01-01T00:00:00Z" },
      ],
      jobs: [{ id: JOB, public_token: BOOKING_TOKEN }],
    },
    rpc: {
      job_report_media: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        rpcCalls.push({ fn: "job_report_media", args });
        return args.p_token === REPORT_TOKEN ? REPORT_MEDIA : [];
      },
      booking_document_media: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        rpcCalls.push({ fn: "booking_document_media", args });
        return args.p_token === BOOKING_TOKEN
          ? [{ ref_id: DOC, bucket: "documents", path: `${SHOP}/jobs/${JOB}/care.pdf` }]
          : [];
      },
      portal_document_media: (args, ctx) => {
        if (ctx.role !== "service_role") throw new FakeRpcError("42501", "denied");
        rpcCalls.push({ fn: "portal_document_media", args });
        return args.p_document_id === DOC && args.p_user_id === CLIENT
          ? { bucket: "documents", path: `${SHOP}/customers/c/receipt.pdf` }
          : null;
      },
    },
  });
  const signs: { bucket: string; paths: string[]; expiresIn: number; auth: string | null }[] = [];
  db.http.on("POST", SIGN_URL, (req, match) => {
    const bucket = match.params.bucket ?? "";
    const body = match.call.json as { paths: string[]; expiresIn: number };
    signs.push({
      bucket,
      paths: body.paths,
      expiresIn: body.expiresIn,
      auth: req.headers.get("authorization"),
    });
    return jsonResponse(
      body.paths.map((path) =>
        path.endsWith("gone.jpg")
          ? {
            path,
            error: "Either the object does not exist or you do not have access to it",
            signedURL: null,
          }
          : { path, error: null, signedURL: `/object/sign/${bucket}/${path}?token=sig` }
      ),
    );
  });
  const log = memoryLogger();
  const handler = makeHandler({ env: db.env(), fetch: db.http.fetch, logger: log.logger });
  return { db, handler, signs, rpcCalls, log };
}

const call = (action: string, body: Record<string, unknown>, token?: string) =>
  jsonRequest("public-media", { action, ...body }, {
    origin: "https://app.example.com",
    ...(token ? { token } : {}),
  });

Deno.test("job_report: signs every visible object for 10 minutes, per bucket", async () => {
  const { handler, signs, log } = setup();
  const res = await handler(call("job_report", { token: REPORT_TOKEN }));
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("access-control-allow-origin"), "https://app.example.com");
  const body = await responseJson<MediaListResponse>(res);
  assertEquals(body.expires_in, EXPIRES_IN);
  assertEquals(body.items.map((i) => [i.ref_id, i.kind]), [
    [PHOTO, "photo"],
    [VIDEO, "video"],
    [VIDEO, "poster"],
    [DOC, "document"],
  ]);
  assertEquals(
    body.items[0]?.url,
    `https://fake-project.supabase.co/storage/v1/object/sign/job-photos/${SHOP}/${JOB}/before%201.jpg?token=sig`,
  );
  assertEquals(signs.map((s) => [s.bucket, s.paths.length, s.expiresIn]), [
    ["job-photos", 3, 600],
    ["job-media", 1, 600],
    ["documents", 1, 600],
  ]);
  assert(signs.every((s) => s.auth === "Bearer fake-service-role-key"));
  assertEquals(log.events("media_sign_skipped").length, 1); // the missing mark photo
});

Deno.test("job_report: unknown or revoked token is 404 and nothing is signed", async () => {
  const { handler, signs, rpcCalls } = setup();
  for (const token of [REVOKED_TOKEN, "99999999-9999-4999-8999-999999999999"]) {
    const res = await handler(call("job_report", { token }));
    assertEquals(res.status, 404);
    assertEquals((await responseJson<ErrorBody>(res)).code, "not_found");
  }
  assertEquals(signs.length, 0);
  assertEquals(rpcCalls.length, 0);
});

Deno.test("public-media: paths and buckets from the client are never accepted", async () => {
  const { handler } = setup();
  for (
    const body of [
      { token: REPORT_TOKEN, path: "x" },
      { token: REPORT_TOKEN, bucket: "signatures" },
      { token: "not-a-token" },
      {},
    ]
  ) {
    const res = await handler(call("job_report", body));
    assertEquals(res.status, 400, JSON.stringify(body));
  }
});

Deno.test("booking_documents: signs the booking's visible documents", async () => {
  const { handler, rpcCalls } = setup();
  const res = await handler(call("booking_documents", { token: BOOKING_TOKEN }));
  assertEquals(res.status, 200);
  const body = await responseJson<MediaListResponse>(res);
  assertEquals(body.items.map((i) => [i.ref_id, i.kind]), [[DOC, "document"]]);
  assertEquals(rpcCalls, [{ fn: "booking_document_media", args: { p_token: BOOKING_TOKEN } }]);
  const unknown = await handler(
    call("booking_documents", { token: "99999999-9999-4999-8999-999999999999" }),
  );
  assertEquals(unknown.status, 404);
});

Deno.test("portal_document: signed-in client gets one URL for their own document", async () => {
  const { handler, rpcCalls } = setup();
  const res = await handler(call("portal_document", { document_id: DOC }, "tok-client"));
  assertEquals(res.status, 200);
  assertEquals(await responseJson(res), {
    expires_in: 600,
    url:
      `https://fake-project.supabase.co/storage/v1/object/sign/documents/${SHOP}/customers/c/receipt.pdf?token=sig`,
  });
  assertEquals(rpcCalls, [{
    fn: "portal_document_media",
    args: { p_document_id: DOC, p_user_id: CLIENT },
  }]);
  const other = await handler(
    call("portal_document", { document_id: crypto.randomUUID() }, "tok-client"),
  );
  assertEquals(other.status, 404);
  assertEquals((await handler(call("portal_document", { document_id: DOC }))).status, 401);
});

Deno.test("public-media: URLs use the public API origin when FUNCTIONS_PUBLIC_URL is set", async () => {
  const { handler } = setup({ FUNCTIONS_PUBLIC_URL: "http://127.0.0.1:54321/functions/v1" });
  const body = await responseJson<MediaListResponse>(
    await handler(call("booking_documents", { token: BOOKING_TOKEN })),
  );
  assert(body.items[0]?.url.startsWith("http://127.0.0.1:54321/storage/v1/object/sign/documents/"));
});

Deno.test("public-media: answers the web app's CORS preflight", async () => {
  const { handler } = setup();
  const res = await handler(preflightRequest("public-media", "https://app.example.com"));
  assertEquals(res.status, 204);
});
