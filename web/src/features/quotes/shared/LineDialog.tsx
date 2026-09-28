import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import {
  Button,
  Checkbox,
  Dialog,
  FormField,
  Input,
  MoneyInput,
  Select,
  Textarea,
} from '@/components/ui';
import { zCents, zOptionalText, zRequiredText } from '@/lib/validation';
import type { PickerVehicle } from './api';
import { formatQuantity, parseQuantity, vehicleLabel } from './format';
import type { DocLine, LineDraft } from './lines';

/** A proposal option a quote line can belong to. */
export interface LineOptionChoice {
  id: string;
  name: string;
}

/** Select value of "shared by every option" / "no vehicle". */
const NONE = '';

const lineSchema = z.object({
  name: zRequiredText('Name', 200),
  description: zOptionalText(5000),
  quantity: z
    .string()
    .refine((v) => parseQuantity(v) !== null, 'Enter a quantity greater than 0 (up to 2 decimals).')
    .transform((v) => parseQuantity(v) ?? 1),
  unit_price_cents: zCents,
  discount_cents: zCents.nullable().transform((v) => v ?? 0),
  taxable: z.boolean(),
  optional: z.boolean(),
  vehicle_id: z.string(),
  option_id: z.string(),
});

type LineFormInput = z.input<typeof lineSchema>;
type LineFormOutput = z.output<typeof lineSchema>;

export interface LineDialogProps {
  open: boolean;
  onClose: () => void;
  /** Editing an existing line; null = new custom line. */
  line: DocLine | null;
  supportsOptional: boolean;
  /**
   * The customer's vehicles: shown as a "Vehicle" picker (fleet quotes and
   * invoices). Omit to hide the picker.
   */
  vehicles?: readonly PickerVehicle[];
  /** Quotes with proposal options: the options a line may belong to. */
  options?: readonly LineOptionChoice[];
  /** Option of a new line (the tab it is added from). */
  defaultOptionId?: string | null;
  onSubmit: (draft: LineDraft) => Promise<unknown>;
}

function defaults(line: DocLine | null, defaultOptionId: string | null): LineFormInput {
  return {
    name: line?.name ?? '',
    description: line?.description ?? '',
    quantity: line ? formatQuantity(line.quantity) : '1',
    unit_price_cents: line?.unit_price_cents ?? Number.NaN,
    discount_cents: line && line.discount_cents > 0 ? line.discount_cents : null,
    taxable: line?.taxable ?? true,
    optional: line?.optional ?? false,
    vehicle_id: line?.vehicle_id ?? NONE,
    option_id: (line ? line.option_id : defaultOptionId) ?? NONE,
  };
}

/** Add a custom line or edit any line (quantity, price, discount, taxable, optional). */
export function LineDialog({
  open,
  onClose,
  line,
  supportsOptional,
  vehicles,
  options,
  defaultOptionId = null,
  onSubmit,
}: LineDialogProps) {
  const form = useForm<LineFormInput, unknown, LineFormOutput>({
    resolver: zodResolver(lineSchema),
    values: defaults(line, defaultOptionId),
  });
  // A line's vehicle may have been archived since: keep it listed so it isn't dropped silently.
  const vehicleChoices = vehicles ?? [];
  const currentVehicleMissing =
    line?.vehicle_id !== null &&
    line?.vehicle_id !== undefined &&
    !vehicleChoices.some((v) => v.id === line.vehicle_id);
  const { errors, isSubmitting } = form.formState;

  const submit = form.handleSubmit(async (values) => {
    await onSubmit({
      service_id: line?.service_id ?? null,
      name: values.name,
      description: values.description,
      quantity: values.quantity,
      unit_price_cents: values.unit_price_cents,
      discount_cents: values.discount_cents,
      taxable: values.taxable,
      optional: supportsOptional ? values.optional : false,
      duration_minutes: line?.duration_minutes ?? 0,
      ...(vehicles ? { vehicle_id: values.vehicle_id === NONE ? null : values.vehicle_id } : {}),
      ...(options && options.length > 0
        ? { option_id: values.option_id === NONE ? null : values.option_id }
        : {}),
    });
    onClose();
  });

  return (
    <Dialog
      open={open}
      onClose={onClose}
      dismissible={!isSubmitting}
      title={line ? 'Edit line item' : 'Add custom line'}
      description="Totals and tax are recalculated by the server when you save."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={isSubmitting}>
            Cancel
          </Button>
          <Button type="submit" form="line-item-form" loading={isSubmitting}>
            {line ? 'Save line' : 'Add line'}
          </Button>
        </>
      }
    >
      <form
        id="line-item-form"
        className="flex flex-col gap-4"
        noValidate
        onSubmit={(event) => void submit(event)}
      >
        <FormField label="Name" required error={errors.name?.message}>
          <Input autoComplete="off" {...form.register('name')} />
        </FormField>
        <FormField label="Description" error={errors.description?.message}>
          <Textarea rows={2} {...form.register('description')} />
        </FormField>
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <FormField label="Quantity" required error={errors.quantity?.message}>
            <Input inputMode="decimal" autoComplete="off" {...form.register('quantity')} />
          </FormField>
          <FormField label="Unit price" required error={errors.unit_price_cents?.message}>
            <Controller
              control={form.control}
              name="unit_price_cents"
              render={({ field }) => (
                <MoneyInput
                  value={Number.isNaN(field.value) ? null : field.value}
                  onChange={(cents) => field.onChange(cents ?? Number.NaN)}
                  onBlur={field.onBlur}
                  name={field.name}
                />
              )}
            />
          </FormField>
          <FormField label="Line discount" error={errors.discount_cents?.message}>
            <Controller
              control={form.control}
              name="discount_cents"
              render={({ field }) => (
                <MoneyInput
                  value={field.value}
                  placeholder="0.00"
                  onChange={(cents) => field.onChange(cents)}
                  onBlur={field.onBlur}
                  name={field.name}
                />
              )}
            />
          </FormField>
        </div>
        {(vehicles || (options && options.length > 0)) && (
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            {vehicles && (
              <FormField
                label="Vehicle"
                help={
                  vehicleChoices.length === 0 && !currentVehicleMissing
                    ? 'This customer has no vehicles on file.'
                    : 'For customers with several vehicles.'
                }
              >
                <Select {...form.register('vehicle_id')}>
                  <option value={NONE}>No specific vehicle</option>
                  {vehicleChoices.map((vehicle) => (
                    <option key={vehicle.id} value={vehicle.id}>
                      {vehicleLabel(vehicle)}
                    </option>
                  ))}
                  {currentVehicleMissing && line?.vehicle_id && (
                    <option value={line.vehicle_id}>Archived vehicle</option>
                  )}
                </Select>
              </FormField>
            )}
            {options && options.length > 0 && (
              <FormField label="Part of" help="Shared lines are in every option.">
                <Select {...form.register('option_id')}>
                  <option value={NONE}>Every option</option>
                  {options.map((option) => (
                    <option key={option.id} value={option.id}>
                      {option.name}
                    </option>
                  ))}
                </Select>
              </FormField>
            )}
          </div>
        )}
        <Checkbox
          label="Taxable"
          description="Include this line in the taxable amount."
          {...form.register('taxable')}
        />
        {supportsOptional && (
          <Checkbox
            label="Optional item"
            description="Shown as an upsell the customer can choose when approving."
            {...form.register('optional')}
          />
        )}
      </form>
    </Dialog>
  );
}
