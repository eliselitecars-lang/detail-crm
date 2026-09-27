import { useEffect, type ReactNode } from 'react';
import { Link } from 'react-router';
import { Logo } from '@/components/layout/Logo';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { Card } from '@/components/ui';
import { cn } from '@/lib/cn';
import { LEGAL_LAST_UPDATED } from '../operator';
import { PRIVACY_PATH, TERMS_PATH } from '../paths';

/** One numbered section of a legal page (`id` is its #anchor). */
export interface LegalSection {
  id: string;
  title: string;
  body: ReactNode;
}

export interface LegalDocumentProps {
  title: string;
  /** Plain-language summary shown above the table of contents. */
  intro: ReactNode;
  sections: LegalSection[];
  /** The other legal page, linked at the end. */
  seeAlso: 'privacy' | 'terms';
}

const OTHER_PAGE = {
  privacy: { to: PRIVACY_PATH, label: 'Privacy Policy' },
  terms: { to: TERMS_PATH, label: 'Terms of Service' },
} as const;

/**
 * /privacy and /terms: the public page frame with the service's own mark
 * (not a shop's), a table of contents and the sections. No sign-in, no data
 * requests, nothing loaded from other origins.
 */
export function LegalDocument({ title, intro, sections, seeAlso: other }: LegalDocumentProps) {
  const seeAlso = OTHER_PAGE[other];
  useEffect(() => {
    document.title = `${title} · Detail CRM`;
  }, [title]);

  return (
    <PublicLayout
      shop={null}
      brand={
        <Link to="/" className="rounded-control flex w-fit" aria-label="Detail CRM home">
          <Logo />
        </Link>
      }
    >
      <article className="flex min-w-0 flex-col gap-6" aria-labelledby="legal-title">
        <header className="flex flex-col gap-2">
          <h1 id="legal-title" className="text-ink text-2xl font-semibold tracking-tight">
            {title}
          </h1>
          <p className="text-muted text-sm">
            Last updated <time dateTime={LEGAL_LAST_UPDATED.iso}>{LEGAL_LAST_UPDATED.label}</time>
          </p>
          <div className="text-ink flex flex-col gap-3 text-sm leading-6 sm:text-base sm:leading-7">
            {intro}
          </div>
        </header>

        <nav aria-labelledby="legal-toc">
          <Card padded>
            <h2 id="legal-toc" className="text-ink text-sm font-semibold">
              On this page
            </h2>
            <ol className="text-primary-ink mt-3 flex list-decimal flex-col gap-1.5 pl-5 text-sm">
              {sections.map((section) => (
                <li key={section.id}>
                  <a href={`#${section.id}`} className="hover:underline">
                    {section.title}
                  </a>
                </li>
              ))}
            </ol>
          </Card>
        </nav>

        <div className="flex flex-col gap-8">
          {sections.map((section, index) => (
            <section
              key={section.id}
              id={section.id}
              aria-labelledby={`${section.id}-title`}
              className="scroll-mt-6"
            >
              <h2
                id={`${section.id}-title`}
                className="text-ink text-lg font-semibold tracking-tight"
              >
                {index + 1}. {section.title}
              </h2>
              <div className="text-ink mt-3 flex flex-col gap-3 text-sm leading-6 break-words sm:text-base sm:leading-7">
                {section.body}
              </div>
            </section>
          ))}
        </div>

        <p className="text-muted border-line border-t pt-5 text-sm">
          See also the{' '}
          <Link to={seeAlso.to} className="text-primary-ink font-medium hover:underline">
            {seeAlso.label}
          </Link>
          .
        </p>
      </article>
    </PublicLayout>
  );
}

/** A bulleted list inside a section. */
export function LegalList({ children, className }: { children: ReactNode; className?: string }) {
  return <ul className={cn('flex list-disc flex-col gap-1.5 pl-5', className)}>{children}</ul>;
}

/** A sub-heading inside a section. */
export function LegalSubheading({ children }: { children: ReactNode }) {
  return <h3 className="text-ink mt-1 text-base font-semibold">{children}</h3>;
}

/** Bold lead-in for a list item ("Accounts:"). */
export function Term({ children }: { children: ReactNode }) {
  return <strong className="font-semibold">{children}</strong>;
}
