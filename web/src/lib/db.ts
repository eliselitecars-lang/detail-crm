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
/**
 * Keys the type generator adds to a table's Row for a SQL function that takes
 * the row and returns void (e.g. `money_refuse_open_checkout(invoices)`,
 * typed `undefined | null`): computed fields PostgREST can embed, never real
 * columns (a column's Row type never admits `undefined`).
 */
type VoidComputedKeys<R> = { [K in keyof R]-?: undefined extends R[K] ? K : never }[keyof R];

export type Row<T extends TableName> = Omit<
  PublicSchema['Tables'][T]['Row'],
  VoidComputedKeys<PublicSchema['Tables'][T]['Row']>
>;
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

/**
 * PostgREST's `max_rows` (the hosted Supabase default, and
 * supabase/config.toml locally): no table, view or RPC response carries more
 * rows than this, whatever `.limit()` / `.range()` asks for — the rest is cut
 * silently. Anything that needs more reads it in pages (`readPages`).
 */
export const POSTGREST_MAX_ROWS = 1000;

/** One page of a select: supabase-js's `{ data, error, count }`. */
export type PageResult<T> = PromiseLike<{
  data: T[] | null;
  error: PostgrestError | null;
  count?: number | null;
}>;
// (A builder whose select string is assembled at runtime is typed with
// supabase-js's GenericStringError rows: read those as `unknown` and parse.)

export interface PagedRows<T> {
  rows: T[];
  /** Rows matching the query (the first page's exact count), or null when not reported. */
  total: number | null;
  /** More rows matched than `limit`: the result is the first `limit` of them. */
  truncated: boolean;
}

/**
 * Reads up to `limit` rows of an ORDERED select in pages of at most
 * POSTGREST_MAX_ROWS. `page(from, to, withCount)` returns the rows
 * [from, to] — `.range(from, to)` — and, when `withCount`, the exact match
 * count (`select(…, { count: 'exact' })`, asked on the first page only).
 * Paging continues from however many rows actually came back until
 * min(count, limit) are read, so a server cap below 1,000 still reads
 * everything. Rows are de-duplicated by `key` (a row inserted meanwhile can
 * shift an offset page by one); order the query with a unique tiebreaker
 * (e.g. `id`) so pages are stable.
 */
export async function readPages<T>(
  page: (from: number, to: number, withCount: boolean) => PageResult<T>,
  { limit, key }: { limit: number; key: (row: T) => string },
): Promise<PagedRows<T>> {
  const rows: T[] = [];
  const seen = new Set<string>();
  let total: number | null = null;
  let offset = 0;
  for (let first = true; ; first = false) {
    const target = total === null ? limit : Math.min(total, limit);
    if (offset >= target) break;
    const size = Math.min(POSTGREST_MAX_ROWS, target - offset);
    const result = await page(offset, offset + size - 1, first);
    const data = unwrap({ data: result.data, error: result.error }) ?? [];
    // postgrest-js reports an unknown count (`Content-Range: …/*`) as NaN.
    if (first && typeof result.count === 'number' && Number.isFinite(result.count)) {
      total = Math.max(result.count, 0);
    }
    for (const row of data) {
      const id = key(row);
      if (seen.has(id)) continue;
      seen.add(id);
      rows.push(row);
    }
    offset += data.length;
    // Nothing more came back (rows deleted meanwhile), or — with no count to
    // go by — a short page is the end.
    if (data.length === 0 || (total === null && data.length < size)) break;
  }
  const truncated = total !== null ? total > limit : offset >= limit;
  return { rows: rows.slice(0, limit), total, truncated };
}
