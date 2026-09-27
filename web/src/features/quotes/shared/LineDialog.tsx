import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import { Button, Checkbox, Dialog, FormField, Input, MoneyInput, Textarea } from '@/components/ui';
import { zCents, zOptionalText, zRequiredText } from '@/lib/validation';
import { formatQuantity, parseQuantity } from './format';
import type { DocLine, LineDraft } from './lines';

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
});

type LineFormInput = z.input<typeof lineSchema>;
type LineFormOutput = z.output<typeof lineSchema>;

export interface LineDialogProps {
  open: boolean;
  onClose: () => void;
  /** Editing an existing line; null = new custom line. */
  line: DocLine | null;
  supportsOptional: boolean;
  onSubmit: (draft: LineDraft) => Promise<unknown>;
}

function defaults(line: DocLine | null): LineFormInput {
  return {
    name: line?.name ?? '',
    description: line?.description ?? '',
    quantity: line ? formatQuantity(line.quantity) : '1',
    unit_price_cents: line?.unit_price_cents ?? Number.NaN,
    discount_cents: line && line.discount_cents > 0 ? line.discount_cents : null,
    taxable: line?.taxable ?? true,
    optional: line?.optional ?? false,
  };
}

/** Add a custom line or edit any line (quantity, price, discount, taxable, optional). */
export function LineDialog({ open, onClose, line, supportsOptional, onSubmit }: LineDialogProps) {
  const form = useForm<LineFormInput, unknown, LineFormOutput>({
    resolver: zodResolver(lineSchema),
    values: defaults(line),
  });
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
