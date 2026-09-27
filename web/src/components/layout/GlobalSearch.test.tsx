import { screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { renderRoute } from '@/test/render';
import { createBuilder, resetSupabaseMock, supabase } from '@/test/supabaseMock';
import { GlobalSearch } from './GlobalSearch';

vi.mock('@/lib/supabase', () => import('@/test/supabaseMock'));

beforeEach(() => resetSupabaseMock());

/** Every IDREF the combobox exposes must resolve to an element in the document. */
function expectValidComboboxRefs(combobox: HTMLElement) {
  for (const attr of ['aria-controls', 'aria-activedescendant']) {
    const id = combobox.getAttribute(attr);
    if (id !== null) expect(document.getElementById(id), `${attr}="${id}"`).not.toBeNull();
  }
}

async function openSearch() {
  const utils = renderRoute(<GlobalSearch />);
  await utils.user.click(screen.getByRole('button', { name: 'Search' }));
  const combobox = await screen.findByRole('combobox', { name: 'Search this shop' });
  return { ...utils, combobox };
}

describe('GlobalSearch', () => {
  it('references the listbox only while it is rendered', async () => {
    supabase.rpc.mockReturnValue(
      createBuilder({
        data: [{ kind: 'customer', id: 'c-1', title: 'Casey Customer', subtitle: null }],
      }),
    );
    const { user, combobox } = await openSearch();
    expect(combobox).not.toHaveAttribute('aria-controls');
    expect(combobox).toHaveAttribute('aria-expanded', 'false');
    expectValidComboboxRefs(combobox);

    await user.type(combobox, 'cas');
    const listbox = await screen.findByRole('listbox', { name: 'Search results' });
    expect(combobox).toHaveAttribute('aria-controls', listbox.id);
    expect(combobox).toHaveAttribute('aria-expanded', 'true');
    expect(screen.getByRole('option', { name: /Casey Customer/ })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    expectValidComboboxRefs(combobox);
  });

  it('drops the references for no-match and error states', async () => {
    supabase.rpc.mockReturnValueOnce(createBuilder({ data: [] }));
    const { user, combobox } = await openSearch();
    await user.type(combobox, 'zz');
    expect(await screen.findByText('No matches for “zz”.')).toBeInTheDocument();
    expect(combobox).not.toHaveAttribute('aria-controls');
    expect(combobox).not.toHaveAttribute('aria-activedescendant');
    expectValidComboboxRefs(combobox);

    supabase.rpc.mockReturnValueOnce(
      createBuilder({ error: { code: '42501', message: 'permission denied for function' } }),
    );
    await user.type(combobox, 'q');
    await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument());
    expect(combobox).not.toHaveAttribute('aria-controls');
    expect(combobox).toHaveAttribute('aria-expanded', 'false');
    expectValidComboboxRefs(combobox);
  });
});
