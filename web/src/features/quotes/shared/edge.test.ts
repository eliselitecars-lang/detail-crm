import { FunctionsHttpError } from '@supabase/supabase-js';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { z } from 'zod';
import { supabase } from '@/lib/supabase';
import { EdgeFunctionError, invokeEdge, toEdgeError } from './edge';

vi.mock('@/lib/supabase', async () => {
  const mod = await import('@/test/supabaseMock');
  return { ...mod, supabase: Object.assign(mod.supabase, { functions: { invoke: vi.fn() } }) };
});

const invoke = vi.mocked(supabase.functions.invoke);

function httpError(status: number, body: unknown) {
  return new FunctionsHttpError(
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } }),
  );
}

beforeEach(() => invoke.mockReset());

describe('invokeEdge', () => {
  it('sends { action, ...params } and validates the result', async () => {
    invoke.mockResolvedValueOnce({ data: { ok: true }, error: null, response: undefined });
    const result = await invokeEdge(
      'payments',
      'refund',
      { payment_id: 'p1' },
      z.object({ ok: z.boolean() }),
    );
    expect(result).toEqual({ ok: true });
    expect(invoke).toHaveBeenCalledWith('payments', {
      body: { action: 'refund', payment_id: 'p1' },
    });
  });

  it('maps error bodies to code, reason and the server message', async () => {
    invoke.mockResolvedValueOnce({
      data: null,
      error: httpError(402, {
        error: 'The card’s bank requires the customer to confirm this payment.',
        code: 'payment_failed',
        details: { reason: 'authentication_required' },
      }),
      response: undefined,
    });
    const error = await invokeEdge('payments', 'charge_saved_card', {}, z.object({})).catch(
      (e: unknown) => e,
    );
    expect(error).toBeInstanceOf(EdgeFunctionError);
    const edge = error as EdgeFunctionError;
    expect(edge.edgeCode).toBe('payment_failed');
    expect(edge.reason).toBe('authentication_required');
    expect(edge.status).toBe(402);
    expect(edge.message).toContain('requires the customer to confirm');
  });

  it('rejects unexpected response shapes', async () => {
    invoke.mockResolvedValueOnce({ data: { nope: 1 }, error: null, response: undefined });
    await expect(
      invokeEdge('payments', 'x', {}, z.object({ url: z.string() })),
    ).rejects.toBeInstanceOf(EdgeFunctionError);
  });

  it('leaves non-HTTP errors with a friendly message', async () => {
    const error = await toEdgeError(new TypeError('Failed to fetch'));
    expect(error.reason).toBeNull();
    expect(error.kind).toBe('network');
  });
});
