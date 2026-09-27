import { Archive, ArchiveRestore, MoreHorizontal, Pencil, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useNavigate, useParams } from 'react-router';
import {
  Badge,
  Button,
  ConfirmDialog,
  DropdownMenu,
  ErrorState,
  KeyValueList,
  LoadingState,
  PageHeader,
  SectionCard,
  Spinner,
  useToast,
} from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { useCan } from '@/features/shop/useCan';
import {
  useAddonSoleLinks,
  useCategories,
  useDeleteService,
  useService,
  useServices,
  useServiceUsage,
  useUpdateService,
} from './api';
import { PriceGrid } from './components/PriceGrid';
import { AddonsCard, PackageItemsCard } from './components/RelationsCards';
import { ServiceFormDialog } from './components/ServiceFormDialog';
import { ServiceImageCard } from './components/ServiceImageCard';
import { describeUsage, formatDuration, KIND_LABELS, usageTotal, type ServiceRow } from './model';

const BACK = { to: '/app/catalog', label: 'Catalog' };

export default function ServiceDetailPage() {
  const { serviceId = '' } = useParams();
  const service = useService(serviceId);

  if (service.isPending)
    return (
      <>
        <PageHeader title="Catalog item" back={BACK} />
        <LoadingState label="Loading…" />
      </>
    );
  if (service.error)
    return (
      <>
        <PageHeader title="Catalog item" back={BACK} />
        <ErrorState
          error={service.error}
          title="Couldn’t load this item"
          onRetry={() => void service.refetch()}
          retrying={service.isRefetching}
        />
      </>
    );
  return <ServiceDetail service={service.data} />;
}

