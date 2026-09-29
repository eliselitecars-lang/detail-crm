import { render } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { describe, expect, it } from 'vitest';
import { privacyPolicy, termsOfService, type LegalText } from './content';
import { LEGAL_LAST_UPDATED, readLegalOperator, type LegalOperator } from './operator';

/**
 * The "Last updated" date on /privacy and /terms is the only way readers can
 * tell the wording changed (the policy says "The date at the top shows the
 * current version"), so it must move with the text (docs/LAUNCH.md §6).
 *
 * Each entry is a published version: the date shown and a fingerprint of the
 * rendered wording of both pages. When the wording changes, this test fails:
 * APPEND an entry with today's date and the fingerprint the failure prints,
 * and set LEGAL_LAST_UPDATED (operator.ts) to that date. Never edit an
 * existing entry; dates only move forward.
 */
const PUBLISHED_VERSIONS: readonly { date: string; fingerprint: string }[] = [
  {
    date: '2026-09-28',
    fingerprint: '987f50db48e67f87df32583133f6bc5bedfd32a5c83b637a1e0984c9f0d68a96',
  },
  // Membership sign-up IP records (kept seven days); one free trial per
  // person (hashed-email trial record); coupon-code checks on the booking
  // page (IP address and hashed code, kept two days).
  {
    date: '2026-09-29',
    fingerprint: '23685fa23c217d90cae47436a904723ab4ee2ae62f063d98b444b4167356e695',
  },
];

const UNSET: LegalOperator = readLegalOperator({});
const CONFIGURED: LegalOperator = readLegalOperator({
  VITE_LEGAL_ENTITY_NAME: 'Example Operator LLC',
  VITE_SUPPORT_EMAIL: 'privacy@example.com',
  VITE_LEGAL_COUNTRY: 'the State of Alabama, United States',
  VITE_LEGAL_ADDRESS: '1 Example Way\\nBirmingham, AL 35203',
});

/** The visible wording of one page (intro, section titles and bodies), whitespace-normalized. */
function wording(text: LegalText): string {
  const { container, unmount } = render(
    <MemoryRouter>
      {text.intro}
      {text.sections.map((section) => (
        <section key={section.id}>
          <h2>{section.title}</h2>
          {section.body}
        </section>
      ))}
    </MemoryRouter>,
  );
  const words = (container.textContent ?? '').replace(/\s+/g, ' ').trim();
  unmount();
  return words;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function currentFingerprint(): Promise<string> {
  const pages = [UNSET, CONFIGURED].flatMap((operator) => [
    wording(privacyPolicy(operator)),
    wording(termsOfService(operator)),
  ]);
  return sha256(pages.join('\n\n'));
}

describe('legal pages version date', () => {
  it('shows the date of the latest published wording', async () => {
    const latest = PUBLISHED_VERSIONS.at(-1);
    const fingerprint = await currentFingerprint();
    expect(
      latest?.fingerprint,
      `The /privacy or /terms wording changed. Append { date: '<today>', fingerprint: '${fingerprint}' } to PUBLISHED_VERSIONS and set LEGAL_LAST_UPDATED (operator.ts) to that date.`,
    ).toBe(fingerprint);
    expect(LEGAL_LAST_UPDATED.iso).toBe(latest?.date);
  });

  it('keeps one entry per version, with dates only moving forward', () => {
    const dates = PUBLISHED_VERSIONS.map((version) => version.date);
    expect([...dates].sort()).toEqual(dates);
    expect(new Set(dates).size).toBe(dates.length);
    const fingerprints = PUBLISHED_VERSIONS.map((version) => version.fingerprint);
    expect(new Set(fingerprints).size).toBe(fingerprints.length);
  });

  it('labels the date the way it is written in ISO form', () => {
    expect(LEGAL_LAST_UPDATED.iso).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const label = new Date(`${LEGAL_LAST_UPDATED.iso}T12:00:00Z`).toLocaleDateString('en-US', {
      timeZone: 'UTC',
      month: 'long',
      day: 'numeric',
      year: 'numeric',
    });
    expect(LEGAL_LAST_UPDATED.label).toBe(label);
  });
});
