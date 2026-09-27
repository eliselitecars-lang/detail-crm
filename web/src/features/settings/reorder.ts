/** Returns a copy of `list` with the item at `from` moved to `to` (clamped). */
export function moveItem<T>(list: readonly T[], from: number, to: number): T[] {
  const next = [...list];
  if (from < 0 || from >= next.length) return next;
  const target = Math.max(0, Math.min(next.length - 1, to));
  const [item] = next.splice(from, 1);
  if (item !== undefined) next.splice(target, 0, item);
  return next;
}

/**
 * Sort position for a newly added row: one past the largest stored `sort`.
 * Defensive against rows without a finite sort (a NaN here would be sent as
 * `sort: null` and violate the NOT NULL column).
 */
export function nextSortPosition(rows: readonly { sort?: number | null }[]): number {
  let max = 0;
  for (const row of rows) {
    const sort = row.sort;
    if (typeof sort === 'number' && Number.isFinite(sort) && sort > max) max = sort;
  }
  return max + 1;
}
