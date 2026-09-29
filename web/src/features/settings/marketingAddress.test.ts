import { describe, expect, it } from 'vitest';
import { blockedMarketingEmailText, hasMailingAddress } from './marketingAddress';

describe('hasMailingAddress (comms_shop_postal_address, 0119)', () => {
  it('needs a non-blank street line and city', () => {
    expect(hasMailingAddress({ address_line1: '1 Main St', city: 'Birmingham' })).toBe(true);
    expect(hasMailingAddress({ address_line1: null, city: 'Birmingham' })).toBe(false);
    expect(hasMailingAddress({ address_line1: '1 Main St', city: null })).toBe(false);
    expect(hasMailingAddress({ address_line1: '   ', city: 'Birmingham' })).toBe(false);
    expect(hasMailingAddress({ address_line1: '1 Main St', city: ' ' })).toBe(false);
  });
});

describe('blockedMarketingEmailText', () => {
  it('names the follow-ups that are on, and nothing for other keys', () => {
    expect(blockedMarketingEmailText(['follow_up'])).toBe(
      'Rebooking follow-up emails are on but aren’t being sent.',
    );
    expect(blockedMarketingEmailText(['service_followup'])).toBe(
      'Maintenance follow-up emails are on but aren’t being sent.',
    );
    expect(blockedMarketingEmailText(['service_followup', 'follow_up'])).toBe(
      'Rebooking and maintenance follow-up emails are on but aren’t being sent.',
    );
    expect(blockedMarketingEmailText(['appointment_reminder'])).toBeNull();
    expect(blockedMarketingEmailText([])).toBeNull();
  });
});
