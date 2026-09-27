/**
 * Test helpers for the public pages (booking, public-docs, portal). Used
 * only by *.test.tsx files together with
 *   vi.mock('@/lib/supabase', () => import('@/features/public-docs/shared/testSupabase'))
 */
import { vi } from 'vitest';
import { createBuilder, resetSupabaseMock, supabase, type MockResult } from '@/test/supabaseMock';

export type RpcHandler = (args: Record<string, unknown>) => MockResult;

export interface RpcCall {
  fn: string;
  args: Record<string, unknown>;
}

/**
 * Routes `supabase.rpc(fn, args)` to per-function handlers (a MockResult or
 * a function of the args). Unknown functions resolve to `{ data: null }`.
 * Returns the recorded calls.
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

/** A PostgREST error body as supabase-js surfaces it. */
export function pgError(code: string, message: string): MockResult {
  return { data: null, error: { code, message, details: null, hint: null } };
}

export const edge = {
  invoke: vi.fn(),
};

export const storageBucket = {
  upload: vi.fn(),
  getPublicUrl: (path: string) => ({ data: { publicUrl: `https://cdn.test/${path}` } }),
};

/** Call in beforeEach: clears recorded calls and re-installs the storage/edge doubles. */
export function resetPublicMocks() {
  resetSupabaseMock();
  edge.invoke.mockReset();
  storageBucket.upload.mockReset();
  supabase.storage.from.mockImplementation((() => storageBucket) as never);
}
