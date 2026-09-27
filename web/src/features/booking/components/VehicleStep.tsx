import { useState } from 'react';
import { FormField, Input, RadioGroup } from '@/components/ui';
import type { BookingCatalog } from '../api';
import { validateVehicle, type FieldErrors, type VehicleInput } from '../model';
import { Banner } from '@/features/public-docs/shared/PublicPage';
import { StepFrame } from './StepFrame';

export function VehicleStep({
  catalog,
  value,
  onChange,
  onContinue,
  notice = null,
}: {
  catalog: BookingCatalog;
  value: VehicleInput;
  onChange: (next: VehicleInput) => void;
  onContinue: () => void;
  notice?: string | null;
}) {
  const [errors, setErrors] = useState<FieldErrors<keyof VehicleInput>>({});
  const [submitted, setSubmitted] = useState(false);
  const requireCategory = catalog.vehicle_categories.length > 0;

  const update = (patch: Partial<VehicleInput>) => {
    const next = { ...value, ...patch };
    onChange(next);
    if (submitted) setErrors(validateVehicle(next, requireCategory));
  };

  const next = () => {
    setSubmitted(true);
    const found = validateVehicle(value, requireCategory);
    setErrors(found);
    if (Object.keys(found).length === 0) onContinue();
  };

  return (
    <StepFrame
      title="Tell us about your vehicle"
      description="Pricing depends on the size and type of vehicle."
      onContinue={next}
    >
      {notice && <Banner tone="warning" title={notice} />}
      {requireCategory && (
        <RadioGroup<string>
          label="Vehicle type"
          value={value.categoryId}
          onChange={(categoryId) => update({ categoryId })}
          options={catalog.vehicle_categories.map((c) => ({ value: c.id, label: c.name }))}
          variant="cards"
          orientation="horizontal"
          error={errors.categoryId}
        />
      )}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <FormField label="Year" error={errors.year}>
          <Input
            value={value.year}
            onChange={(event) =>
              update({ year: event.target.value.replace(/[^\d]/g, '').slice(0, 4) })
            }
            inputMode="numeric"
            autoComplete="off"
            placeholder="e.g. 2021"
          />
        </FormField>
        <FormField label="Make" required error={errors.make}>
          <Input
            value={value.make}
            onChange={(event) => update({ make: event.target.value })}
            maxLength={60}
            autoComplete="off"
            placeholder="e.g. Toyota"
          />
        </FormField>
        <FormField label="Model" required error={errors.model}>
          <Input
            value={value.model}
            onChange={(event) => update({ model: event.target.value })}
            maxLength={60}
            autoComplete="off"
            placeholder="e.g. Camry"
          />
        </FormField>
        <FormField label="Color" error={errors.color}>
          <Input
            value={value.color}
            onChange={(event) => update({ color: event.target.value })}
            maxLength={40}
            autoComplete="off"
          />
        </FormField>
      </div>
    </StepFrame>
  );
}
