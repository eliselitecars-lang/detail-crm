/**
 * In-memory fake of the Supabase HTTP APIs that edge functions use, served
 * through FakeFetch so tests exercise the REAL supabase-js client:
 *
 *  - PostgREST tables: GET/HEAD (select, filters, order, limit/offset,
 *    single/maybeSingle, count), POST (insert/upsert), PATCH, DELETE.
 *  - PostgREST RPC: POST/GET /rest/v1/rpc/<fn> → registered handlers.
 *  - Auth: GET /auth/v1/user (token → user), used by getCaller().
 *
 *   const db = new FakeSupabase({ tables: { shop_members: [member] } });
 *   db.addUser("tok-owner", { id: ownerId, email: "o@example.com" });
 *   const admin = db.admin();
 *   const res = await handler(jsonRequest(url, body, { token: "tok-owner" }));
 *   db.table("payments")  // assert writes
 *
 * Scope: plain column selects only (embedded resources, `or=`/`and=` and
 * other operators return a 400 "fake-supabase: unsupported …" error so a test
 * can never pass on semantics the fake does not implement). RLS is NOT
 * emulated — use the SQL test suite for policies; here, assert which role
 * (`requests[i].role`) made each call.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { Env } from "../env.ts";
import { adminClient } from "../supabase.ts";
import { FakeFetch, jsonResponse } from "./fake_fetch.ts";
import { testEnvSource } from "./env.ts";

export type Row = Record<string, unknown>;

export interface FakeUser {
  id: string;
  email?: string | null;
  email_confirmed_at?: string | null;
  phone?: string | null;
  is_anonymous?: boolean;
  app_metadata?: Record<string, unknown>;
  user_metadata?: Record<string, unknown>;
}

export type RequestRole = "service_role" | "authenticated" | "anon";

export interface FakeRequestLog {
  kind: "rest" | "rpc" | "auth";
  method: string;
  /** Table or function name (auth: endpoint path). */
  target: string;
  role: RequestRole;
  /** Auth user id for `authenticated` requests. */
  userId: string | null;
}

export interface RpcContext {
  role: RequestRole;
  userId: string | null;
  db: FakeSupabase;
}

export type RpcHandler = (args: Record<string, unknown>, ctx: RpcContext) => unknown;

export interface TableOptions {
  /** Primary key columns (default ["id"]; an absent `id` gets a random UUID). */
  primaryKey?: readonly string[];
  /** Additional unique constraints (each a column list). */
  unique?: ReadonlyArray<readonly string[]>;
  /** Column defaults applied on insert. */
  defaults?: () => Row;
}

export interface FakeSupabaseOptions {
  url?: string;
  tables?: Record<string, Row[]>;
  tableOptions?: Record<string, TableOptions>;
  users?: Record<string, FakeUser>;
  rpc?: Record<string, RpcHandler>;
  /** Share one FakeFetch with Stripe/Twilio/Resend stubs. */
  http?: FakeFetch;
  env?: Record<string, string | undefined>;
}

/** Error thrown from an RPC handler → PostgREST-style error response. */
export class FakeRpcError extends Error {
  readonly code: string;
  readonly status: number;
  readonly details: string | null;
  readonly hint: string | null;

  constructor(
    code: string,
    message: string,
    options: { status?: number; details?: string; hint?: string } = {},
  ) {
    super(message);
    this.name = "FakeRpcError";
    this.code = code;
    this.status = options.status ?? 400;
    this.details = options.details ?? null;
    this.hint = options.hint ?? null;
  }
}

class Unsupported extends Error {}

export const FAKE_SUPABASE_URL = "https://fake-project.supabase.co";
export const FAKE_ANON_KEY = "fake-anon-key";
export const FAKE_SERVICE_ROLE_KEY = "fake-service-role-key";

function pgError(status: number, code: string, message: string, details: string | null = null) {
  return jsonResponse({ code, message, details, hint: null }, status);
}

// ---------------------------------------------------------------------------
// PostgREST query parsing
// ---------------------------------------------------------------------------

