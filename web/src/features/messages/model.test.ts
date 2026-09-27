import { describe, expect, it } from 'vitest';
import { sendMessageBody } from './edge';
import { formatDayLabel, formatListTime } from './format';
import {
  buildThreads,
  channelAvailability,
  customerName,
  messagePreview,
  smsSegments,
  threadKey,
  unreadThreadsOutside,
  type InboxMessage,
  type ThreadCustomer,
} from './model';
import { refFromSearch, threadSearch } from './threadUtils';

const customer = (over: Partial<ThreadCustomer> = {}): ThreadCustomer => ({
  id: 'c1',
  first_name: 'Casey',
  last_name: 'Jones',
  company: null,
  phone: '+12055550101',
  email: 'casey@example.com',
  sms_opt_in: true,
  email_opt_in: false,
  sms_opted_out_at: null,
  email_opted_out_at: null,
  archived_at: null,
  ...over,
});

let seq = 0;
const msg = (over: Partial<InboxMessage> = {}): InboxMessage => ({
  id: `m${++seq}`,
  customer_id: 'c1',
  job_id: null,
  campaign_id: null,
  direction: 'outbound',
  channel: 'sms',
  to_address: '+12055550101',
  from_address: null,
  subject: null,
  body: 'Hello',
  status: 'sent',
  error: null,
  template_key: null,
  read_at: null,
  send_after: '2026-03-01T10:00:00Z',
  sent_at: null,
  delivered_at: null,
  created_at: '2026-03-01T10:00:00Z',
  customer: customer(),
  ...over,
});

describe('buildThreads', () => {
  it('groups by customer, newest thread first, latest message as preview', () => {
    const threads = buildThreads(
      [
        msg({ body: 'old', created_at: '2026-03-01T09:00:00Z' }),
        msg({ body: 'newest c1', created_at: '2026-03-03T09:00:00Z' }),
        msg({
          customer_id: 'c2',
          customer: customer({ id: 'c2', first_name: 'Dana' }),
          body: 'c2',
          created_at: '2026-03-02T09:00:00Z',
        }),
      ],
      [],
    );
    expect(threads.map((t) => t.key)).toEqual(['c:c1', 'c:c2']);
    expect(threads[0]?.last.body).toBe('newest c1');
    expect(threads[1]?.customer?.first_name).toBe('Dana');
  });

  it('counts unread inbound per thread and groups unknown senders by number', () => {
    const threads = buildThreads(
      [
        msg({ direction: 'inbound', status: 'received', from_address: '+12055550101' }),
        msg({
          customer_id: null,
          customer: null,
          direction: 'inbound',
          status: 'received',
          from_address: '+12055550199',
          created_at: '2026-03-05T00:00:00Z',
        }),
      ],
      [
        { customer_id: 'c1', from_address: '+12055550101' },
        { customer_id: 'c1', from_address: '+12055550101' },
        { customer_id: null, from_address: '+12055550199' },
      ],
    );
    expect(threads.map((t) => [t.key, t.unread])).toEqual([
      ['u:+12055550199', 1],
      ['c:c1', 2],
    ]);
    expect(threads[0]?.ref).toEqual({ kind: 'unknown', from: '+12055550199' });
  });

  it('skips outbound rows without a customer', () => {
    expect(buildThreads([msg({ customer_id: null, customer: null })], [])).toEqual([]);
  });
});

describe('unreadThreadsOutside', () => {
  const row = (
    id: string,
    customer_id: string | null,
    created_at: string,
    from: string | null = '+1205',
  ) => ({
    id,
    customer_id,
    from_address: from,
    created_at,
  });

  it('returns the newest unread message of each thread missing from the page', () => {
    const unread = [
      row('u1', 'c1', '2026-03-01T09:00:00Z'),
      row('u2', 'c1', '2026-03-02T09:00:00Z'),
      row('u3', 'c2', '2026-03-03T09:00:00Z'),
      row('u4', null, '2026-03-04T09:00:00Z', '+12055550199'),
      row('u5', 'c3', '2026-03-05T09:00:00Z'),
      row('u6', null, '2026-03-06T09:00:00Z', null),
    ];
    expect(unreadThreadsOutside(new Set(['c:c3']), unread, 10)).toEqual(['u4', 'u3', 'u2']);
    expect(unreadThreadsOutside(new Set(['c:c3']), unread, 2)).toEqual(['u4', 'u3']);
    expect(
      unreadThreadsOutside(new Set(['c:c1', 'c:c2', 'c:c3', 'u:+12055550199']), unread, 10),
    ).toEqual([]);
  });
});

