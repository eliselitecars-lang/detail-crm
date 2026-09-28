import { render, screen } from '@testing-library/react';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { isEmbeddablePath, isFramed } from './framing';
import { RootLayout } from './RootLayout';

function renderAt(path: string) {
  const router = createMemoryRouter(
    [
      {
        element: <RootLayout />,
        children: [
          { path: '/book/:slug', element: <h1>Booking page</h1> },
          { path: '/app', element: <h1>Staff app</h1> },
        ],
      },
    ],
    { initialEntries: [path] },
  );
  return render(<RouterProvider router={router} />);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('framing', () => {
  it('only the booking page and lead forms may be embedded', () => {
    expect(isEmbeddablePath('/book/glacier')).toBe(true);
    expect(isEmbeddablePath('/lead/0f0e0d0c-0b0a-4908-8706-050403020100')).toBe(true);
    expect(isEmbeddablePath('/book/glacier/extra')).toBe(false);
    expect(isEmbeddablePath('/booking/abc')).toBe(false);
    expect(isEmbeddablePath('/app')).toBe(false);
    expect(isEmbeddablePath('/login')).toBe(false);
  });

  it('treats an unreadable parent as framed', () => {
    const win = {
      self: {},
      get top(): never {
        throw new Error('cross-origin');
      },
    } as unknown as Window;
    expect(isFramed(win)).toBe(true);
  });

  it('refuses to render other pages inside a frame, but not embeddable ones', () => {
    vi.spyOn(window, 'top', 'get').mockReturnValue({} as Window);
    renderAt('/app');
    expect(
      screen.getByRole('heading', { name: 'This page can’t be shown here' }),
    ).toBeInTheDocument();
    expect(screen.queryByText('Staff app')).not.toBeInTheDocument();
  });

  it('renders embeddable pages inside a frame', () => {
    vi.spyOn(window, 'top', 'get').mockReturnValue({} as Window);
    renderAt('/book/glacier');
    expect(screen.getByRole('heading', { name: 'Booking page' })).toBeInTheDocument();
  });

  it('renders everything normally at the top level', () => {
    renderAt('/app');
    expect(screen.getByRole('heading', { name: 'Staff app' })).toBeInTheDocument();
  });
});
