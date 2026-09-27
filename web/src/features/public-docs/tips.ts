/**
 * Optional tip on the public invoice. The payments edge function accepts a
 * whole-cent tip with 0 <= tip <= balance (payments/lib.ts boundedTip); the
 * balance itself always comes from the server.
 */
export type TipChoice = 'none' | '15' | '20' | 'custom';

/** Tip in cents for a choice, or null when a custom amount is missing/out of range. */
export function tipCents(
  choice: TipChoice,
  balanceCents: number,
  customCents: number | null,
): number | null {
  const balance = Math.max(0, Math.trunc(balanceCents));
  switch (choice) {
    case 'none':
      return 0;
    case '15':
    case '20': {
      const pct = Number(choice);
      return Math.min(balance, Math.round((balance * pct) / 100));
    }
    case 'custom':
      if (customCents === null || !Number.isInteger(customCents)) return null;
      if (customCents < 0 || customCents > balance) return null;
      return customCents;
  }
}
