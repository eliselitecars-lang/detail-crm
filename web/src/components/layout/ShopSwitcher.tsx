import { Check, ChevronsUpDown, Plus } from 'lucide-react';
import { useNavigate } from 'react-router';
import { Avatar, DropdownMenu, type DropdownMenuEntry } from '@/components/ui';
import { ROLE_LABELS } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';

/**
 * Current shop + role; lists the user's other shops and "Create a shop".
 * The name takes the header's room (up to 40% of it, so search keeps its
 * share) and truncates only when that runs out.
 */
export function ShopSwitcher() {
  const { shop, role, memberships, switchShop } = useShop();
  const navigate = useNavigate();

  const items: DropdownMenuEntry[] = [
    ...memberships.map((m) => ({
      key: m.shopId,
      label: (
        <span className="flex min-w-0 flex-1 items-center justify-between gap-3">
          <span className="min-w-0">
            <span className="block truncate">{m.shop.name}</span>
            <span className="text-muted block text-xs">{ROLE_LABELS[m.role]}</span>
          </span>
          {m.shopId === shop.id && (
            <Check className="text-primary size-4" aria-label="Current shop" />
          )}
        </span>
      ),
      onSelect: () => {
        if (m.shopId === shop.id) return;
        switchShop(m.shopId);
        void navigate('/app');
      },
    })),
    { key: 'sep', separator: true as const },
    {
      key: 'new',
      label: 'Create another shop',
      icon: <Plus />,
      onSelect: () => void navigate('/app/onboarding'),
    },
  ];

  return (
    <DropdownMenu
      align="start"
      items={items}
      className="max-w-[40%] min-w-0"
      menuClassName="w-64"
      trigger={({ ref, ...props }) => (
        <button
          ref={ref}
          type="button"
          {...props}
          aria-label={`Current shop: ${shop.name}. Switch shop`}
          className="rounded-control hover:bg-surface-2 flex max-w-full min-w-0 items-center gap-2 px-2 py-1.5 text-left"
        >
          <Avatar name={shop.name} color={shop.brand_color} size="sm" className="rounded-md" />
          <span className="hidden min-w-0 sm:block">
            <span className="text-ink block truncate text-sm font-semibold">{shop.name}</span>
            <span className="text-muted block text-[11px] leading-tight">{ROLE_LABELS[role]}</span>
          </span>
          <ChevronsUpDown className="text-subtle size-4 shrink-0" aria-hidden="true" />
        </button>
      )}
    />
  );
}
