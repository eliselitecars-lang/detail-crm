/**
 * Type helpers over the generated `Database` type. Features use these instead
 * of reaching into `Database['public'][...]` so a regenerated
 * `database.types.ts` drops in without edits.
 */
import type { PostgrestError } from '@supabase/supabase-js';
import type { Database } from './database.types';
import { AppError, toAppError } from './errors';

type PublicSchema = Database['public'];

export type TableName = Extract<keyof PublicSchema['Tables'], string>;
export type Row<T extends TableName> = PublicSchema['Tables'][T]['Row'];
export type InsertRow<T extends TableName> = PublicSchema['Tables'][T]['Insert'];
export type UpdateRow<T extends TableName> = PublicSchema['Tables'][T]['Update'];
export type RpcName = Extract<keyof PublicSchema['Functions'], string>;
export type RpcArgs<F extends RpcName> = PublicSchema['Functions'][F]['Args'];
export type RpcReturns<F extends RpcName> = PublicSchema['Functions'][F]['Returns'];

interface SupabaseResult<T> {
  data: T;
  error: PostgrestError | null;
}

/**
 * Unwraps a supabase-js `{ data, error }` result: throws an `AppError` with a
 * user-friendly message on error, returns `data` otherwise. Use inside
 * TanStack Query `queryFn` / `mutationFn` so errors flow to `error` states.
 */
export function unwrap<T>(result: SupabaseResult<T>): T {
  if (result.error) throw toAppError(result.error);
  return result.data;
}

/** Like `unwrap` but also rejects a `null` result (e.g. `.maybeSingle()` miss). */
export function unwrapRequired<T>(result: SupabaseResult<T | null>, what = 'record'): T {
  const data = unwrap(result);
  if (data === null || data === undefined) {
    throw new AppError(`That ${what} could not be found.`, { kind: 'not_found' });
  }
  return data;
}
