import type { PostgrestError } from '@supabase/supabase-js';
import { unwrap } from '@/lib/db';

/** `unwrap` for list queries: a null list (no rows) becomes []. */
export function unwrapList<T>(result: { data: T[] | null; error: PostgrestError | null }): T[] {
  return unwrap(result) ?? [];
}
