import { useState } from 'react';
import { Combobox, Select } from '@/components/ui';
import { formatPhone } from '@/lib/phone';
import { useCustomerSearch, useCustomerVehicles, type PickerCustomer } from './api';
import { customerName, vehicleLabel } from './format';

export interface CustomerComboboxProps {
  value: PickerCustomer | null;
  onChange: (customer: PickerCustomer | null) => void;
  disabled?: boolean;
  /** Customers never offered (e.g. the customer being merged). */
  excludeIds?: readonly string[];
}

/** Searchable customer picker (use inside <FormField label="Customer">). */
export function CustomerCombobox({
  value,
  onChange,
  disabled,
  excludeIds = [],
}: CustomerComboboxProps) {
  const [query, setQuery] = useState('');
  const search = useCustomerSearch(query);
  const found = search.data ?? [];
  const options = excludeIds.length === 0 ? found : found.filter((c) => !excludeIds.includes(c.id));
  return (
    <Combobox<PickerCustomer>
      value={value}
      onChange={onChange}
      options={options}
      loading={search.isFetching}
      onQueryChange={setQuery}
      getOptionValue={(c) => c.id}
      getOptionLabel={(c) => customerName(c)}
      renderOption={(c) => (
        <span className="flex flex-col">
          <span className="text-ink text-sm">{customerName(c)}</span>
          <span className="text-muted text-xs">
            {[c.email, c.phone ? formatPhone(c.phone) : null].filter(Boolean).join(' · ') ||
              'No contact details'}
          </span>
        </span>
      )}
      placeholder="Search customers by name, email or phone…"
      emptyText={search.isError ? 'Couldn’t search customers' : 'No customers found'}
      disabled={disabled}
    />
  );
}

export interface VehicleSelectProps {
  customerId: string | null;
  value: string | null;
  onChange: (vehicleId: string | null) => void;
  disabled?: boolean;
  /** Label of the empty option. */
  emptyLabel?: string;
}

/** The customer's vehicles (use inside <FormField label="Vehicle">). */
export function VehicleSelect({
  customerId,
  value,
  onChange,
  disabled,
  emptyLabel = 'No specific vehicle',
}: VehicleSelectProps) {
  const vehicles = useCustomerVehicles(customerId);
  const options = (vehicles.data ?? []).map((v) => ({ value: v.id, label: vehicleLabel(v) }));
  return (
    <Select
      value={value ?? ''}
      disabled={disabled || !customerId || vehicles.isPending}
      onChange={(event) => onChange(event.target.value || null)}
      placeholder={
        !customerId
          ? 'Choose a customer first'
          : vehicles.isPending
            ? 'Loading vehicles…'
            : vehicles.isError
              ? 'Couldn’t load vehicles'
              : emptyLabel
      }
      options={options}
    />
  );
}
