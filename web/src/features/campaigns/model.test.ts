import { describe, expect, it } from 'vitest';
import {
  audienceFromForm,
  audienceRangeError,
  audienceToForm,
  audienceToJson,
  campaignFormSchema,
  describeAudience,
  EMPTY_AUDIENCE_FORM,
  normalizeTags,
  campaignPreviewSchema,
  hasPlaceholders,
} from './model';

describe('audience', () => {
  it('omits empty filters so "everyone opted in" is {}', () => {
    expect(audienceFromForm(EMPTY_AUDIENCE_FORM)).toEqual({});
    expect(audienceToJson({})).toEqual({});
  });

  it('round-trips the database shape', () => {
    const form = {
      tags: ['VIP', ' fleet '],
      lifecycle: 'customer' as const,
      lastVisitBefore: '2026-01-01',
      lastVisitAfter: '2025-06-01',
    };
    const audience = audienceFromForm(form);
    expect(audience).toEqual({
      tags: ['VIP', 'fleet'],
      lifecycle: 'customer',
      last_visit_before: '2026-01-01',
      last_visit_after: '2025-06-01',
    });
    expect(audienceToForm(audienceToJson(audience))).toEqual({ ...form, tags: ['VIP', 'fleet'] });
  });

  it('treats unknown or invalid stored audiences as empty', () => {
    expect(audienceToForm({ bogus: 1 })).toEqual(EMPTY_AUDIENCE_FORM);
    expect(audienceToForm({ lifecycle: 'vip' })).toEqual(EMPTY_AUDIENCE_FORM);
    expect(audienceToForm(null)).toEqual(EMPTY_AUDIENCE_FORM);
  });

  it('dedupes tags case-insensitively and drops blanks', () => {
    expect(normalizeTags(['VIP', 'vip', ' ', 'Fleet', 'fleet '])).toEqual(['VIP', 'Fleet']);
    expect(normalizeTags(Array.from({ length: 60 }, (_, i) => `t${i}`))).toHaveLength(50);
  });

  it('flags a last-visit window that can never match', () => {
    expect(
      audienceRangeError({
        ...EMPTY_AUDIENCE_FORM,
        lastVisitAfter: '2026-02-01',
        lastVisitBefore: '2026-02-01',
      }),
    ).toMatch(/nobody matches/);
    expect(
      audienceRangeError({
        ...EMPTY_AUDIENCE_FORM,
        lastVisitAfter: '2026-01-01',
        lastVisitBefore: '2026-02-01',
      }),
    ).toBeNull();
  });

  it('describes the audience in plain English', () => {
    expect(describeAudience({}, 'sms')).toBe('Customers opted in to texts');
    expect(
      describeAudience(
        { tags: ['vip', 'fleet'], lifecycle: 'lead', last_visit_before: '2026-01-15' },
        'email',
      ),
    ).toBe(
      'Customers opted in to email, who are leads, tagged “vip” or “fleet”, whose last visit was before Jan 15, 2026',
    );
  });
});

describe('campaignFormSchema', () => {
  const base = {
    name: 'Spring special',
    channel: 'sms' as const,
    subject: '',
    body: 'Hi {{customer_first_name}}',
    sendDate: '',
    sendTime: '',
  };

  it('accepts a minimal SMS draft', () => {
    expect(campaignFormSchema.safeParse(base).success).toBe(true);
  });

  it('requires an email subject, a body within limits and a complete send time', () => {
    const email = campaignFormSchema.safeParse({ ...base, channel: 'email' });
    expect(email.success).toBe(false);
    expect(email.error?.issues[0]?.path).toEqual(['subject']);

    const long = campaignFormSchema.safeParse({ ...base, body: 'x'.repeat(1601) });
    expect(long.error?.issues[0]?.path).toEqual(['body']);

    const half = campaignFormSchema.safeParse({ ...base, sendDate: '2026-04-01' });
    expect(half.error?.issues[0]?.path).toEqual(['sendTime']);
  });

  it('bounds the body by the channel limit only (the server measures the rendered text)', () => {
    expect(campaignFormSchema.safeParse({ ...base, body: 'x'.repeat(1600) }).success).toBe(true);
    const email = { ...base, channel: 'email' as const, subject: 'Spring' };
    expect(campaignFormSchema.safeParse({ ...email, body: 'x'.repeat(50000) }).success).toBe(true);
    expect(
      campaignFormSchema.safeParse({ ...email, body: 'x'.repeat(50001) }).error?.issues[0]?.message,
    ).toBe('Keep it under 50,000 characters.');
  });

  it('parses the server preview', () => {
    expect(
      campaignPreviewSchema.parse({
        subject: null,
        body: 'Hi [first name]\nReply STOP to opt out.',
        body_length: 15,
        max_body_length: 1577,
        footer_added: true,
        truncated: false,
      }).max_body_length,
    ).toBe(1577);
  });

  it('spots placeholders', () => {
    expect(hasPlaceholders('Hi {{customer_name}}!')).toBe(true);
    expect(hasPlaceholders('Hi there {not one}')).toBe(false);
  });
});