function ServiceDetail({ service }: { service: ServiceRow }) {
  const canManage = useCan('catalog.manage');
  const categories = useCategories();
  const toast = useToast();
  const update = useUpdateService(service.id);
  const [editing, setEditing] = useState(false);
  const [confirm, setConfirm] = useState<'archive' | 'delete' | null>(null);
  const archived = service.archived_at !== null;
  const category = categories.data?.find((c) => c.id === service.category_id);

  const setArchived = async (next: boolean) => {
    try {
      await update.mutateAsync({ archived_at: next ? new Date().toISOString() : null });
      toast.success(next ? 'Archived' : 'Restored');
      setConfirm(null);
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <>
      <PageHeader
        title={service.name}
        back={BACK}
        meta={
          <span className="flex flex-wrap gap-1.5">
            <Badge tone="neutral">{KIND_LABELS[service.kind]}</Badge>
            {archived ? (
              <Badge tone="warning">Archived</Badge>
            ) : service.active ? (
              <Badge tone="success" dot>
                Active
              </Badge>
            ) : (
              <Badge tone="neutral" dot>
                Inactive
              </Badge>
            )}
            {service.online_bookable && <Badge tone="info">Bookable online</Badge>}
          </span>
        }
        actions={
          canManage ? (
            <div className="flex gap-2">
              <Button variant="secondary" leadingIcon={<Pencil />} onClick={() => setEditing(true)}>
                Edit details
              </Button>
              <DropdownMenu
                align="end"
                items={[
                  archived
                    ? {
                        key: 'restore',
                        label: 'Restore',
                        icon: <ArchiveRestore />,
                        onSelect: () => void setArchived(false),
                      }
                    : {
                        key: 'archive',
                        label: 'Archive',
                        icon: <Archive />,
                        onSelect: () => setConfirm('archive'),
                      },
                  { key: 'sep', separator: true },
                  {
                    key: 'delete',
                    label: 'Delete…',
                    icon: <Trash2 />,
                    tone: 'danger',
                    onSelect: () => setConfirm('delete'),
                  },
                ]}
                trigger={(props) => (
                  <button
                    type="button"
                    {...props}
                    aria-label="More actions"
                    className="border-line-strong bg-surface text-ink hover:bg-surface-2 rounded-control inline-flex size-9 items-center justify-center border"
                  >
                    <MoreHorizontal className="size-4" aria-hidden="true" />
                  </button>
                )}
              />
            </div>
          ) : undefined
        }
      />
      {archived && (
        <p className="bg-warning-soft text-warning-ink rounded-control mb-4 px-3 py-2 text-sm">
          Archived items stay on past jobs, quotes and invoices but can’t be added to new ones.
        </p>
      )}
      <div className="grid gap-5 lg:grid-cols-3">
        <div className="flex min-w-0 flex-col gap-5 lg:col-span-2">
          <SectionCard title="Details">
            <KeyValueList
              items={[
                { key: 'category', label: 'Category', value: category?.name ?? 'No category' },
                {
                  key: 'duration',
                  label: 'Default time',
                  value: formatDuration(service.duration_minutes),
                },
                { key: 'taxable', label: 'Taxable', value: service.taxable ? 'Yes' : 'No' },
                {
                  key: 'online',
                  label: 'Bookable online',
                  value: service.online_bookable ? 'Yes' : 'No',
                },
                { key: 'sort', label: 'Sort order', value: String(service.sort) },
                {
                  key: 'description',
                  label: 'Description',
                  value: service.description ? (
                    <span className="whitespace-pre-line">{service.description}</span>
                  ) : null,
                },
              ]}
            />
          </SectionCard>
          <PriceGrid service={service} canManage={canManage} />
          {service.kind === 'package' && (
            <PackageItemsCard service={service} canManage={canManage} />
          )}
        </div>
        <div className="flex min-w-0 flex-col gap-5">
          <ServiceImageCard service={service} canManage={canManage} />
          {/* Any non-add-on can carry add-on links (services, packages and
              products — the server and online booking honour them for all
              three), so the card must stay reachable after a kind change. */}
          {service.kind !== 'addon' && <AddonsCard service={service} canManage={canManage} />}
        </div>
      </div>

      {canManage && (
        <>
          <ServiceFormDialog open={editing} onClose={() => setEditing(false)} service={service} />
          <ConfirmDialog
            open={confirm === 'archive'}
            onClose={() => setConfirm(null)}
            loading={update.isPending}
            title={`Archive ${service.name}?`}
            description="It disappears from booking, new jobs and quotes. Past documents keep it. You can restore it any time."
            confirmLabel="Archive"
            onConfirm={() => setArchived(true)}
          />
          {confirm === 'delete' && (
            <DeleteServiceDialog
              service={service}
              onClose={() => setConfirm(null)}
              onArchive={() => setArchived(true)}
              archiving={update.isPending}
            />
          )}
        </>
      )}
    </>
  );
}

/** Deletes only unreferenced items; anything in use must be archived instead. */
function DeleteServiceDialog({
  service,
  onClose,
  onArchive,
  archiving,
}: {
  service: ServiceRow;
  onClose: () => void;
  onArchive: () => Promise<void>;
  archiving: boolean;
}) {
  const navigate = useNavigate();
  const toast = useToast();
  const usage = useServiceUsage(service.id, true);
  const isAddon = service.kind === 'addon';
  const soleLinks = useAddonSoleLinks(service.id, isAddon);
  const services = useServices();
  const remove = useDeleteService();
  const inUse = usage.data ? usageTotal(usage.data) > 0 : false;
  const archived = service.archived_at !== null;
  // Only add-ons need the "which services would switch to all add-ons" check.
  const linksPending = isAddon && (soleLinks.isPending || services.isPending);
  const linksError = isAddon ? (soleLinks.error ?? services.error) : null;

  if (usage.isPending || usage.error || inUse || linksPending || linksError) {
    return (
      <ConfirmDialog
        open
        onClose={onClose}
        loading={archiving}
        title={`Delete ${service.name}?`}
        confirmLabel={archived || !inUse ? 'Close' : 'Archive instead'}
        onConfirm={async () => {
          if (inUse && !archived) await onArchive();
          else onClose();
        }}
      >
        {usage.isPending || (!inUse && linksPending) ? (
          <p className="text-muted flex items-center gap-2 text-sm" role="status">
            <Spinner className="size-4" /> Checking where it’s used…
          </p>
        ) : usage.error || (!inUse && linksError) ? (
          <div className="flex flex-col items-start gap-2">
            <p role="alert" className="text-danger-ink text-sm">
              {errorMessage(usage.error ?? linksError)}
            </p>
            <Button
              size="sm"
              variant="secondary"
              loading={usage.isRefetching || soleLinks.isRefetching || services.isRefetching}
              onClick={() => {
                if (usage.error) void usage.refetch();
                if (soleLinks.error) void soleLinks.refetch();
                if (services.error) void services.refetch();
              }}
            >
              Try again
            </Button>
          </div>
        ) : (
          <p className="text-muted text-sm">
            It’s used by {describeUsage(usage.data)}, so it can’t be deleted.
            {archived ? ' It is already archived.' : ' Archive it to hide it from new work.'}
          </p>
        )}
      </ConfirmDialog>
    );
  }

  const nameOf = new Map((services.data ?? []).map((s) => [s.id, s.name]));
  const widened = isAddon ? (soleLinks.data ?? []).map((id) => nameOf.get(id) ?? 'An item') : [];

  return (
    <ConfirmDialog
      open
      onClose={onClose}
      tone="danger"
      loading={remove.isPending}
      title={`Delete ${service.name}?`}
      description="It isn’t used on any job, quote, invoice, package or plan. Its prices, add-on links and image are removed too, and checklists linked to it are no longer added automatically. This can’t be undone."
      confirmLabel={widened.length > 0 ? 'Delete anyway' : 'Delete'}
      onConfirm={async () => {
        try {
          await remove.mutateAsync(service);
          toast.success('Deleted');
          void navigate('/app/catalog', { replace: true });
        } catch (error) {
          toast.error(error);
          onClose();
        }
      }}
    >
      {widened.length > 0 && (
        <div className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-sm">
          <p className="font-medium">
            {widened.length === 1
              ? `${widened[0] ?? ''} only offers this add-on.`
              : 'These items only offer this add-on:'}
          </p>
          {widened.length > 1 && (
            <ul className="mt-1 list-disc pl-5">
              {widened.map((name, i) => (
                <li key={`${name}-${i}`}>{name}</li>
              ))}
            </ul>
          )}
          <p className="mt-1">
            After deleting, {widened.length === 1 ? 'it' : 'they'} will offer every add-on —
            including on online booking. Archive this add-on instead, or pick other add-ons for{' '}
            {widened.length === 1 ? 'it' : 'them'} first.
          </p>
        </div>
      )}
    </ConfirmDialog>
  );
}