describe('channelAvailability', () => {
  it('blocks missing addresses and opt-outs', () => {
    expect(channelAvailability(customer(), 'sms')).toEqual({ available: true, reason: null });
    expect(channelAvailability(customer({ phone: null }), 'sms').available).toBe(false);
    expect(
      channelAvailability(customer({ sms_opted_out_at: '2026-01-01T00:00:00Z' }), 'sms').reason,
    ).toMatch(/STOP/);
    expect(channelAvailability(customer({ email: null }), 'email').available).toBe(false);
    expect(
      channelAvailability(customer({ email_opted_out_at: '2026-01-01T00:00:00Z' }), 'email')
        .available,
    ).toBe(false);
  });

  it('does not require marketing opt-in for one-to-one messages', () => {
    expect(channelAvailability(customer({ email_opt_in: false }), 'email').available).toBe(true);
  });
});

describe('helpers', () => {
  it('names customers', () => {
    expect(customerName(customer())).toBe('Casey Jones');
    expect(customerName(customer({ first_name: null, last_name: null, company: 'Fleet Co' }))).toBe(
      'Fleet Co',
    );
    expect(customerName(null)).toBe('Unknown customer');
  });

  it('previews and counts SMS segments', () => {
    expect(messagePreview({ body: ' a\n b ', subject: null, channel: 'sms' })).toBe('a b');
    expect(messagePreview({ body: '', subject: 'Hi', channel: 'email' })).toBe('Hi');
    expect(smsSegments('')).toBe(0);
    expect(smsSegments('x'.repeat(160))).toBe(1);
    expect(smsSegments('x'.repeat(161))).toBe(2);
    expect(smsSegments('🚗'.repeat(40))).toBe(2); // UCS-2: 80 code units > 70
  });

  it('round-trips thread refs through the URL', () => {
    const ref = { kind: 'unknown', from: '+12055550199' } as const;
    expect(refFromSearch(new URLSearchParams(threadSearch(ref)))).toEqual(ref);
    expect(refFromSearch(new URLSearchParams('?customer=abc'))).toEqual({
      kind: 'customer',
      customerId: 'abc',
    });
    expect(refFromSearch(new URLSearchParams(''))).toBeNull();
    expect(threadKey({ kind: 'customer', customerId: 'x' })).toBe('c:x');
  });

  it('formats times in the shop zone, not the browser zone', () => {
    const now = new Date('2026-03-10T15:00:00Z'); // 10:00 AM in Chicago (CDT)
    expect(formatListTime('2026-03-10T14:30:00Z', 'America/Chicago', now)).toBe('9:30 AM');
    expect(formatListTime('2026-03-02T14:30:00Z', 'America/Chicago', now)).toBe('Mar 2');
    expect(formatListTime('2025-03-02T14:30:00Z', 'America/Chicago', now)).toBe('3/2/25');
    expect(formatDayLabel('2026-03-10', 'America/Chicago', now)).toBe('Today');
    expect(formatDayLabel('2026-03-09', 'America/Chicago', now)).toBe('Yesterday');
    expect(formatDayLabel('2026-03-01', 'America/Chicago', now)).toBe('Sun, Mar 1, 2026');
  });
});

describe('sendMessageBody', () => {
  it('builds free-form and template payloads without prices or addresses', () => {
    expect(
      sendMessageBody({
        shopId: 's1',
        customerId: 'c1',
        channel: 'email',
        jobId: null,
        content: { kind: 'text', subject: 'Hi', body: 'Hello' },
      }),
    ).toEqual({
      action: 'send',
      shop_id: 's1',
      customer_id: 'c1',
      channel: 'email',
      subject: 'Hi',
      body: 'Hello',
    });
    expect(
      sendMessageBody({
        shopId: 's1',
        customerId: 'c1',
        channel: 'sms',
        jobId: 'j1',
        content: { kind: 'template', templateKey: 'on_the_way' },
      }),
    ).toEqual({
      action: 'send',
      shop_id: 's1',
      customer_id: 'c1',
      channel: 'sms',
      job_id: 'j1',
      template_key: 'on_the_way',
    });
  });
});
