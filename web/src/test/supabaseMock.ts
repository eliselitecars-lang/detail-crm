/**
 * Test double for `@/lib/supabase`. Usage in a test file:
 *
 *   vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));
 *
 * then drive `supabase.auth.*`, `supabase.rpc`, `setTableResult(...)`,
 * `setFunctionResult(...)` (edge functions: `supabase.functions.invoke`) and
 * `supabase.storage.from(bucket).upload/remove/createSignedUrl(s)`.
 * Call `resetSupabaseMock()` in `beforeEach`.
 */
import { FunctionsHttpError } from '@supabase/supabase-js';
import { vi, type Mock } from 'vitest';

export interface MockResult {
  data?: unknown;
  error?: unknown;
  count?: number | null;
}

const CHAIN_METHODS = [
  'select',
  'insert',
  'update',
  'upsert',
  'delete',
  'eq',
  'neq',
  'is',
  'in',
  'gt',
  'gte',
  'lt',
  'lte',
  'like',
  'ilike',
  'or',
  'not',
  'contains',
  'containedBy',
  'overlaps',
  'filter',
  'match',
  'textSearch',
  'csv',
  'order',
  'limit',
  'range',
  'single',
  'maybeSingle',
  'abortSignal',
  'returns',
] as const;

export type Builder = { [K in (typeof CHAIN_METHODS)[number]]: Mock } & PromiseLike<MockResult>;

/** A thenable PostgREST builder that records calls and resolves to `result`. */
export function createBuilder(result: MockResult = { data: null, error: null }): Builder {
  const builder = {} as Builder;
  for (const method of CHAIN_METHODS) builder[method] = vi.fn(() => builder);
  (builder as { then: PromiseLike<MockResult>['then'] }).then = (onFulfilled, onRejected) =>
    Promise.resolve({ data: null, error: null, count: null, ...result }).then(
      onFulfilled,
      onRejected,
    );
  return builder;
}

/** A PostgREST error as supabase-js surfaces it (`{ data: null, error }`). */
export function pgError(code: string, message: string): MockResult {
  return { data: null, error: { code, message, details: null, hint: null } };
}

export type RpcHandler = (args: Record<string, unknown>) => MockResult;

export interface RpcCall {
  fn: string;
  args: Record<string, unknown>;
}

const tableResults = new Map<string, MockResult>();
export const builders: Record<string, Builder[]> = {};

/** Sets what `supabase.from(table)…` resolves to. */
export function setTableResult(table: string, result: MockResult) {
  tableResults.set(table, result);
}

/** What `supabase.functions.invoke(name, …)` resolves to (supabase-js shape). */
export interface FunctionResult {
  data?: unknown;
  error?: unknown;
  response?: unknown;
}

const functionResults = new Map<string, FunctionResult>();

/**
 * Sets what `supabase.functions.invoke(name)` resolves to. Use a
 * `FunctionsHttpError` (see `edgeHttpError`) as `error` for an HTTP failure.
 * For per-call results use `supabase.functions.invoke.mockResolvedValueOnce`.
 */
export function setFunctionResult(name: string, result: FunctionResult) {
  functionResults.set(name, result);
}

/** A supabase-js `FunctionsHttpError` carrying `body` as the JSON response. */
export function edgeHttpError(status: number, body: unknown): FunctionsHttpError {
  return new FunctionsHttpError(
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }),
  );
}

/** supabase-js storage results: `{ data, error }` (data null on error). */
type StorageResult<T> = Promise<{ data: T | null; error: unknown }>;

