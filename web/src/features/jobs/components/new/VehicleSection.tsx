import { ScanLine } from 'lucide-react';
import { useState, type KeyboardEvent } from 'react';
import {
  Button,
  ErrorState,
  FormField,
  Input,
  LoadingState,
  RadioGroup,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import type { VehicleCategory } from '../../api';
import { vehicleLabel } from '../../model';
import { useCreateVehicle, useCustomerVehicles, type VehicleOption } from '../../newJobApi';
import { decodeVin, normalizeVin } from '../../vin';

export interface VehicleSectionProps {
  customerId: string;
  vehicleId: string | null;
  categoryId: string;
  categories: VehicleCategory[];
  onVehicle: (vehicle: VehicleOption | null) => void;
  onCategory: (categoryId: string) => void;
}

const NONE = 'none';

export function VehicleSection({
  customerId,
  vehicleId,
  categoryId,
  categories,
  onVehicle,
  onCategory,
}: VehicleSectionProps) {
  const vehicles = useCustomerVehicles(customerId);
  const [adding, setAdding] = useState(false);
  const list = vehicles.data ?? [];

  return (
    <SectionCard
      title="Vehicle"
      description="The vehicle size sets catalog prices."
      actions={
        !adding ? (
          <Button size="sm" variant="secondary" onClick={() => setAdding(true)}>
            Add vehicle
          </Button>
        ) : undefined
      }
    >
      <div className="flex flex-col gap-4">
        {vehicles.isPending ? (
          <LoadingState label="Loading vehicles…" />
        ) : vehicles.isError ? (
          <ErrorState compact error={vehicles.error} onRetry={() => void vehicles.refetch()} />
        ) : (
          !adding && (
            <RadioGroup<string>
              label="Vehicle"
              variant="cards"
              value={vehicleId ?? NONE}
              onChange={(value) => onVehicle(list.find((v) => v.id === value) ?? null)}
              options={[
                ...list.map((v) => ({
                  value: v.id,
                  label: vehicleLabel(v, true),
                  description: [v.license_plate, v.vin].filter(Boolean).join(' · ') || undefined,
                })),
                { value: NONE, label: 'No vehicle', description: 'Price by size only' },
              ]}
            />
          )
        )}
        {adding && (
          <NewVehicleForm
            customerId={customerId}
            categories={categories}
            onCancel={() => setAdding(false)}
            onCreated={(v) => {
              setAdding(false);
              onVehicle(v);
            }}
          />
        )}
        {/* Without vehicle sizes every service is priced at its base price. */}
        {categories.length > 0 && (
          <FormField label="Vehicle size" required>
            <Select
              value={categoryId}
              onChange={(e) => onCategory(e.target.value)}
              placeholder="Choose a size"
              options={categories.map((c) => ({ value: c.id, label: c.name }))}
            />
          </FormField>
        )}
      </div>
    </SectionCard>
  );
}

function NewVehicleForm({
  customerId,
  categories,
  onCancel,
  onCreated,
}: {
  customerId: string;
  categories: VehicleCategory[];
  onCancel: () => void;
  onCreated: (vehicle: VehicleOption) => void;
}) {
  const toast = useToast();
  const create = useCreateVehicle(customerId);
  const [form, setForm] = useState({
    vin: '',
    year: '',
    make: '',
    model: '',
    trim: '',
    color: '',
    plate: '',
    categoryId: '',
  });
  const [decoding, setDecoding] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const set = (patch: Partial<typeof form>) => setForm((f) => ({ ...f, ...patch }));

  const decode = async () => {
    setDecoding(true);
    setErrors({});
    try {
      const d = await decodeVin(form.vin);
      set({
        vin: normalizeVin(form.vin),
        year: d.year?.toString() ?? form.year,
        make: d.make ?? form.make,
        model: d.model ?? form.model,
        trim: d.trim ?? form.trim,
      });
      toast.success('VIN decoded');
    } catch (error) {
      setErrors({ vin: error instanceof Error ? error.message : 'Couldn’t decode this VIN.' });
    } finally {
      setDecoding(false);
    }
  };

  const submit = async () => {
    const next: Record<string, string> = {};
    const year = form.year.trim() ? Number(form.year) : null;
    const vin = normalizeVin(form.vin);
    if (year !== null && (!Number.isInteger(year) || year < 1886 || year > 2100)) {
      next.year = 'Enter a 4-digit year.';
    }
    if (vin && !/^[A-Z0-9]{5,17}$/.test(vin)) next.vin = 'A VIN has 5–17 letters and numbers.';
    if (!form.make.trim() && !form.model.trim()) next.make = 'Enter the make or model.';
    setErrors(next);
    if (Object.keys(next).length > 0) return;
    try {
      const vehicle = await create.mutateAsync({
        vin: vin || null,
        year,
        make: form.make.trim() || null,
        model: form.model.trim() || null,
        trim: form.trim.trim() || null,
        color: form.color.trim() || null,
        license_plate: form.plate.trim() || null,
        category_id: form.categoryId || null,
      });
      toast.success('Vehicle added');
      onCreated(vehicle);
    } catch (error) {
      toast.error(error);
    }
  };

  // Enter in a field saves this record instead of submitting the job form.
  const submitOnEnter = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      void submit();
    }
  };

  return (
    // Not a <form>: this sits inside the New job form (forms can't nest).
    <div role="group" aria-label="New vehicle" className="grid grid-cols-2 gap-3 sm:grid-cols-4">
      <FormField label="VIN" error={errors.vin} className="col-span-2 sm:col-span-3">
        <Input
          onKeyDown={submitOnEnter}
          value={form.vin}
          maxLength={20}
          autoCapitalize="characters"
          onChange={(e) => set({ vin: e.target.value })}
        />
      </FormField>
      <div className="col-span-2 flex items-end sm:col-span-1">
        <Button
          type="button"
          variant="secondary"
          fullWidth
          loading={decoding}
          disabled={!form.vin.trim()}
          leadingIcon={<ScanLine className="size-4" aria-hidden="true" />}
          onClick={() => void decode()}
        >
          Decode
        </Button>
      </div>
      <FormField label="Year" error={errors.year}>
        <Input
          onKeyDown={submitOnEnter}
          inputMode="numeric"
          maxLength={4}
          value={form.year}
          onChange={(e) => set({ year: e.target.value })}
        />
      </FormField>
      <FormField label="Make" error={errors.make}>
        <Input
          onKeyDown={submitOnEnter}
          value={form.make}
          maxLength={60}
          onChange={(e) => set({ make: e.target.value })}
        />
      </FormField>
      <FormField label="Model">
        <Input
          onKeyDown={submitOnEnter}
          value={form.model}
          maxLength={60}
          onChange={(e) => set({ model: e.target.value })}
        />
      </FormField>
      <FormField label="Trim">
        <Input
          onKeyDown={submitOnEnter}
          value={form.trim}
          maxLength={60}
          onChange={(e) => set({ trim: e.target.value })}
        />
      </FormField>
      <FormField label="Color">
        <Input
          onKeyDown={submitOnEnter}
          value={form.color}
          maxLength={40}
          onChange={(e) => set({ color: e.target.value })}
        />
      </FormField>
      <FormField label="Plate">
        <Input
          onKeyDown={submitOnEnter}
          value={form.plate}
          maxLength={15}
          onChange={(e) => set({ plate: e.target.value })}
        />
      </FormField>
      {categories.length > 0 && (
        <FormField label="Size" className="col-span-2">
          <Select
            value={form.categoryId}
            onChange={(e) => set({ categoryId: e.target.value })}
            placeholder="Choose a size"
            options={categories.map((c) => ({ value: c.id, label: c.name }))}
          />
        </FormField>
      )}
      <div className="col-span-2 flex gap-2 sm:col-span-4">
        <Button loading={create.isPending} onClick={() => void submit()}>
          Save vehicle
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel} disabled={create.isPending}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
