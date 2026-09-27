/**
 * Customers list state <-> URL search params, so filters survive reloads and
 * can be linked (e.g. /app/customers?tag=VIP&lifecycle=lead).
 */
import type { ArchivedFilter, CustomerListFilters, CustomerSortKey } from './api';
import { isLifecycle } from './model';

export const PAGE_SIZE = 25;

const SORT_KEYS: readonly CustomerSortKey[] = ['name', 'created_at', 'updated_at'];
const ARCHIVED: readonly ArchivedFilter[] = ['active', 'archived', 'all'];

export function parseListParams(params: URLSearchParams): CustomerListFilters {
  const sortKey = params.get('sort');
  const dir = params.get('dir');
  const archived = params.get('archived');
  const lifecycle = params.get('lifecycle');
  const page = Number(params.get('page') ?? '1');
  const key: CustomerSortKey = SORT_KEYS.includes(sortKey as CustomerSortKey)
    ? (sortKey as CustomerSortKey)
    : 'name';
  return {
    search: params.get('q') ?? '',
    tag: params.get('tag') || null,
    lifecycle: isLifecycle(lifecycle) ? lifecycle : null,
    archived: ARCHIVED.includes(archived as ArchivedFilter)
      ? (archived as ArchivedFilter)
      : 'active',
    sort: {
      key,
      direction: dir === 'asc' || dir === 'desc' ? dir : key === 'name' ? 'asc' : 'desc',
    },
    page: Number.isInteger(page) && page >= 1 ? page : 1,
    pageSize: PAGE_SIZE,
  };
}

/**
 * Only non-default values are written, keeping URLs short. The search text is
 * written as typed (not trimmed): the search box re-syncs from this value, so
 * trimming here would eat the space after a word when the user pauses
 * ("jane " → "jane" → "janedoe"). Terms are trimmed when patterns are built.
 */
export function toListParams(f: CustomerListFilters): URLSearchParams {
  const params = new URLSearchParams();
  if (f.search.trim()) params.set('q', f.search);
  if (f.tag) params.set('tag', f.tag);
  if (f.lifecycle) params.set('lifecycle', f.lifecycle);
  if (f.archived !== 'active') params.set('archived', f.archived);
  const defaultDir = f.sort.key === 'name' ? 'asc' : 'desc';
  if (f.sort.key !== 'name' || f.sort.direction !== defaultDir) {
    params.set('sort', f.sort.key);
    params.set('dir', f.sort.direction);
  }
  if (f.page > 1) params.set('page', String(f.page));
  return params;
}
