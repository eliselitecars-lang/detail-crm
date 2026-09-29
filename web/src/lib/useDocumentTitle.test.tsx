import { render } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { APP_TITLE, publicPageTitle, useDocumentTitle } from './useDocumentTitle';

function Titled({ title }: { title: string | null }) {
  useDocumentTitle(title);
  return null;
}

describe('useDocumentTitle', () => {
  beforeEach(() => {
    document.title = APP_TITLE;
  });

  it('sets the title while mounted and resets it when the page goes away', () => {
    const { unmount } = render(<Titled title="Jane Doe · Detail CRM" />);
    expect(document.title).toBe('Jane Doe · Detail CRM');
    unmount();
    expect(document.title).toBe(APP_TITLE);
  });

  it('brings back the enclosing title when a nested one unmounts', () => {
    const { rerender } = render(
      <>
        <Titled title="Settings · Detail CRM" />
        <Titled title="Payments · Settings · Detail CRM" />
      </>,
    );
    expect(document.title).toBe('Payments · Settings · Detail CRM');
    rerender(<Titled title="Settings · Detail CRM" />);
    expect(document.title).toBe('Settings · Detail CRM');
  });

  it('follows a title change and claims nothing for null', () => {
    const { rerender, unmount } = render(<Titled title="Quote #1 · Glacier" />);
    rerender(<Titled title="Quote #2 · Glacier" />);
    expect(document.title).toBe('Quote #2 · Glacier');
    rerender(<Titled title={null} />);
    expect(document.title).toBe(APP_TITLE);
    unmount();
    expect(document.title).toBe(APP_TITLE);
  });
});

describe('publicPageTitle', () => {
  it('names the page and the shop, or the service while no shop is known', () => {
    expect(publicPageTitle('Invoice #2001', 'Glacier Detailing')).toBe(
      'Invoice #2001 · Glacier Detailing',
    );
    expect(publicPageTitle('Loading quote', null)).toBe('Loading quote · Detail CRM');
    expect(publicPageTitle(null, 'Glacier Detailing')).toBe('Glacier Detailing');
    expect(publicPageTitle('Your account', 'Your account')).toBe('Your account');
    expect(publicPageTitle(undefined, undefined)).toBe(APP_TITLE);
  });
});
