import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router';
import { describe, expect, it } from 'vitest';
import { PublicLayout } from './PublicLayout';

function renderLayout(props: Partial<Parameters<typeof PublicLayout>[0]> = {}) {
  return render(
    <MemoryRouter>
      <PublicLayout shop={{ name: 'Glacier Detailing' }} {...props}>
        <p>Page</p>
      </PublicLayout>
    </MemoryRouter>,
  );
}

describe('PublicLayout footer', () => {
  it('links shop-branded pages to the client portal', () => {
    renderLayout();
    expect(screen.getByRole('link', { name: 'My account' })).toHaveAttribute('href', '/portal');
  });

  it('uses a full page load while a shop analytics tag is on the page', () => {
    renderLayout({ fullPageLinks: true });
    const link = screen.getByRole('link', { name: 'My account' });
    expect(link).toHaveAttribute('href', '/portal');
    expect(link.tagName).toBe('A');
  });

  it('hides the link on the portal itself and on service pages', () => {
    renderLayout({ accountLink: false });
    expect(screen.queryByRole('link', { name: 'My account' })).not.toBeInTheDocument();
    renderLayout({ shop: null, brand: <span>Detail CRM</span> });
    expect(screen.queryByRole('link', { name: 'My account' })).not.toBeInTheDocument();
  });
});
