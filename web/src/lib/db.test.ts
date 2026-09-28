import type { PostgrestError } from '@supabase/supabase-js';
import { describe, expect, it } from 'vitest';
import { POSTGREST_MAX_ROWS, readPages } from './db';

interface R {
  id: string;
}

/** A fake PostgREST that caps every response at `maxRows` (like max_rows). */
function server(count: number, maxRows = POSTGREST_MAX_ROWS, reportCount = true) {
  const all: R[] = Array.from({ length: count }, (_, i) => ({ id: `r${i}` }));
  const calls: { from: number; to: number; withCount: boolean }[] = [];
  const page = (from: number, to: number, withCount: boolean) => {
    calls.push({ from, to, withCount });
    const data = all.slice(from, Math.min(to + 1, from + maxRows));
    return Promise.resolve({
      data,
      error: null,
      count: withCount && reportCount ? all.length : null,
    });
  };
  return { page, calls };
}

const key = (r: R) => r.id;

describe('readPages (PostgREST max_rows)', () => {
  it('reads past 1,000 rows in pages and reports nothing was cut', async () => {
    const { page, calls } = server(2500);
    const result = await readPages(page, { limit: 5000, key });
    expect(result.rows).toHaveLength(2500);
    expect(result.rows.at(-1)).toEqual({ id: 'r2499' });
    expect(result).toMatchObject({ total: 2500, truncated: false });
    expect(calls).toEqual([
      { from: 0, to: 999, withCount: true },
      { from: 1000, to: 1999, withCount: false },
      { from: 2000, to: 2499, withCount: false },
    ]);
  });

  it('stops at the limit and says the result is truncated', async () => {
    const { page } = server(2600);
    const result = await readPages(page, { limit: 2000, key });
    expect(result.rows).toHaveLength(2000);
    expect(result).toMatchObject({ total: 2600, truncated: true });
  });

  it('exactly the limit is not truncated', async () => {
    const { page } = server(2000);
    const result = await readPages(page, { limit: 2000, key });
    expect(result.rows).toHaveLength(2000);
    expect(result.truncated).toBe(false);
  });

  it('keeps going when the server caps pages below 1,000 (the count decides)', async () => {
    const { page, calls } = server(1200, 500);
    const result = await readPages(page, { limit: 5000, key });
    expect(result.rows).toHaveLength(1200);
    expect(result.truncated).toBe(false);
    expect(calls.map((c) => c.from)).toEqual([0, 500, 1000]);
  });

  it('without a count, a short page is the end', async () => {
    const { page, calls } = server(1500, POSTGREST_MAX_ROWS, false);
    const result = await readPages(page, { limit: 5000, key });
    expect(result.rows).toHaveLength(1500);
    expect(result).toMatchObject({ total: null, truncated: false });
    expect(calls).toHaveLength(2);
  });

  it('an unknown count (NaN from Content-Range */*) reads like no count, never loops', async () => {
    const calls: number[] = [];
    const page = (from: number) => {
      calls.push(from);
      return Promise.resolve({ data: [{ id: `r${from}` }], error: null, count: Number.NaN });
    };
    const result = await readPages(page, { limit: 5000, key });
    expect(result).toMatchObject({ rows: [{ id: 'r0' }], total: null, truncated: false });
    expect(calls).toEqual([0]);
  });

  it('drops a row repeated across pages (inserted meanwhile)', async () => {
    let n = 0;
    const page = (from: number, to: number) => {
      n += 1;
      // The second page starts one row early (a newer row pushed everything down).
      const start = n === 1 ? from : from - 1;
      const data = Array.from({ length: to - from + 1 }, (_, i) => ({
        id: `r${start + i}`,
      })).filter((r) => Number(r.id.slice(1)) < 1500);
      return Promise.resolve({ data, error: null, count: n === 1 ? 1500 : null });
    };
    const result = await readPages(page, { limit: 5000, key });
    expect(new Set(result.rows.map((r) => r.id)).size).toBe(result.rows.length);
  });

  it('throws the server error', async () => {
    const page = () =>
      Promise.resolve({
        data: null,
        error: {
          code: '42501',
          message: 'denied',
          details: '',
          hint: '',
        } as unknown as PostgrestError,
        count: null,
      });
    await expect(readPages(page, { limit: 10, key })).rejects.toThrow();
  });
});