function splitTopLevel(input: string, separator = ","): string[] {
  const parts: string[] = [];
  let depth = 0;
  let quoted = false;
  let current = "";
  for (const ch of input) {
    if (ch === '"') quoted = !quoted;
    if (!quoted && (ch === "(" || ch === "{")) depth++;
    if (!quoted && (ch === ")" || ch === "}")) depth--;
    if (ch === separator && depth === 0 && !quoted) {
      parts.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  parts.push(current);
  return parts;
}

function unquote(value: string): string {
  const trimmed = value.trim();
  return trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2
    ? trimmed.slice(1, -1).replace(/\\(.)/g, "$1")
    : trimmed;
}

interface SelectColumn {
  column: string;
  alias: string;
}

function parseSelect(select: string | null): SelectColumn[] | "*" {
  if (select === null || select.trim() === "" || select.trim() === "*") return "*";
  return splitTopLevel(select).map((raw) => {
    const item = raw.trim();
    if (/[()!]/.test(item) || item.includes("->")) {
      throw new Unsupported(`select item "${item}" (embedded resources/json paths)`);
    }
    const [aliasPart, columnPart] = item.includes(":") && !item.includes("::")
      ? item.split(":", 2) as [string, string]
      : [undefined, item];
    const column = (columnPart ?? item).split("::")[0]?.trim() ?? "";
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(column)) throw new Unsupported(`select item "${item}"`);
    return { column, alias: aliasPart?.trim() || column };
  });
}

function looseEquals(value: unknown, raw: string): boolean {
  if (value === null || value === undefined) return false;
  if (typeof value === "boolean") return String(value) === raw;
  if (typeof value === "number") return raw.trim() !== "" && Number(raw) === value;
  if (typeof value === "string") return value === raw;
  return JSON.stringify(value) === raw;
}

function compare(value: unknown, raw: string): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "number") return value - Number(raw);
  const text = String(value);
  return text < raw ? -1 : text > raw ? 1 : 0;
}

function likeToRegExp(pattern: string, flags: string): RegExp {
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/[*%]/g, ".*")
    .replace(/_/g, ".");
  return new RegExp(`^${escaped}$`, flags);
}

function parseList(raw: string, open: string, close: string): string[] {
  if (!raw.startsWith(open) || !raw.endsWith(close)) {
    throw new Unsupported(`list value "${raw}"`);
  }
  const inner = raw.slice(1, -1);
  return inner === "" ? [] : splitTopLevel(inner).map(unquote);
}

function evaluate(value: unknown, op: string, raw: string): boolean {
  switch (op) {
    case "eq":
      return looseEquals(value, raw);
    case "neq":
      return value !== null && value !== undefined && !looseEquals(value, raw);
    case "gt":
    case "gte":
    case "lt":
    case "lte": {
      const diff = compare(value, raw);
      if (diff === null || Number.isNaN(diff)) return false;
      return op === "gt" ? diff > 0 : op === "gte" ? diff >= 0 : op === "lt" ? diff < 0 : diff <= 0;
    }
    case "in":
      return parseList(raw, "(", ")").some((item) => looseEquals(value, item));
    case "is":
      if (raw === "null") return value === null || value === undefined;
      if (raw === "true") return value === true;
      if (raw === "false") return value === false;
      throw new Unsupported(`is.${raw}`);
    case "like":
      return typeof value === "string" && likeToRegExp(raw, "").test(value);
    case "ilike":
      return typeof value === "string" && likeToRegExp(raw, "i").test(value);
    case "cs": {
      if (!Array.isArray(value)) return false;
      const wanted = parseList(raw, "{", "}");
      return wanted.every((item) => value.some((v) => looseEquals(v, item)));
    }
    default:
      throw new Unsupported(`operator "${op}"`);
  }
}

interface Filter {
  column: string;
  negate: boolean;
  op: string;
  value: string;
}

const RESERVED_PARAMS = new Set(["select", "order", "limit", "offset", "on_conflict", "columns"]);

