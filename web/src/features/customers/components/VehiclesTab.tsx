import { Archive, ArchiveRestore, Car, Pencil, Plus } from 'lucide-react';
import { useState } from 'react';
import {
  Badge,
  Button,
  Card,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  LoadingState,
  Switch,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { toAppError } from '@/lib/errors';
import { useCustomerVehicles, useSetVehicleArchived, useVehicleCategories } from '../api';
import { vehicleLabel, type VehicleRow } from '../model';
import { VehicleFormDialog } from './VehicleFormDialog';

type Editing = { mode: 'new' } | { mode: 'edit'; vehicle: VehicleRow } | null;

export function VehiclesTab({
  customerId,
  archivedCustomer,
}: {
  customerId: string;
  archivedCustomer: boolean;
}) {
  const { shopId } = useShop();
  const canManage = useCan('customers.manage');
  const toast = useToast();
  const [showArchived, setShowArchived] = useState(false);
  const [editing, setEditing] = useState<Editing>(null);
  const [archiving, setArchiving] = useState<VehicleRow | null>(null);
  const vehicles = useCustomerVehicles(shopId, customerId, showArchived);
  const categories = useVehicleCategories(shopId);
  const setArchived = useSetVehicleArchived(shopId);

  const categoryName = (id: string | null) =>
    id ? (categories.data?.find((c) => c.id === id)?.name ?? null) : null;

  const toggleArchive = async (vehicle: VehicleRow, archived: boolean) => {
    try {
      await setArchived.mutateAsync({ id: vehicle.id, archived });
      toast.success(archived ? 'Vehicle archived' : 'Vehicle restored');
      setArchiving(null);
    } catch (error) {
      toast.error(toAppError(error).message);
    }
  };

  const canAdd = canManage && !archivedCustomer;

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-3">
        {canManage ? (
          <Switch
            checked={showArchived}
            onCheckedChange={setShowArchived}
            label="Show archived vehicles"
            className="flex-row-reverse justify-end"
          />
        ) : (
          <span />
        )}
        {canAdd && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ mode: 'new' })}
          >
            Add vehicle
          </Button>
        )}
      </div>

      {vehicles.isPending ? (
        <Card>
          <LoadingState variant="rows" rows={3} label="Loading vehicles…" />
        </Card>
      ) : vehicles.isError ? (
        <Card>
          <ErrorState error={vehicles.error} onRetry={() => void vehicles.refetch()} />
        </Card>
      ) : vehicles.data.length === 0 ? (
        <Card>
          <EmptyState
            icon={<Car aria-hidden="true" />}
            title="No vehicles yet"
            description={
              canAdd ? 'Add a vehicle, or decode it from the VIN.' : 'No vehicles are on file.'
            }
            action={
              canAdd && <Button onClick={() => setEditing({ mode: 'new' })}>Add vehicle</Button>
            }
          />
        </Card>
      ) : (
        <ul className="grid grid-cols-1 gap-3 md:grid-cols-2" aria-label="Vehicles">
          {vehicles.data.map((v) => {
            const category = categoryName(v.category_id);
            return (
              <li key={v.id}>
                <Card className="flex h-full flex-col gap-3 p-4">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <h3 className="text-ink text-sm font-semibold break-words">
                        {vehicleLabel(v, true)}
                      </h3>
                      <div className="mt-1 flex flex-wrap gap-1">
                        {v.color && <Badge>{v.color}</Badge>}
                        {category && <Badge tone="info">{category}</Badge>}
                        {v.archived_at && <Badge>Archived</Badge>}
                      </div>
                    </div>
                    {canManage && (
                      <div className="flex shrink-0 gap-1">
                        <Button
                          size="sm"
                          variant="ghost"
                          leadingIcon={<Pencil className="size-3.5" aria-hidden="true" />}
                          aria-label={`Edit ${vehicleLabel(v)}`}
                          onClick={() => setEditing({ mode: 'edit', vehicle: v })}
                        >
                          Edit
                        </Button>
                        {v.archived_at ? (
                          <Button
                            size="sm"
                            variant="ghost"
                            leadingIcon={<ArchiveRestore className="size-3.5" aria-hidden="true" />}
                            aria-label={`Restore ${vehicleLabel(v)}`}
                            loading={setArchived.isPending && setArchived.variables?.id === v.id}
                            onClick={() => void toggleArchive(v, false)}
                          >
                            Restore
                          </Button>
                        ) : (
                          <Button
                            size="sm"
                            variant="ghost"
                            leadingIcon={<Archive className="size-3.5" aria-hidden="true" />}
                            aria-label={`Archive ${vehicleLabel(v)}`}
                            onClick={() => setArchiving(v)}
                          >
                            Archive
                          </Button>
                        )}
                      </div>
                    )}
                  </div>
                  <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                    <dt className="text-muted">VIN</dt>
                    <dd className="text-ink font-mono text-xs leading-5 break-all">
                      {v.vin ?? '—'}
                    </dd>
                    <dt className="text-muted">Plate</dt>
                    <dd className="text-ink">{v.license_plate ?? '—'}</dd>
                  </dl>
                  {v.notes && (
                    <p className="text-muted text-sm break-words whitespace-pre-wrap">{v.notes}</p>
                  )}
                </Card>
              </li>
            );
          })}
        </ul>
      )}

      {editing && (
        <VehicleFormDialog
          customerId={customerId}
          {...(editing.mode === 'edit' ? { vehicle: editing.vehicle } : {})}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={archiving !== null}
        onClose={() => setArchiving(null)}
        onConfirm={() => (archiving ? toggleArchive(archiving, true) : undefined)}
        loading={setArchived.isPending}
        title="Archive this vehicle?"
        description="It’s hidden from new jobs and quotes. Past jobs keep it, and you can restore it anytime."
        confirmLabel="Archive vehicle"
      />
    </div>
  );
}
