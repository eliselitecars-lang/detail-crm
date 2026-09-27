import { formatPhone } from '@/lib/phone';
import { customerName, type ThreadRef, type ThreadSummary } from './model';

/** Search string that selects a thread on /app/messages. */
export function threadSearch(ref: ThreadRef): string {
  return ref.kind === 'customer'
    ? `?customer=${encodeURIComponent(ref.customerId)}`
    : `?from=${encodeURIComponent(ref.from)}`;
}

export function threadTitle(thread: Pick<ThreadSummary, 'ref' | 'customer'>): string {
  if (thread.ref.kind === 'unknown') return formatPhone(thread.ref.from) || thread.ref.from;
  return customerName(thread.customer);
}

/** Reads the selected thread from the URL (?customer=<id> or ?from=<E.164>). */
export function refFromSearch(params: URLSearchParams): ThreadRef | null {
  const customerId = params.get('customer');
  if (customerId) return { kind: 'customer', customerId };
  const from = params.get('from');
  if (from) return { kind: 'unknown', from };
  return null;
}