function parseFilters(search: URLSearchParams): Filter[] {
  const filters: Filter[] = [];
  for (const [column, expr] of search) {
    if (RESERVED_PARAMS.has(column)) continue;
    if (column === "or" || column === "and" || column.includes(".")) {
      throw new Unsupported(`filter "${column}"`);
    }
    const negate = expr.startsWith("not.");
    const rest = negate ? expr.slice(4) : expr;
    const dot = rest.indexOf(".");
    if (dot < 0) throw new Unsupported(`filter expression "${expr}"`);
    filters.push({ column, negate, op: rest.slice(0, dot), value: rest.slice(dot + 1) });
  }
  return filters;
}

function applyFilters(rows: Row[], filters: Filter[]): Row[] {
  return rows.filter((row) =>
    filters.every((f) => evaluate(row[f.column], f.op, f.value) !== f.negate)
  );
}

function applyOrder(rows: Row[], order: string | null): Row[] {
  if (!order) return rows;
  const keys = order.split(",").map((part) => {
    const [column = "", ...mods] = part.split(".");
    const desc = mods.includes("desc");
    const nullsFirst = mods.includes("nullsfirst") || (desc && !mods.includes("nullslast"));
    return { column, desc, nullsFirst };
  });
  return [...rows].sort((a, b) => {
    for (const { column, desc, nullsFirst } of keys) {
      const av = a[column];
      const bv = b[column];
      const aNull = av === null || av === undefined;
      const bNull = bv === null || bv === undefined;
      if (aNull || bNull) {
        if (aNull && bNull) continue;
        return aNull === nullsFirst ? -1 : 1;
      }
      const diff = typeof av === "number" && typeof bv === "number"
        ? av - bv
        : String(av) < String(bv)
        ? -1
        : String(av) > String(bv)
        ? 1
        : 0;
      if (diff !== 0) return desc ? -diff : diff;
    }
    return 0;
  });
}

function project(rows: Row[], columns: SelectColumn[] | "*"): Row[] {
  if (columns === "*") return rows.map((row) => structuredClone(row));
  return rows.map((row) => {
    const out: Row = {};
    for (const { column, alias } of columns) out[alias] = structuredClone(row[column] ?? null);
    return out;
  });
}

function preferences(headers: Headers): Set<string> {
  return new Set(
    (headers.get("prefer") ?? "").split(",").map((part) => part.trim()).filter(Boolean),
  );
}

// ---------------------------------------------------------------------------
// FakeSupabase
// ---------------------------------------------------------------------------

export class FakeSupabase {
  readonly url: string;
  readonly http: FakeFetch;
  readonly requests: FakeRequestLog[] = [];
  readonly envRecord: Record<string, string | undefined>;
  readonly #tables = new Map<string, Row[]>();
  readonly #tableOptions = new Map<string, TableOptions>();
  readonly #users = new Map<string, FakeUser>();
  readonly #rpc = new Map<string, RpcHandler>();

  constructor(options: FakeSupabaseOptions = {}) {
    this.url = (options.url ?? FAKE_SUPABASE_URL).replace(/\/+$/, "");
    this.http = options.http ?? new FakeFetch();
    this.envRecord = {
      SUPABASE_URL: this.url,
      SUPABASE_ANON_KEY: FAKE_ANON_KEY,
      SUPABASE_SERVICE_ROLE_KEY: FAKE_SERVICE_ROLE_KEY,
      ...options.env,
    };
    for (const [name, rows] of Object.entries(options.tables ?? {})) this.seed(name, rows);
    for (const [name, opts] of Object.entries(options.tableOptions ?? {})) {
      this.#tableOptions.set(name, opts);
    }
    for (const [token, user] of Object.entries(options.users ?? {})) this.addUser(token, user);
    for (const [name, handler] of Object.entries(options.rpc ?? {})) this.onRpc(name, handler);
    this.#install();
  }

