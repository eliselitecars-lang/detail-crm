import { screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { PublicLayout } from '@/components/layout/PublicLayout';
import { renderRoute } from '@/test/render';
import { resetSupabaseMock } from '@/test/supabaseMock';
import { readLegalOperator, type LegalOperator } from './operator';
import { PRIVACY_PATH, TERMS_PATH } from './paths';
import PrivacyPage from './PrivacyPage';
import { routes } from './routes';
import TermsPage from './TermsPage';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

const UNSET: LegalOperator = readLegalOperator({});
const CONFIGURED: LegalOperator = readLegalOperator({
  VITE_LEGAL_ENTITY_NAME: 'Example Operator LLC',
  VITE_SUPPORT_EMAIL: 'privacy@example.com',
  VITE_LEGAL_COUNTRY: 'the State of Alabama, United States',
  VITE_LEGAL_ADDRESS: '1 Example Way\\nBirmingham, AL 35203',
});

function renderPage(page: 'privacy' | 'terms', operator: LegalOperator) {
  const path = page === 'privacy' ? PRIVACY_PATH : TERMS_PATH;
  const ui =
    page === 'privacy' ? <PrivacyPage operator={operator} /> : <TermsPage operator={operator} />;
  return renderRoute(ui, { path, routePath: path, shop: null });
}

function legalFooterLinks() {
  const footer = screen.getByRole('contentinfo');
  const nav = within(footer).getByRole('navigation', { name: 'Legal' });
  return {
    privacy: within(nav).getByRole('link', { name: 'Privacy Policy' }),
    terms: within(nav).getByRole('link', { name: 'Terms of Service' }),
  };
}

beforeEach(() => resetSupabaseMock());

describe('legal routes', () => {
  it('registers public /privacy and /terms (no sign-in wrapper)', () => {
    const publicRoutes = routes.public ?? [];
    expect(publicRoutes.map((r) => r.path)).toEqual(['/privacy', '/terms']);
    for (const route of publicRoutes) {
      expect(route.element).toBeUndefined();
      expect(route.children).toBeUndefined();
    }
  });
});

describe('PrivacyPage', () => {
  it('renders every section with a table of contents', () => {
    renderPage('privacy', UNSET);
    expect(screen.getByRole('heading', { level: 1, name: 'Privacy Policy' })).toBeInTheDocument();
    expect(document.title).toBe('Privacy Policy · Detail CRM');
    const toc = screen.getByRole('navigation', { name: 'On this page' });
    const entries = within(toc).getAllByRole('link');
    expect(entries.length).toBeGreaterThanOrEqual(10);
    for (const entry of entries) {
      const id = entry.getAttribute('href')?.slice(1) ?? '';
      expect(document.getElementById(id)).not.toBeNull();
    }
    for (const title of [
      'Shops and their customers’ information',
      'Information the Service handles',
      'Who receives information',
      'Texts, emails and your choices',
      'Keeping and deleting information',
      'Children',
      'Contact us',
    ]) {
      expect(screen.getByRole('heading', { level: 2, name: new RegExp(title) })).toBeVisible();
    }
  });

  it('names the providers, the opt-outs and account deletion', () => {
    renderPage('privacy', UNSET);
    const text = document.body.textContent ?? '';
    for (const provider of [
      'Supabase',
      'Stripe',
      'Twilio',
      'Resend',
      'Cloudflare',
      'Apple',
      'Google Fonts',
      'OpenStreetMap',
      'NHTSA',
    ]) {
      expect(text).toContain(provider);
    }
    expect(text).toContain('Reply STOP');
    expect(text).toContain('unsubscribe link');
    expect(text).toContain('the Service never receives or stores them');
    expect(text).toContain('More › Your account');
    expect(text).toContain('transfer ownership of the shop or delete it');
    expect(text).toContain('We do not sell personal information');
  });

  it('says what a shop’s own Meta Pixel / Google Analytics tag receives, and where it runs', () => {
    renderPage('privacy', UNSET);
    const text = document.body.textContent ?? '';
    expect(text).toContain('neither app contains our own advertising or analytics trackers');
    expect(text).toContain('Meta or Google receive, as the shop’s providers');
    expect(text).toContain('The tags run on no other page');
    expect(text).toContain('automatic advanced matching');
    // Location from the iPhone app: stamped on clock-in/out only, never sent from the day map.
    expect(text).toContain('the day map shows your own position on your device');
    expect(text).toContain('Clocking in or out in the web app records no location');
  });

  it('uses neutral wording when the operator details are not configured', () => {
    renderPage('privacy', UNSET);
    const text = document.body.textContent ?? '';
    expect(text).toContain('The operator of this service (“we”, “us”) runs the Service');
    expect(text).toContain(
      'For privacy questions and requests, contact the operator of this service.',
    );
    // No invented address, email or company.
    expect(text).not.toMatch(/@|undefined|null|LLC|Inc\b/);
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
    expect(document.querySelector('address')).toBeNull();
  });

  it('shows the configured operator, email and address', () => {
    renderPage('privacy', CONFIGURED);
    const text = document.body.textContent ?? '';
    expect(text).toContain('Example Operator LLC (“we”, “us”) runs the Service');
    const contact = screen.getByRole('region', { name: /Contact us/ });
    expect(within(contact).getByRole('link', { name: 'privacy@example.com' })).toHaveAttribute(
      'href',
      'mailto:privacy@example.com',
    );
    expect(contact.querySelector('address')?.textContent).toBe(
      '1 Example Way\nBirmingham, AL 35203',
    );
  });

  it('loads nothing from other origins and links only to app pages', () => {
    renderPage('privacy', CONFIGURED);
    expect(document.querySelectorAll('img, script, iframe, link')).toHaveLength(0);
    for (const anchor of document.querySelectorAll('a')) {
      expect(anchor.getAttribute('href')).toMatch(/^(\/|#|mailto:)/);
    }
  });

  it('links to the terms from the footer and the end of the page', () => {
    renderPage('privacy', UNSET);
    const { privacy, terms } = legalFooterLinks();
    expect(privacy).toHaveAttribute('href', '/privacy');
    expect(terms).toHaveAttribute('href', '/terms');
    const article = screen.getByRole('article', { name: 'Privacy Policy' });
    expect(within(article).getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'href',
      '/terms',
    );
  });
});

describe('TermsPage', () => {
  it('renders the service terms', () => {
    renderPage('terms', UNSET);
    expect(screen.getByRole('heading', { level: 1, name: 'Terms of Service' })).toBeInTheDocument();
    expect(document.title).toBe('Terms of Service · Detail CRM');
    for (const title of [
      'Accounts and roles',
      'Your responsibilities as a shop',
      'Payments through Stripe',
      'Acceptable use',
      'Ending use of the Service',
      'Disclaimers',
      'Limitation of liability',
      'Governing law and disputes',
    ]) {
      expect(screen.getByRole('heading', { level: 2, name: new RegExp(title) })).toBeVisible();
    }
    const text = document.body.textContent ?? '';
    expect(text).toContain('you are the merchant of record for every payment');
    expect(text).toContain('these terms do not set prices');
  });

  it('uses neutral wording and no governing-law country when unset', () => {
    renderPage('terms', UNSET);
    const text = document.body.textContent ?? '';
    expect(text).toContain(
      'These terms are an agreement between you and the operator of this service',
    );
    expect(text).toContain(
      'governed by the laws of the place where the operator of this service is established',
    );
    expect(text).not.toMatch(/@|undefined|null|LLC|Inc\b/);
    expect(document.querySelector('a[href^="mailto:"]')).toBeNull();
  });

  it('takes the governing law from VITE_LEGAL_COUNTRY when set', () => {
    renderPage('terms', CONFIGURED);
    const text = document.body.textContent ?? '';
    expect(text).toContain('These terms are an agreement between you and Example Operator LLC');
    expect(text).toContain(
      'These terms are governed by the laws of the State of Alabama, United States',
    );
    expect(screen.getByRole('link', { name: 'privacy@example.com' })).toHaveAttribute(
      'href',
      'mailto:privacy@example.com',
    );
  });

  it('links back to the privacy policy', () => {
    renderPage('terms', UNSET);
    expect(legalFooterLinks().privacy).toHaveAttribute('href', '/privacy');
  });
});

describe('legal links on other pages', () => {
  it('sit under the auth pages (AuthLayout)', () => {
    renderRoute(
      <AuthLayout title="Sign in">
        <p>form</p>
      </AuthLayout>,
      { path: '/login', routePath: '/login', shop: null },
    );
    const nav = screen.getByRole('navigation', { name: 'Legal' });
    expect(within(nav).getByRole('link', { name: 'Privacy Policy' })).toHaveAttribute(
      'href',
      '/privacy',
    );
    expect(within(nav).getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'href',
      '/terms',
    );
  });

  it('sit in the footer of shop-branded public pages (PublicLayout)', () => {
    renderRoute(
      <PublicLayout shop={{ name: 'Glacier Detailing', phone: '+12055550100' }}>
        <p>invoice</p>
      </PublicLayout>,
      { path: '/i/x', routePath: '/i/:token', shop: null },
    );
    const { privacy, terms } = legalFooterLinks();
    expect(privacy).toHaveAttribute('href', '/privacy');
    expect(terms).toHaveAttribute('href', '/terms');
    expect(screen.getByRole('contentinfo')).toHaveTextContent('Powered by Detail CRM');
  });
});
