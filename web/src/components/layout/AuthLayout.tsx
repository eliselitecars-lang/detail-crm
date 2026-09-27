import type { ReactNode } from 'react';
import { Link } from 'react-router';
import { Card } from '@/components/ui';
import { Logo } from './Logo';

export interface AuthLayoutProps {
  title: string;
  description?: ReactNode;
  children: ReactNode;
  /** Content under the card (e.g. "No account? Sign up"). */
  footer?: ReactNode;
}

/** Centered card layout for sign-in, sign-up, password and invite pages. */
export function AuthLayout({ title, description, children, footer }: AuthLayoutProps) {
  return (
    <div className="bg-canvas flex min-h-dvh flex-col items-center justify-center px-4 py-10">
      <main className="w-full max-w-sm">
        <Link
          to="/"
          className="rounded-control mx-auto mb-6 flex w-fit"
          aria-label="Detail CRM home"
        >
          <Logo />
        </Link>
        <Card padded className="shadow-pop">
          <h1 className="text-ink text-lg font-semibold tracking-tight">{title}</h1>
          {description && <p className="text-muted mt-1 text-sm">{description}</p>}
          <div className="mt-5">{children}</div>
        </Card>
        {footer && <div className="text-muted mt-5 text-center text-sm">{footer}</div>}
      </main>
    </div>
  );
}
