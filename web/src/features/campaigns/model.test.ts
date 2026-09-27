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
  smsNeedsStopFooter,
  campaignBodyMax,
  EMAIL_FOOTER_RESERVE,
  hasPlaceholders,
  hasUnsubscribeLink,
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

  it('knows when the STOP footer is appended', () => {
    expect(smsNeedsStopFooter('Deal inside')).toBe(true);
    expect(smsNeedsStopFooter('Reply STOP to quit')).toBe(false);
    expect(smsNeedsStopFooter('Deals! text "stop" to end')).toBe(false);
    expect(smsNeedsStopFooter('Stop by this Saturday for our spring special!')).toBe(true);
  });

  it('reserves room for the footer the server appends', () => {
    expect(campaignBodyMax('sms', 'Deal inside')).toBe(1577);
    expect(campaignBodyMax('sms', 'Reply STOP to quit')).toBe(1600);
    expect(campaignBodyMax('email', 'Hi')).toBe(50000 - EMAIL_FOOTER_RESERVE);
    expect(campaignBodyMax('email', 'Bye: {{ unsubscribe_link }}')).toBe(50000);

    const fits = campaignFormSchema.safeParse({ ...base, body: 'x'.repeat(1577) });
    expect(fits.success).toBe(true);
    const cut = campaignFormSchema.safeParse({ ...base, body: 'x'.repeat(1578) });
    expect(cut.error?.issues[0]?.message).toMatch(/1,577 characters.*Reply STOP/);
    const withStop = campaignFormSchema.safeParse({
      ...base,
      body: `${'x'.repeat(1580)} Reply STOP to quit`,
    });
    expect(withStop.success).toBe(true);
  });

  it('spots placeholders and unsubscribe links', () => {
    expect(hasPlaceholders('Hi {{customer_name}}!')).toBe(true);
    expect(hasPlaceholders('Hi there {not one}')).toBe(false);
    expect(hasUnsubscribeLink('{{unsubscribe_link}}')).toBe(true);
    expect(hasUnsubscribeLink('{{review_link}}')).toBe(false);
  });
});
