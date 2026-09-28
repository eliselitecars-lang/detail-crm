import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { builders, resetSupabaseMock, setTableResult, supabase } from '@/test/supabaseMock';
import type { ServiceRow } from '../model';
import { ServiceImageCard } from './ServiceImageCard';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

const service = {
  id: 'svc-1',
  shop_id: 'shop-1',
  name: 'Full detail',
  image_path: 'shop-1/services/svc-1.jpg',
  updated_at: '2026-01-01T00:00:00Z',
} as ServiceRow;

describe('ServiceImageCard', () => {
  it('asks before deleting the stored image, and removes it only on confirm', async () => {
    setTableResult('services', { data: [{ id: 'svc-1' }] });
    const { user } = renderRoute(<ServiceImageCard service={service} canManage />);
    await user.click(screen.getByRole('button', { name: 'Remove' }));
    const dialog = await screen.findByRole('alertdialog', { name: 'Remove this image?' });
    expect(builders.services).toBeUndefined();

    await user.click(within(dialog).getByRole('button', { name: 'Cancel' }));
    await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());
    expect(builders.services).toBeUndefined();

    await user.click(screen.getByRole('button', { name: 'Remove' }));
    await user.click(
      within(await screen.findByRole('alertdialog')).getByRole('button', { name: 'Remove image' }),
    );
    await waitFor(() =>
      expect(supabase.storage.from('shop-assets').remove).toHaveBeenCalledWith([
        'shop-1/services/svc-1.jpg',
      ]),
    );
    expect(builders.services?.[0]?.update).toHaveBeenCalledWith({ image_path: null });
    expect(await screen.findByText('Image removed')).toBeInTheDocument();
  });
});
