import { QueryClientProvider } from '@tanstack/react-query';
import { act, render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { AuthContext } from '@/features/auth/authContext';
import { shellKeys } from '@/lib/queryKeys';
import { storageKeys } from '@/lib/storage';
import { createTestQueryClient, membership, signedInAuth } from '@/test/render';
import { fetchMemberships } from './api';
import { useShopContext } from './shopContext';
import { ShopProvider } from './ShopProvider';

vi.mock('./api', () => ({ fetchMemberships: vi.fn() }));
const fetchMock = vi.mocked(fetchMemberships);

const shop = (id: string, name: string, role: 'owner' | 'technician' = 'owner') =>
  membership({ shopId: id, role, shop: { ...membership().shop, id, name } });

function Probe() {
  const ctx = useShopContext();
  return (
    <div>
      <p data-testid="status">{ctx.status}</p>
      <p data-testid="current">{ctx.membership?.shop.name ?? 'none'}</p>
      <p data-testid="role">{ctx.membership?.role ?? 'none'}</p>
      {ctx.memberships.map((m) => (
        <button key={m.shopId} type="button" onClick={() => ctx.switchShop(m.shopId)}>
          {`switch to ${m.shop.name}`}
        </button>
      ))}
    </div>
  );
}

function renderProvider(queryClient = createTestQueryClient()) {
  return render(
    <QueryClientProvider client={queryClient}>
      <AuthContext value={signedInAuth('me@example.com', 'user-1')}>
        <ShopProvider>
          <Probe />
        </ShopProvider>
      </AuthContext>
    </QueryClientProvider>,
  );
}

describe('ShopProvider', () => {
  beforeEach(() => fetchMock.mockClear());

  it('reports empty when the user has no shops', async () => {
    fetchMock.mockResolvedValue([]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('empty'));
    expect(screen.getByTestId('current')).toHaveTextContent('none');
  });

  it('selects the first shop by name when nothing is remembered', async () => {
    fetchMock.mockResolvedValue([
      shop('s2', 'Zen Detail'),
      shop('s1', 'Apex Auto Spa', 'technician'),
    ]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('ready'));
    expect(screen.getByTestId('current')).toHaveTextContent('Apex Auto Spa');
    expect(screen.getByTestId('role')).toHaveTextContent('technician');
    expect(fetchMock).toHaveBeenCalledWith('user-1');
  });

  it('restores the remembered shop and persists switches per user', async () => {
    window.localStorage.setItem(storageKeys.lastShop('user-1'), 's2');
    fetchMock.mockResolvedValue([shop('s1', 'Apex Auto Spa'), shop('s2', 'Zen Detail')]);
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('current')).toHaveTextContent('Zen Detail'));

    await userEvent.click(screen.getByRole('button', { name: 'switch to Apex Auto Spa' }));
    expect(screen.getByTestId('current')).toHaveTextContent('Apex Auto Spa');
    expect(window.localStorage.getItem(storageKeys.lastShop('user-1'))).toBe('s1');
  });

  it('keeps the loaded shop when a background refetch fails', async () => {
    fetchMock.mockResolvedValueOnce([shop('s1', 'Apex Auto Spa')]);
    const queryClient = createTestQueryClient();
    renderProvider(queryClient);
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('ready'));

    fetchMock.mockRejectedValueOnce(new Error('503 Service Unavailable'));
    await act(() => queryClient.refetchQueries());
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(queryClient.getQueryState(shellKeys.memberships('user-1'))?.status).toBe('error');
    expect(screen.getByTestId('status')).toHaveTextContent('ready');
    expect(screen.getByTestId('current')).toHaveTextContent('Apex Auto Spa');
  });

  it('surfaces load errors', async () => {
    fetchMock.mockRejectedValueOnce(new Error('offline'));
    renderProvider();
    await waitFor(() => expect(screen.getByTestId('status')).toHaveTextContent('error'));
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
