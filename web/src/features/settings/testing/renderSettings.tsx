import { QueryClientProvider } from '@tanstack/react-query';
import { render } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { vi } from 'vitest';
import { ToastProvider } from '@/components/ui/Toast';
import { AuthContext } from '@/features/auth/authContext';
import type { ShopRole } from '@/features/shop/permissions';
import { ShopContext } from '@/features/shop/shopContext';
import { createTestQueryClient, membership, shopValue, signedInAuth } from '@/test/render';
import { routes } from '../routes';

/**
 * Renders the real settings route tree (lazy pages, guards, redirects) at
 * `path` under /app with the given role.
 */
export function renderSettings(path: string, { role = 'owner' }: { role?: ShopRole } = {}) {
  const queryClient = createTestQueryClient();
  const refetch = vi.fn(() => Promise.resolve());
  const router = createMemoryRouter([{ path: '/app', children: routes.staff ?? [] }], {
    initialEntries: [path],
  });
  const user = userEvent.setup();
  const utils = render(
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <AuthContext value={signedInAuth()}>
          <ShopContext value={shopValue({ membership: membership({ role }), refetch })}>
            <RouterProvider router={router} />
          </ShopContext>
        </AuthContext>
      </ToastProvider>
    </QueryClientProvider>,
  );
  return { ...utils, user, router, queryClient, refetch };
}
