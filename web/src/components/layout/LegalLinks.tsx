import { Link } from 'react-router';
import { PRIVACY_PATH, TERMS_PATH } from '@/features/legal/paths';
import { cn } from '@/lib/cn';

/**
 * Links to the operator's Privacy Policy and Terms of Service (public
 * /privacy and /terms). Used under the auth pages, in the public page footer
 * and on /account.
 */
export function LegalLinks({ className }: { className?: string }) {
  const link = 'rounded-control hover:text-ink underline-offset-2 hover:underline';
  return (
    <nav
      aria-label="Legal"
      className={cn('flex flex-wrap items-center justify-center gap-x-4 gap-y-1', className)}
    >
      <Link to={PRIVACY_PATH} className={link}>
        Privacy Policy
      </Link>
      <Link to={TERMS_PATH} className={link}>
        Terms of Service
      </Link>
    </nav>
  );
}