  /** Env whose Supabase vars point at this fake (other vars from testEnvSource). */
  env(overrides: Record<string, string | undefined> = {}): Env {
    return new Env(testEnvSource({ ...this.envRecord, ...overrides }));
  }

  /** Service-role client wired to the fake (the same factory functions use). */
  admin(): SupabaseClient {
    return adminClient({ env: this.env(), fetch: this.http.fetch });
  }

  /** Anon-key client acting as the user owning `token`. */
  asUser(token: string): SupabaseClient {
    return createClient(this.url, FAKE_ANON_KEY, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { fetch: this.http.fetch, headers: { Authorization: `Bearer ${token}` } },
    });
  }

  addUser(token: string, user: FakeUser): this {
    this.#users.set(token, user);
    return this;
  }

  onRpc(name: string, handler: RpcHandler): this {
    this.#rpc.set(name, handler);
    return this;
  }

  setTableOptions(table: string, options: TableOptions): this {
    this.#tableOptions.set(table, options);
    return this;
  }

  /** Replaces a table's rows (creating the table). */
  seed(table: string, rows: Row[]): this {
    this.#tables.set(table, rows.map((row) => structuredClone(row)));
    return this;
  }

  /** A snapshot copy of a table's rows (empty for unknown tables). */
  table(table: string): Row[] {
    return (this.#tables.get(table) ?? []).map((row) => structuredClone(row));
  }

  // -------------------------------------------------------------------------

  #roleOf(headers: Headers): { role: RequestRole; userId: string | null } {
    const auth = headers.get("authorization");
    const token = auth ? /^Bearer\s+(\S+)$/i.exec(auth)?.[1] ?? null : null;
    if (token === FAKE_SERVICE_ROLE_KEY) return { role: "service_role", userId: null };
    if (token && this.#users.has(token)) {
      return { role: "authenticated", userId: this.#users.get(token)?.id ?? null };
    }
    return { role: "anon", userId: null };
  }

  #checkApiKey(headers: Headers): Response | null {
    const apikey = headers.get("apikey");
    if (apikey !== FAKE_ANON_KEY && apikey !== FAKE_SERVICE_ROLE_KEY) {
      return jsonResponse({ message: "Invalid API key" }, 401);
    }
    return null;
  }

  #install(): void {
    const rest = `${this.url}/rest/v1`;
    this.http.on("GET", `${this.url}/auth/v1/user`, (req) => this.#authUser(req));
    for (const method of ["GET", "HEAD", "POST", "PATCH", "DELETE"]) {
      this.http.on(
        method,
        `${rest}/:table`,
        (req, match) => this.#table(req, match.params.table ?? "", match.url, match.call.json),
      );
    }
    for (const method of ["GET", "POST"]) {
      this.http.on(
        method,
        `${rest}/rpc/:fn`,
        (req, match) => this.#callRpc(req, match.params.fn ?? "", match.url, match.call.json),
      );
    }
  }

  #authUser(req: Request): Response {
    const keyError = this.#checkApiKey(req.headers);
    if (keyError) return keyError;
    const { role, userId } = this.#roleOf(req.headers);
    this.requests.push({ kind: "auth", method: "GET", target: "user", role, userId });
    const auth = req.headers.get("authorization") ?? "";
    const token = /^Bearer\s+(\S+)$/i.exec(auth)?.[1];
    const user = token ? this.#users.get(token) : undefined;
    if (!user) {
      return jsonResponse(
        {
          code: 403,
          error_code: "bad_jwt",
          msg: "invalid JWT: unable to parse or verify signature",
        },
        403,
      );
    }
    const now = new Date(0).toISOString();
    return jsonResponse({
      id: user.id,
      aud: "authenticated",
      role: "authenticated",
      email: user.email ?? "",
      phone: user.phone ?? "",
      email_confirmed_at: user.email_confirmed_at ?? undefined,
      is_anonymous: user.is_anonymous ?? false,
      app_metadata: user.app_metadata ?? { provider: "email", providers: ["email"] },
      user_metadata: user.user_metadata ?? {},
      identities: [],
      created_at: now,
      updated_at: now,
    });
  }

  async #callRpc(req: Request, fn: string, url: URL, body: unknown): Promise<Response> {
    const keyError = this.#checkApiKey(req.headers);
    if (keyError) return keyError;
    const { role, userId } = this.#roleOf(req.headers);
    this.requests.push({ kind: "rpc", method: req.method, target: fn, role, userId });
    const handler = this.#rpc.get(fn);
    if (!handler) {
      return pgError(
        404,
        "PGRST202",
        `Could not find the function public.${fn} in the schema cache`,
      );
    }
    const args: Record<string, unknown> = req.method === "GET"
      ? Object.fromEntries(url.searchParams)
      : (body && typeof body === "object" && !Array.isArray(body)
        ? body as Record<string, unknown>
        : {});
    try {
      const result = await handler(args, { role, userId, db: this });
      return result === undefined ? new Response(null, { status: 204 }) : jsonResponse(result);
    } catch (err) {
      if (err instanceof FakeRpcError) {
        return jsonResponse(
          { code: err.code, message: err.message, details: err.details, hint: err.hint },
          err.status,
        );
      }
      throw err;
    }
  }

  #table(req: Request, table: string, url: URL, body: unknown): Response {
    const keyError = this.#checkApiKey(req.headers);
    if (keyError) return keyError;
    const { role, userId } = this.#roleOf(req.headers);
    this.requests.push({ kind: "rest", method: req.method, target: table, role, userId });
    const rows = this.#tables.get(table);
    if (!rows) {
      return pgError(
        404,
        "PGRST205",
        `Could not find the table 'public.${table}' in the schema cache`,
      );
    }
    try {
      switch (req.method) {
        case "GET":
        case "HEAD":
          return this.#select(req, rows, url);
        case "POST":
          return this.#insert(req, table, rows, url, body);
        case "PATCH":
          return this.#update(req, table, rows, url, body);
        case "DELETE":
          return this.#delete(req, table, rows, url);
        default:
          return pgError(405, "PGRST117", `Unsupported HTTP method ${req.method}`);
      }
    } catch (err) {
      if (err instanceof Unsupported) {
        return pgError(400, "FAKE0", `fake-supabase: unsupported ${err.message}`);
      }
      if (err instanceof FakeRpcError) {
        return jsonResponse(
          { code: err.code, message: err.message, details: err.details, hint: err.hint },
          err.status,
        );
      }
      throw err;
    }
  }

  #respond(req: Request, rows: Row[], status: number, total?: number): Response {
    const headers: Record<string, string> = {};
    if (total !== undefined) {
      headers["Content-Range"] = rows.length ? `0-${rows.length - 1}/${total}` : `*/${total}`;
    }
    const accept = req.headers.get("accept") ?? "";
    if (accept.startsWith("application/vnd.pgrst.object+json")) {
      if (rows.length !== 1) {
        return jsonResponse(
          {
            code: "PGRST116",
            message: "Cannot coerce the result to a single JSON object",
            details: `The result contains ${rows.length} rows`,
            hint: null,
          },
          406,
        );
      }
      return jsonResponse(rows[0], status, headers);
    }
    if (req.method === "HEAD") return new Response(null, { status, headers });
    return jsonResponse(rows, status, headers);
  }

  #select(req: Request, rows: Row[], url: URL): Response {
    const columns = parseSelect(url.searchParams.get("select"));
    let result = applyOrder(
      applyFilters(rows, parseFilters(url.searchParams)),
      url.searchParams.get("order"),
    );
    const total = result.length;
    const offset = Number(url.searchParams.get("offset") ?? 0);
    const limit = url.searchParams.get("limit");
    result = result.slice(offset, limit === null ? undefined : offset + Number(limit));
    const counted = [...preferences(req.headers)].some((p) => p.startsWith("count="));
    return this.#respond(req, project(result, columns), 200, counted ? total : undefined);
  }

  #keyOf(row: Row, columns: readonly string[]): string {
    return JSON.stringify(columns.map((c) => row[c] ?? null));
  }

  #constraints(table: string): Array<readonly string[]> {
    const opts = this.#tableOptions.get(table);
    return [opts?.primaryKey ?? ["id"], ...(opts?.unique ?? [])];
  }

  #violates(table: string, rows: Row[], candidate: Row, ignore?: Row): boolean {
    return this.#constraints(table).some((cols) => {
      if (cols.some((c) => candidate[c] === null || candidate[c] === undefined)) return false;
      const key = this.#keyOf(candidate, cols);
      return rows.some((row) => row !== ignore && this.#keyOf(row, cols) === key);
    });
  }

  #insert(req: Request, table: string, rows: Row[], url: URL, body: unknown): Response {
    const prefer = preferences(req.headers);
    const input = Array.isArray(body) ? body : [body];
    const opts = this.#tableOptions.get(table);
    const primaryKey = opts?.primaryKey ?? ["id"];
    const columnsParam = url.searchParams.get("columns");
    const allowed = columnsParam ? new Set(columnsParam.split(",").map(unquote)) : null;
    const merge = prefer.has("resolution=merge-duplicates");
    const ignore = prefer.has("resolution=ignore-duplicates");
    const conflictCols = url.searchParams.get("on_conflict")?.split(",").map((c) => c.trim()) ??
      primaryKey;
    const written: Row[] = [];

    for (const item of input) {
      if (!item || typeof item !== "object" || Array.isArray(item)) {
        return pgError(400, "PGRST102", "All object keys must match");
      }
      let values = item as Row;
      if (allowed) {
        values = Object.fromEntries(Object.entries(values).filter(([k]) => allowed.has(k)));
      }
      if (merge || ignore) {
        const key = this.#keyOf(values, conflictCols);
        const existing = rows.find((row) => this.#keyOf(row, conflictCols) === key);
        if (existing) {
          if (merge) {
            Object.assign(existing, structuredClone(values));
            written.push(existing);
          }
          continue;
        }
      }
      const row: Row = { ...(opts?.defaults?.() ?? {}), ...structuredClone(values) };
      if (primaryKey.length === 1 && primaryKey[0] === "id" && row.id === undefined) {
        row.id = crypto.randomUUID();
      }
      if (this.#violates(table, rows, row)) {
        return pgError(
          409,
          "23505",
          `duplicate key value violates unique constraint on "${table}"`,
        );
      }
      rows.push(row);
      written.push(row);
    }
    if (!prefer.has("return=representation")) return new Response(null, { status: 201 });
    return this.#respond(req, project(written, parseSelect(url.searchParams.get("select"))), 201);
  }

  #update(req: Request, table: string, rows: Row[], url: URL, body: unknown): Response {
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return pgError(400, "PGRST102", "Update body must be an object");
    }
    const matched = applyFilters(rows, parseFilters(url.searchParams));
    for (const row of matched) {
      const next = { ...row, ...structuredClone(body as Row) };
      if (this.#violates(table, rows, next, row)) {
        return pgError(
          409,
          "23505",
          `duplicate key value violates unique constraint on "${table}"`,
        );
      }
    }
    for (const row of matched) Object.assign(row, structuredClone(body as Row));
    if (!preferences(req.headers).has("return=representation")) {
      return new Response(null, { status: 204 });
    }
    return this.#respond(req, project(matched, parseSelect(url.searchParams.get("select"))), 200);
  }

  #delete(req: Request, table: string, rows: Row[], url: URL): Response {
    const matched = applyFilters(rows, parseFilters(url.searchParams));
    const remaining = rows.filter((row) => !matched.includes(row));
    rows.length = 0;
    rows.push(...remaining);
    this.#tables.set(table, rows);
    if (!preferences(req.headers).has("return=representation")) {
      return new Response(null, { status: 204 });
    }
    return this.#respond(req, project(matched, parseSelect(url.searchParams.get("select"))), 200);
  }
}
