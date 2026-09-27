import { describe, expect, it } from 'vitest';
import type { MessageTemplate } from '../api';
import {
  draftFromRow,
  insertPlaceholder,
  offsetDraftFrom,
  offsetError,
  patchFor,
  validateDraft,
} from './drafts';
import { describeOffset, offsetFromInput, previewVars, templateMeta, TEMPLATE_KEYS } from './meta';
import { placeholdersIn, renderTemplate, smsSegments } from './render';

describe('renderTemplate (parity with SQL render_template)', () => {
  it('substitutes names with optional spaces/tabs, case-sensitively', () => {
    expect(renderTemplate('Hi {{ name }}, {{\tname\t}}! {{Name}}', { name: 'Ana' })).toBe(
      'Hi Ana, Ana! ',
    );
  });

  it('renders strings verbatim, numbers in JSON form, booleans, and blanks the rest', () => {
    expect(
      renderTemplate('{{s}}|{{n}}|{{f}}|{{b}}|{{z}}|{{o}}|{{a}}|{{missing}}', {
        s: '$1,234.56',
        n: 1001,
        f: 1.5,
        b: true,
        z: null,
        o: { x: 1 },
        a: [1],
      }),
    ).toBe('$1,234.56|1001|1.5|true||||');
  });

  it('never uses exponent form for numbers', () => {
    expect(renderTemplate('{{n}}', { n: 1e21 })).toBe('1000000000000000000000');
  });

  it('is single pass: substituted values are not re-scanned', () => {
    expect(renderTemplate('{{a}}', { a: '{{b}}', b: 'x' })).toBe('{{b}}');
  });

  it('leaves malformed placeholders untouched', () => {
    expect(renderTemplate('{{ a b }} {x} {{1a}} {{a', { a: 'A' })).toBe('{{ a b }} {x} {{1a}} {{a');
  });

  it('does not read inherited properties', () => {
    expect(renderTemplate('{{toString}}', {})).toBe('');
  });

  it('lists placeholders once, in order', () => {
    expect(placeholdersIn('{{b}} {{a}} {{ b }}')).toEqual(['b', 'a']);
  });
});

describe('smsSegments', () => {
  it('counts GSM-7 and unicode segments', () => {
    expect(smsSegments('')).toEqual({ segments: 0, unicode: false });
    expect(smsSegments('a'.repeat(160))).toEqual({ segments: 1, unicode: false });
    expect(smsSegments('a'.repeat(161))).toEqual({ segments: 2, unicode: false });
    expect(smsSegments('It’s ready')).toEqual({ segments: 1, unicode: true });
    expect(smsSegments('é'.repeat(71)).unicode).toBe(false);
    expect(smsSegments('😀'.repeat(71))).toEqual({ segments: 2, unicode: true });
  });
});

describe('template meta', () => {
  it('covers every template key exactly once', () => {
    const keys = TEMPLATE_KEYS.map((m) => m.key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(keys).toHaveLength(13);
    expect(templateMeta('invite').channels).toEqual(['email']);
  });

  it('converts offsets to the stored sign and bounds', () => {
    const reminder = templateMeta('appointment_reminder');
    const review = templateMeta('review_request');
    expect(offsetFromInput(reminder, '1', 'days')).toBe(-1440);
    expect(offsetFromInput(reminder, '0', 'hours')).toBe(0);
    expect(offsetFromInput(reminder, '31', 'days')).toBeNull();
    expect(offsetFromInput(review, '2', 'hours')).toBe(120);
    expect(offsetFromInput(review, '365', 'days')).toBe(525600);
    expect(offsetFromInput(review, '1.5', 'hours')).toBeNull();
    expect(offsetFromInput(templateMeta('on_the_way'), '1', 'hours')).toBeNull();
  });

  it('describes offsets in words', () => {
    expect(describeOffset(templateMeta('appointment_reminder'), -1440)).toBe(
      '1 day before the appointment',
    );
    expect(describeOffset(templateMeta('review_request'), 120)).toBe('2 hours after completion');
    expect(describeOffset(templateMeta('follow_up'), 45)).toBe('45 minutes after completion');
    expect(describeOffset(templateMeta('on_the_way'), null)).toBeNull();
  });

  it('fills preview values from the shop and brackets job-specific ones', () => {
    const vars = previewVars({
      name: 'Glacier Detailing',
      phone: '(205) 555-0100',
      reviewUrl: null,
      bookingPageUrl: 'https://app.test/book/glacier',
    });
    expect(renderTemplate('{{shop_name}} {{shop_phone}} {{booking_page_link}}', vars)).toBe(
      'Glacier Detailing (205) 555-0100 https://app.test/book/glacier',
    );
    expect(vars.customer_first_name).toBe('[customer first name]');
    expect(vars.review_link).toBe('[review link]');
    expect(vars.amount).toBe('[amount]');
  });
});

const row = (over: Partial<MessageTemplate> = {}): MessageTemplate => ({
  id: 't1',
  key: 'booking_confirmed',
  channel: 'email',
  subject: 'Confirmed',
  body: 'Hi {{customer_first_name}}',
  enabled: true,
  offset_minutes: null,
  updated_at: '2026-01-01T00:00:00Z',
  ...over,
});

describe('template drafts', () => {
  it('validates body and subject like the CHECK constraints', () => {
    const email = draftFromRow(row());
    expect(validateDraft('email', { ...email, subject: ' ' })).toEqual({
      subject: 'Add a subject line.',
    });
    expect(validateDraft('sms', { ...email, body: 'x'.repeat(1601) }).body).toMatch(/1,600/);
    expect(validateDraft('sms', { ...email, subject: '', body: 'ok' })).toEqual({});
  });

  it('builds minimal patches', () => {
    const r = row();
    expect(patchFor(r, draftFromRow(r))).toEqual({});
    expect(patchFor(r, { ...draftFromRow(r), enabled: false, subject: ' New ' })).toEqual({
      enabled: false,
      subject: 'New',
    });
    const sms = row({ channel: 'sms', subject: null });
    expect(patchFor(sms, { ...draftFromRow(sms), subject: 'ignored' })).toEqual({});
  });

  it('flags invalid offsets', () => {
    const meta = templateMeta('appointment_reminder');
    expect(offsetDraftFrom(-1440)).toMatchObject({ value: '1', unit: 'days' });
    expect(offsetError(meta, { base: null, value: 'x', unit: 'hours' })).toMatch(/30 days/);
    expect(offsetError(meta, { base: null, value: '3', unit: 'hours' })).toBeUndefined();
  });

  it('inserts placeholders at the caret', () => {
    expect(insertPlaceholder('Hi !', 'shop_name', 3, 3)).toEqual({
      text: 'Hi {{shop_name}}!',
      caret: 16,
    });
    expect(insertPlaceholder('Hi XX', 'a', 3, 5).text).toBe('Hi {{a}}');
  });
});
