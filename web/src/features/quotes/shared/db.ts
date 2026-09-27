import type { PostgrestError } from '@supabase/supabase-js';
import { unwrap } from '@/lib/db';

/** `unwrap` for list selects: a null payload becomes an empty list. */
export function unwrapList<T>(result: { data: T[] | null; error: PostgrestError | null }): T[] {
  return unwrap(result) ?? [];
}
