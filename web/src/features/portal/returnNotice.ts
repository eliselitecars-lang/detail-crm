import type { BannerTone } from '@/features/public-docs/shared/PublicPage';

/** Stripe Checkout return parameters the payments function puts on /portal links. */
export const RETURN_PARAMS = ['card', 'membership'] as const;

/** Wait before re-reading the overview after a membership sign-up (the webhook activates it). */
export const MEMBERSHIP_REFRESH_MS = 5000;

export interface ReturnNotice {
  tone: BannerTone;
  title: string;
}

/** The banner for a ?card= / ?membership= return value; null for unknown values. */
export function returnNotice(
  param: (typeof RETURN_PARAMS)[number],
  value: string | null,
  shopName: string | null,
): ReturnNotice | null {
  if (param === 'card') {
    if (value === 'saved') {
      return {
        tone: 'success',
        title: `Your card was saved. ${shopName ?? 'The shop'} can now charge it for future visits.`,
      };
    }
    if (value === 'canceled') return { tone: 'info', title: 'No card was saved.' };
    return null;
  }
  if (value === 'active') {
    return {
      tone: 'success',
      title: 'Thanks! Your membership is being activated — it can take a minute to show as active.',
    };
  }
  if (value === 'canceled') {
    return { tone: 'info', title: 'Membership sign-up was cancelled; nothing was charged.' };
  }
  return null;
}
