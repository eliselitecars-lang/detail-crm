import { describe, expect, it } from 'vitest';
import { sendMessageBody } from './edge';
import { formatDayLabel, formatListTime } from './format';
import {
  channelAvailability,
  CUSTOMER_TEMPLATE_KEYS,
  customerName,
  formatTemplateVariables,
  JOB_TEMPLATE_KEYS,
  messagePreview,
  SENDABLE_TEMPLATE_KEYS,
  smsSegments,
  threadFromRow,
  threadKey,
  threadsFromPages,
  type InboxThreadRow,
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
const row = (over: Partial<InboxThreadRow> = {}): InboxThreadRow => ({
  thread_key: 'c:c1',
  customer_id: 'c1',
  from_address: '+12055550101',
  customer_first_name: 'Casey',
  customer_last_name: 'Jones',
  customer_company: null,
  last_message_id: `m${++seq}`,
  last_direction: 'outbound',
  last_channel: 'sms',
  last_status: 'sent',
  last_body: 'Hello',
  last_created_at: '2026-03-01T10:00:00Z',
  unread_count: 0,
  ...over,
});

describe('threadFromRow', () => {
  it('maps a customer thread with its newest message and unread count', () => {
    const thread = threadFromRow(row({ unread_count: 2, last_body: 'See you soon' }));
    expect(thread).toMatchObject({
      key: 'c:c1',
      ref: { kind: 'customer', customerId: 'c1' },
      customer: { first_name: 'Casey', last_name: 'Jones', company: null },
      last: { body: 'See you soon', direction: 'outbound', channel: 'sms' },
      unread: 2,
    });
  });

  it('keys conversations without a customer by the counterpart address', () => {
    const thread = threadFromRow(
      row({
        thread_key: 'a:+12055550199',
        customer_id: null,
        from_address: '+12055550199',
        customer_first_name: null,
        customer_last_name: null,
        last_direction: 'inbound',
        last_status: 'received',
      }),
    );
    expect(thread?.ref).toEqual({ kind: 'unknown', from: '+12055550199' });
    expect(thread?.key).toBe('u:+12055550199');
    expect(thread?.customer).toBeNull();
    // falls back to the address in the key; a row with neither is dropped
    expect(
      threadFromRow(
        row({ thread_key: 'a:jane@example.com', customer_id: null, from_address: null }),
      )?.ref,
    ).toEqual({ kind: 'unknown', from: 'jane@example.com' });
    expect(
      threadFromRow(row({ thread_key: 'x', customer_id: null, from_address: null })),
    ).toBeNull();
  });
});

describe('threadsFromPages', () => {
  it('keeps the server order and lists each conversation once across pages', () => {
    const threads = threadsFromPages([
      [
        row({ last_created_at: '2026-03-03T00:00:00Z' }),
        row({ thread_key: 'c:c2', customer_id: 'c2' }),
      ],
      [
        row({ last_created_at: '2026-03-01T00:00:00Z' }),
        row({ thread_key: 'c:c3', customer_id: 'c3' }),
      ],
    ]);
    expect(threads.map((t) => t.key)).toEqual(['c:c1', 'c:c2', 'c:c3']);
    expect(threads[0]?.last.created_at).toBe('2026-03-03T00:00:00Z');
  });
});

describe('template keys', () => {
  it('splits sendable keys into job-only and customer-level ones', () => {
    expect(SENDABLE_TEMPLATE_KEYS).not.toContain('invite');
    expect([...CUSTOMER_TEMPLATE_KEYS].sort()).toEqual([
      'follow_up',
      'membership_welcome',
      'review_request',
    ]);
    expect(JOB_TEMPLATE_KEYS.has('quote_sent')).toBe(true);
    expect(JOB_TEMPLATE_KEYS.has('on_the_way')).toBe(true);
    expect(JOB_TEMPLATE_KEYS.has('review_request')).toBe(false);
    expect(JOB_TEMPLATE_KEYS.size + CUSTOMER_TEMPLATE_KEYS.size).toBe(
      SENDABLE_TEMPLATE_KEYS.length,
    );
    expect(formatTemplateVariables(['job_date', 'vehicle'])).toBe('{{job_date}}, {{vehicle}}');
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
      channelAvailability(customer({ email_opted_out_at: '2026-01-01T00:00:00Z' }), 'email'),
    ).toEqual({ available: false, reason: 'Opted out of all email from your shop.' });
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
    expect(
      sendMessageBody({
        shopId: 's1',
        customerId: 'c1',
        channel: 'sms',
        jobId: null,
        content: { kind: 'text', subject: null, body: 'Hi' },
        requestNonce: 'nonce_1234',
      }),
    ).toMatchObject({ body: 'Hi', request_nonce: 'nonce_1234' });
  });
});
