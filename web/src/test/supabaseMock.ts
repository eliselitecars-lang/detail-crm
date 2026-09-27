/**
 * Test double for `@/lib/supabase`. Usage in a test file:
 *
 *   const { supabaseMock } = vi.hoisted(() => ({ supabaseMock: createSupabaseMockHoisted() }))
 *
 * Simpler: `vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'))`
 * then drive `supabase.auth.*` / `supabase.rpc` / `setTableResult(...)`.
 */
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

const tableResults = new Map<string, MockResult>();
export const builders: Record<string, Builder[]> = {};

/** Sets what `supabase.from(table)…` resolves to. */
export function setTableResult(table: string, result: MockResult) {
  tableResults.set(table, result);
}

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
  storage: {
    from: vi.fn(() => ({
      getPublicUrl: (path: string) => ({ data: { publicUrl: `https://cdn.test/${path}` } }),
    })),
  },
};

export const isSupabaseConfigured = true;
export const shopAssetUrl = (path: string | null | undefined) =>
  path ? `https://cdn.test/${path}` : null;

/** Clears recorded calls and table results between tests. */
export function resetSupabaseMock() {
  tableResults.clear();
  for (const key of Object.keys(builders)) delete builders[key];
  vi.clearAllMocks();
}
