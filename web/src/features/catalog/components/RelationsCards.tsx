import { ArrowDown, ArrowUp, Plus, X } from 'lucide-react';
import { useState } from 'react';
import { Link } from 'react-router';
import {
  Badge,
  Button,
  Checkbox,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import {
  useAddPackageItem,
  usePackageItems,
  useRemovePackageItem,
  useReorder,
  useServiceAddons,
  useServices,
  useToggleAddon,
} from '../api';
import { KIND_LABELS, moveItem, resequence, type ServiceRow } from '../model';

/** What a package includes (package_items). Packages can't contain packages. */
export function PackageItemsCard({
  service,
  canManage,
}: {
  service: ServiceRow;
  canManage: boolean;
}) {
  const toast = useToast();
  const items = usePackageItems(service.id);
  const services = useServices();
  const add = useAddPackageItem(service.id);
  const remove = useRemovePackageItem();
  const reorder = useReorder('package_items');
  const [choice, setChoice] = useState('');

  const byId = new Map((services.data ?? []).map((s) => [s.id, s]));
  const list = items.data ?? [];
  const included = new Set(list.map((i) => i.service_id));
  const candidates = (services.data ?? []).filter(
    (s) =>
      s.id !== service.id && s.kind !== 'package' && s.archived_at === null && !included.has(s.id),
  );

  const onAdd = async () => {
    if (!choice) return;
    try {
      const lastSort = list.reduce((max, i) => Math.max(max, i.sort), 0);
      await add.mutateAsync({ serviceId: choice, sort: lastSort + 10 });
      setChoice('');
    } catch (error) {
      toast.error(error);
    }
  };

  const move = (index: number, delta: number) =>
    reorder.mutate(resequence(moveItem(list, index, index + delta)), {
      onError: (error) => toast.error(error),
    });

  let body;
  if (items.isPending || services.isPending)
    body = <LoadingState label="Loading package contents…" variant="rows" rows={2} />;
  else if (items.error || services.error)
    body = (
      <ErrorState
        compact
        error={items.error ?? services.error}
        title="Couldn’t load package contents"
        onRetry={() => {
          void items.refetch();
          void services.refetch();
        }}
      />
    );
  else
    body = (
      <>
        {list.length === 0 ? (
          <EmptyState
            compact
            title="This package is empty"
            description="Add the services it includes."
          />
        ) : (
          <ul className="divide-line divide-y" aria-label="Included in this package">
            {list.map((item, index) => {
              const included = byId.get(item.service_id);
              const name = included?.name ?? 'Removed service';
              return (
                <li key={item.id} className="flex items-center gap-2 px-4 py-2.5 sm:px-5">
                  <div className="min-w-0 flex-1">
                    <Link
                      to={`/app/catalog/services/${item.service_id}`}
                      className="text-ink hover:text-primary-ink truncate font-medium hover:underline"
                    >
                      {name}
                    </Link>
                    {included && (
                      <p className="text-muted text-xs">
                        {KIND_LABELS[included.kind]}
                        {included.archived_at ? ' · archived' : ''}
                      </p>
                    )}
                  </div>
                  {canManage && (
                    <div className="flex shrink-0 items-center">
                      <IconButton
                        label={`Move ${name} up`}
                        icon={<ArrowUp className="size-4" />}
                        size="sm"
                        disabled={index === 0 || reorder.isPending}
                        onClick={() => move(index, -1)}
                      />
                      <IconButton
                        label={`Move ${name} down`}
                        icon={<ArrowDown className="size-4" />}
                        size="sm"
                        disabled={index === list.length - 1 || reorder.isPending}
                        onClick={() => move(index, 1)}
                      />
                      <IconButton
                        label={`Remove ${name} from package`}
                        icon={<X className="size-4" />}
                        size="sm"
                        variant="danger"
                        disabled={remove.isPending}
                        onClick={() =>
                          remove.mutate(item.id, { onError: (error) => toast.error(error) })
                        }
                      />
                    </div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
        {canManage && (
          <div className="border-line flex gap-2 border-t px-4 py-3 sm:px-5">
            <Select
              aria-label="Service to include"
              placeholder={candidates.length === 0 ? 'Nothing else to add' : 'Choose a service…'}
              value={choice}
              onChange={(e) => setChoice(e.target.value)}
              options={candidates.map((s) => ({
                value: s.id,
                label: `${s.name} (${KIND_LABELS[s.kind]})`,
              }))}
              className="min-w-0 flex-1"
            />
            <Button
              variant="secondary"
              leadingIcon={<Plus />}
              disabled={!choice}
              loading={add.isPending}
              onClick={() => void onAdd()}
            >
              Add
            </Button>
          </div>
        )}
      </>
    );

  return (
    <SectionCard title="Package contents" description="Services included in this package." flush>
      {body}
    </SectionCard>
  );
}

/** Add-ons offered with a service (service_addons). None selected = all add-ons. */
export function AddonsCard({ service, canManage }: { service: ServiceRow; canManage: boolean }) {
  const toast = useToast();
  const links = useServiceAddons(service.id);
  const services = useServices();
  const toggle = useToggleAddon(service.id);

  const linked = new Set((links.data ?? []).map((l) => l.addon_id));
  const addons = (services.data ?? []).filter(
    (s) => s.kind === 'addon' && (s.archived_at === null || linked.has(s.id)),
  );

  let body;
  if (links.isPending || services.isPending)
    body = <LoadingState label="Loading add-ons…" variant="rows" rows={2} />;
  else if (links.error || services.error)
    body = (
      <ErrorState
        compact
        error={links.error ?? services.error}
        title="Couldn’t load add-ons"
        onRetry={() => {
          void links.refetch();
          void services.refetch();
        }}
      />
    );
  else if (addons.length === 0)
    body = (
      <EmptyState
        compact
        title="No add-ons in the catalog"
        description="Create items of type Add-on to offer them with this service."
      />
    );
  else
    body = (
      <div className="flex flex-col gap-3 px-4 py-3 sm:px-5">
        <p className="text-muted text-xs">
          {linked.size === 0 ? (
            <Badge tone="info">All add-ons are offered</Badge>
          ) : (
            `Only the selected add-ons are offered with ${service.name}.`
          )}
        </p>
        {canManage ? (
          <fieldset className="flex flex-col gap-2">
            <legend className="sr-only">Add-ons offered with {service.name}</legend>
            {addons.map((addon) => (
              <Checkbox
                key={addon.id}
                label={addon.archived_at ? `${addon.name} (archived)` : addon.name}
                checked={linked.has(addon.id)}
                disabled={toggle.isPending}
                onChange={(e) =>
                  toggle.mutate(
                    { addonId: addon.id, offered: e.target.checked },
                    { onError: (error) => toast.error(error) },
                  )
                }
              />
            ))}
          </fieldset>
        ) : (
          linked.size > 0 && (
            <ul className="text-ink list-disc pl-5 text-sm">
              {addons
                .filter((a) => linked.has(a.id))
                .map((a) => (
                  <li key={a.id}>{a.name}</li>
                ))}
            </ul>
          )
        )}
      </div>
    );

  return (
    <SectionCard title="Add-ons" description="Leave all unchecked to offer every add-on." flush>
      {body}
    </SectionCard>
  );
}