function storageBucket(bucket: string) {
  const signed = (path: string) => `https://signed.test/${bucket}/${path}`;
  return {
    getPublicUrl: (path: string) => ({ data: { publicUrl: `https://cdn.test/${path}` } }),
    upload: vi.fn<
      (path: string, body?: unknown, options?: unknown) => StorageResult<{ path: string }>
    >((path) => Promise.resolve({ data: { path }, error: null })),
    remove: vi.fn<(paths: string[]) => StorageResult<{ name: string }[]>>((paths) =>
      Promise.resolve({ data: paths.map((name) => ({ name })), error: null }),
    ),
    createSignedUrl: vi.fn<
      (path: string, expiresIn?: number, options?: unknown) => StorageResult<{ signedUrl: string }>
    >((path) => Promise.resolve({ data: { signedUrl: signed(path) }, error: null })),
    createSignedUrls: vi.fn<
      (
        paths: string[],
        expiresIn?: number,
      ) => StorageResult<{ path: string | null; signedUrl: string; error: string | null }[]>
    >((paths) =>
      Promise.resolve({
        data: paths.map((path) => ({ path, signedUrl: signed(path), error: null })),
        error: null,
      }),
    ),
  };
}

export type StorageBucketMock = ReturnType<typeof storageBucket>;
const storageBuckets = new Map<string, StorageBucketMock>();

const channel = {
  on: vi.fn(() => channel),
  subscribe: vi.fn(() => channel),
};

export const supabase = {
  auth: {
    onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    signInWithPassword: vi.fn(() => Promise.resolve({ data: {}, error: null })),
    signUp: vi.fn(() => Promise.resolve({ data: { session: null, user: null }, error: null })),
    signOut: vi.fn(() => Promise.resolve({ error: null })),
    resetPasswordForEmail: vi.fn(() => Promise.resolve({ data: {}, error: null })),
    updateUser: vi.fn(() => Promise.resolve({ data: {}, error: null })),
    getSession: vi.fn(() => Promise.resolve({ data: { session: null }, error: null })),
    initialize: vi.fn(() => Promise.resolve({ error: null })),
  },
  from: vi.fn((table: string) => {
    const builder = createBuilder(tableResults.get(table));
    (builders[table] ??= []).push(builder);
    return builder;
  }),
  rpc: vi.fn(() => createBuilder()),
  channel: vi.fn(() => channel),
  removeChannel: vi.fn(() => Promise.resolve('ok')),
  functions: {
    /** The app always passes `{ body: { action, … } }`. */
    invoke: vi.fn(
      (name: string, _options: { body: Record<string, unknown> }): Promise<FunctionResult> =>
        Promise.resolve({ data: null, error: null, ...functionResults.get(name) }),
    ),
  },
  storage: {
    /** One mock per bucket, so tests can assert on `storage.from('x').upload`. */
    from: vi.fn((bucket: string): StorageBucketMock => {
      let mock = storageBuckets.get(bucket);
      if (!mock) {
        mock = storageBucket(bucket);
        storageBuckets.set(bucket, mock);
      }
      return mock;
    }),
  },
};

/**
 * Routes `supabase.rpc(fn, args)` to per-function results (a MockResult or a
 * function of the args). Unknown functions resolve to `{ data: null }`.
 * Returns the recorded calls (in order).
 */
export function mockRpc(handlers: Record<string, MockResult | RpcHandler>): RpcCall[] {
  const calls: RpcCall[] = [];
  supabase.rpc.mockImplementation(((fn: string, args?: Record<string, unknown>) => {
    const call = { fn, args: args ?? {} };
    calls.push(call);
    const handler = handlers[fn];
    const result = typeof handler === 'function' ? handler(call.args) : (handler ?? { data: null });
    return createBuilder(result);
  }) as never);
  return calls;
}

export const isSupabaseConfigured = true;
export const shopAssetUrl = (path: string | null | undefined) =>
  path ? `https://cdn.test/${path}` : null;

/** Clears recorded calls, table / function results and storage mocks between tests. */
export function resetSupabaseMock() {
  tableResults.clear();
  functionResults.clear();
  storageBuckets.clear();
  for (const key of Object.keys(builders)) delete builders[key];
  vi.clearAllMocks();
  // Per-test overrides (mockResolvedValue / mockImplementation / *Once queues)
  // must not leak into the next test: back to the defaults above.
  supabase.rpc.mockReset();
  supabase.functions.invoke.mockReset();
  supabase.storage.from.mockReset();
}
