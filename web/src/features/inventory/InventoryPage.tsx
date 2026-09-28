import {
  Archive,
  ArchiveRestore,
  History,
  MoreHorizontal,
  Package,
  PackagePlus,
  Pencil,
  Plus,
  Trash2,
} from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  Checkbox,
  ConfirmDialog,
  DropdownMenu,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  SearchInput,
  SectionCard,
  Table,
  useToast,
  type Column,
} from '@/components/ui';
import { formatCents } from '@/lib/money';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useArchiveProduct, useDeleteProduct, useProducts } from './api';
import { MovementsDrawer } from './components/MovementsDrawer';
import { ProductDialog, StockDialog } from './components/ProductDialogs';
import {
  formatQty,
  isLowStock,
  stockValueCents,
  type ManualMovementKind,
  type Product,
} from './model';

type Action =
  | { kind: 'edit'; product: Product | null }
  | { kind: 'stock'; product: Product; movement: ManualMovementKind }
  | { kind: 'history'; product: Product }
  | { kind: 'delete'; product: Product };

export default function InventoryPage() {
  const { currency } = useShop();
  const canManage = useCan('inventory.manage');
  const toast = useToast();
  const products = useProducts();
  const archive = useArchiveProduct();
  const remove = useDeleteProduct();
  const [action, setAction] = useState<Action | null>(null);
  const [search, setSearch] = useState('');
  const [showArchived, setShowArchived] = useState(false);
  const [lowOnly, setLowOnly] = useState(false);

  const all = products.data ?? [];
  const q = search.trim().toLowerCase();
  const rows = all.filter(
    (p) =>
      (showArchived || p.archived_at === null) &&
      (!lowOnly || isLowStock(p)) &&
      (!q ||
        p.name.toLowerCase().includes(q) ||
        (p.sku ?? '').toLowerCase().includes(q) ||
        (p.supplier ?? '').toLowerCase().includes(q)),
  );
  const live = all.filter((p) => p.archived_at === null);
  const lowCount = live.filter(isLowStock).length;
  const money = (cents: number) => formatCents(cents, { currency });

  const setArchived = async (product: Product, archived: boolean) => {
    try {
      await archive.mutateAsync({ id: product.id, archived });
      toast.success(archived ? 'Product archived' : 'Product restored', product.name);
    } catch (error) {
      toast.error(error);
    }
  };

  const columns: Column<Product>[] = [
    {
      key: 'name',
      header: 'Product',
      primary: true,
      cell: (p) => (
        <span className="flex flex-wrap items-center gap-1.5">
          <span className="font-medium">{p.name}</span>
          {p.sku && <span className="text-muted text-xs">{p.sku}</span>}
          {isLowStock(p) && <Badge tone="warning">Low stock</Badge>}
          {!p.active && <Badge tone="neutral">Inactive</Badge>}
          {p.archived_at && <Badge tone="neutral">Archived</Badge>}
        </span>
      ),
    },
    {
      key: 'onHand',
      header: 'On hand',
      align: 'right',
      cell: (p) => (
        <span className="tabular">
          {formatQty(p.on_hand)} <span className="text-muted text-xs">{p.unit}</span>
        </span>
      ),
    },
    {
      key: 'reorder',
      header: 'Reorder at',
      align: 'right',
      hideOnMobile: true,
      cell: (p) => (p.reorder_at === null ? '—' : formatQty(p.reorder_at)),
    },
    {
      key: 'cost',
      header: 'Cost per unit',
      align: 'right',
      cell: (p) => money(p.unit_cost_cents),
    },
    {
      key: 'supplier',
      header: 'Supplier',
      hideOnMobile: true,
      cell: (p) => p.supplier ?? '—',
    },
    {
      key: 'actions',
      header: <span className="sr-only">Actions</span>,
      align: 'right',
      cell: (p) => (
        <span className="inline-flex items-center gap-1">
          {canManage && p.archived_at === null && (
            <Button
              size="sm"
              variant="secondary"
              leadingIcon={<PackagePlus className="size-4" />}
              onClick={() => setAction({ kind: 'stock', product: p, movement: 'receive' })}
            >
              Receive<span className="sr-only"> {p.name}</span>
            </Button>
          )}
          <DropdownMenu
            align="end"
            items={[
              {
                key: 'history',
                label: 'Stock history',
                icon: <History />,
                onSelect: () => setAction({ kind: 'history', product: p }),
              },
              ...(canManage
                ? [
                    ...(p.archived_at === null
                      ? [
                          {
                            key: 'adjust',
                            label: 'Adjust stock…',
                            onSelect: () =>
                              setAction({ kind: 'stock', product: p, movement: 'adjust' }),
                          },
                          {
                            key: 'count',
                            label: 'Count stock…',
                            onSelect: () =>
                              setAction({ kind: 'stock', product: p, movement: 'count' }),
                          },
                        ]
                      : []),
                    {
                      key: 'edit',
                      label: 'Edit…',
                      icon: <Pencil />,
                      onSelect: () => setAction({ kind: 'edit', product: p }),
                    },
                    p.archived_at === null
                      ? {
                          key: 'archive',
                          label: 'Archive',
                          icon: <Archive />,
                          onSelect: () => void setArchived(p, true),
                        }
                      : {
                          key: 'restore',
                          label: 'Restore',
                          icon: <ArchiveRestore />,
                          onSelect: () => void setArchived(p, false),
                        },
                    { key: 'sep', separator: true as const },
                    {
                      key: 'delete',
                      label: 'Delete…',
                      icon: <Trash2 />,
                      tone: 'danger' as const,
                      onSelect: () => setAction({ kind: 'delete', product: p }),
                    },
                  ]
                : []),
            ]}
            trigger={(props) => (
              <button
                type="button"
                {...props}
                aria-label={`More actions for ${p.name}`}
                className="border-line-strong bg-surface text-ink hover:bg-surface-2 rounded-control inline-flex size-8 items-center justify-center border"
              >
                <MoreHorizontal className="size-4" aria-hidden="true" />
              </button>
            )}
          />
        </span>
      ),
    },
  ];

  let body;
  if (products.isPending) body = <LoadingState variant="rows" rows={5} label="Loading products…" />;
  else if (products.isError)
    body = (
      <ErrorState
        error={products.error}
        title="Couldn’t load products"
        onRetry={() => void products.refetch()}
        retrying={products.isRefetching}
      />
    );
  else if (all.length === 0)
    body = (
      <EmptyState
        icon={<Package aria-hidden="true" />}
        title="No products yet"
        description="Add the supplies your services use, then list them on each service (Catalog → a service → Materials used) so stock goes down as jobs are completed."
        action={
          canManage ? (
            <Button
              leadingIcon={<Plus />}
              onClick={() => setAction({ kind: 'edit', product: null })}
            >
              Add product
            </Button>
          ) : undefined
        }
      />
    );
  else if (rows.length === 0)
    body = (
      <EmptyState
        compact
        icon={<Package aria-hidden="true" />}
        title="No products match"
        description="Try another search, or clear the filters."
      />
    );
  else body = <Table caption="Products" columns={columns} rows={rows} getRowId={(p) => p.id} />;

  return (
    <>
      <PageHeader
        title="Inventory"
        description="Supplies on hand, reorder alerts and what each job used."
        actions={
          canManage ? (
            <Button
              leadingIcon={<Plus />}
              onClick={() => setAction({ kind: 'edit', product: null })}
            >
              New product
            </Button>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-4">
        {live.length > 0 && (
          <div
            className="grid grid-cols-2 gap-3 sm:grid-cols-3"
            role="group"
            aria-label="Inventory summary"
          >
            <Summary label="Products" value={String(live.length)} />
            <Summary
              label="Low stock"
              value={String(lowCount)}
              tone={lowCount > 0 ? 'warning' : undefined}
            />
            <Summary label="Stock value at cost" value={money(stockValueCents(live))} />
          </div>
        )}
        <SectionCard
          title="Products"
          flush
          actions={
            all.length > 0 ? (
              <div className="flex flex-wrap items-center gap-3">
                <Checkbox
                  checked={lowOnly}
                  onChange={(e) => setLowOnly(e.target.checked)}
                  label="Low stock only"
                />
                <Checkbox
                  checked={showArchived}
                  onChange={(e) => setShowArchived(e.target.checked)}
                  label="Show archived"
                />
              </div>
            ) : undefined
          }
        >
          {all.length > 0 && (
            <div className="border-line border-b px-4 py-3 sm:px-5">
              <SearchInput
                value={search}
                onChange={setSearch}
                placeholder="Search by name, SKU or supplier"
                aria-label="Search products"
              />
            </div>
          )}
          {body}
        </SectionCard>
      </div>

      {action?.kind === 'edit' && (
        <ProductDialog product={action.product} onClose={() => setAction(null)} />
      )}
      {action?.kind === 'stock' && (
        <StockDialog
          product={action.product}
          initialKind={action.movement}
          onClose={() => setAction(null)}
        />
      )}
      {action?.kind === 'history' && (
        <MovementsDrawer product={action.product} onClose={() => setAction(null)} />
      )}
      <ConfirmDialog
        open={action?.kind === 'delete'}
        onClose={() => setAction(null)}
        tone="danger"
        loading={remove.isPending}
        title={`Delete ${action?.kind === 'delete' ? action.product.name : 'product'}?`}
        description="Its stock history is deleted too, and the service profit report loses the materials it recorded. Archive it instead to keep the history."
        confirmLabel="Delete"
        onConfirm={async () => {
          if (action?.kind !== 'delete') return;
          try {
            await remove.mutateAsync(action.product.id);
            toast.success('Product deleted');
          } catch (error) {
            toast.error(error);
          } finally {
            setAction(null);
          }
        }}
      />
    </>
  );
}

function Summary({ label, value, tone }: { label: string; value: string; tone?: 'warning' }) {
  return (
    <dl className="rounded-card border-line bg-surface shadow-card flex min-w-0 flex-col gap-1 border p-4">
      <dt className="text-muted text-xs font-medium">{label}</dt>
      <dd
        className={
          tone === 'warning'
            ? 'tabular text-warning-ink truncate text-xl font-semibold'
            : 'tabular text-ink truncate text-xl font-semibold'
        }
      >
        {value}
      </dd>
    </dl>
  );
}
