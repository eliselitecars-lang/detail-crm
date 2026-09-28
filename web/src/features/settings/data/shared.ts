/** Small helpers shared by the settings data modules. */
import type { PostgrestError } from '@supabase/supabase-js';
import type { useQueryClient } from '@tanstack/react-query';
import { unwrap } from '@/lib/db';

/** `unwrap` for list selects: a successful select never yields null rows. */
export function unwrapList<T>(result: { data: T[] | null; error: PostgrestError | null }): T[] {
  return unwrap(result) ?? [];
}

export type QueryClient = ReturnType<typeof useQueryClient>;

export function invalidateKeys(queryClient: QueryClient, keys: readonly (readonly unknown[])[]) {
  return Promise.all(keys.map((queryKey) => queryClient.invalidateQueries({ queryKey })));
}
