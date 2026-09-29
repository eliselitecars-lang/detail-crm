import type { MessageTemplateKey } from '@/features/messages/model';

/**
 * Marketing email and the shop's mailing address (0119, CAN-SPAM): every
 * marketing email ends with the shop's postal address. Without a street line
 * and a city on file, a campaign launch by email is refused (55000 HINT
 * postal_address_required) and every other marketing email — rebooking and
 * maintenance follow-ups, or one of those templates sent by hand — is simply
 * not queued. These helpers let the settings screens say so.
 */

/** Where the address is edited (Settings → Business profile). */
export const BUSINESS_PROFILE_PATH = '/app/settings/business';

/** Template keys whose email is marketing (comms_is_marketing_key, 0083). */
export const MARKETING_EMAIL_KEYS: ReadonlySet<MessageTemplateKey> = new Set<MessageTemplateKey>([
  'follow_up',
  'service_followup',
]);

/**
 * Mirrors comms_shop_postal_address (0119): the address counts only with a
 * non-blank street line AND a non-blank city.
 */
export function hasMailingAddress(shop: {
  address_line1: string | null;
  city: string | null;
}): boolean {
  return (shop.address_line1 ?? '').trim() !== '' && (shop.city ?? '').trim() !== '';
}

/** The shared sentence: why marketing email stops without the address. */
export const MAILING_ADDRESS_REQUIRED =
  'The law requires your shop’s mailing address in every marketing email, and there’s no street address and city on file.';

/** Business profile's Address card: what the address is used for. */
export const MAILING_ADDRESS_USE =
  'Marketing emails (campaigns, rebooking and maintenance follow-ups) end with this address, as the law requires.';

/** Business profile, while the street line or city is blank. */
export const MAILING_ADDRESS_MISSING =
  'Without a street address and city, marketing email isn’t sent: campaigns can’t be launched by email, and rebooking and maintenance follow-up emails are skipped. Texts and other emails are not affected.';

const FOLLOWUP_NAMES: Record<string, string> = {
  follow_up: 'rebooking',
  service_followup: 'maintenance',
};

/**
 * "Rebooking and maintenance follow-up emails are on but aren’t being sent."
 * for the marketing email keys that are switched on; null for none.
 */
export function blockedMarketingEmailText(keys: readonly MessageTemplateKey[]): string | null {
  const names = [...MARKETING_EMAIL_KEYS]
    .filter((key) => keys.includes(key))
    .map((key) => FOLLOWUP_NAMES[key] ?? key);
  if (names.length === 0) return null;
  const joined = names.join(' and ');
  return `${joined.charAt(0).toUpperCase()}${joined.slice(1)} follow-up emails are on but aren’t being sent.`;
}
