/**
 * Settings tests' `@/lib/supabase` double: the shared mock plus
 * `functions.invoke` (stripe-connect) and storage upload/remove (logo).
 *   vi.mock('@/lib/supabase', () => import('./testing/supabaseMock'));
 */
import { vi } from 'vitest';
import { supabase as base } from '@/test/supabaseMock';

export * from '@/test/supabaseMock';

export const invoke = vi.fn(
  (
    _name: string,
    _options: { body: Record<string, unknown> },
  ): Promise<{
    data: unknown;
    error: unknown;
  }> => Promise.resolve({ data: null, error: null }),
);
export const upload = vi.fn(() => Promise.resolve({ data: { path: 'x' }, error: null }));
export const remove = vi.fn(() => Promise.resolve({ data: [], error: null }));

Object.assign(base, { functions: { invoke } });
base.storage.from = vi.fn(() => ({
  getPublicUrl: (path: string) => ({ data: { publicUrl: `https://cdn.test/${path}` } }),
  upload,
  remove,
}));
