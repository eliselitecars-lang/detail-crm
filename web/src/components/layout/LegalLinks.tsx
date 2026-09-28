import { Link } from 'react-router';
import { PRIVACY_PATH, TERMS_PATH } from '@/features/legal/paths';
import { cn } from '@/lib/cn';

/**
 * Links to the operator's Privacy Policy and Terms of Service (public
 * /privacy and /terms). Used under the auth pages, in the public page footer
 * and on /account. `fullPageLoad` makes them plain links that leave the
 * document (a public booking page with the shop's analytics tag loaded: the
 * tag must not see the next page, features/booking/tracking.ts).
 */
export function LegalLinks({
  className,
  fullPageLoad = false,
}: {
  className?: string;
  fullPageLoad?: boolean;
}) {
  const link = 'rounded-control hover:text-ink underline-offset-2 hover:underline';
  return (
    <nav
      aria-label="Legal"
      className={cn('flex flex-wrap items-center justify-center gap-x-4 gap-y-1', className)}
    >
      {fullPageLoad ? (
        <>
          <a href={PRIVACY_PATH} className={link}>
            Privacy Policy
          </a>
          <a href={TERMS_PATH} className={link}>
            Terms of Service
          </a>
        </>
      ) : (
        <>
          <Link to={PRIVACY_PATH} className={link}>
            Privacy Policy
          </Link>
          <Link to={TERMS_PATH} className={link}>
            Terms of Service
          </Link>
        </>
      )}
    </nav>
  );
}
