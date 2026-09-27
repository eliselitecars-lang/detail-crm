import { zodResolver } from '@hookform/resolvers/zod';
import { useMemo } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import { Button, Dialog, FormField, MoneyInput, Select, Textarea, useToast } from '@/components/ui';
import { formatCents } from '@/lib/money';
import { zCents, zOptionalText } from '@/lib/validation';
import {
  MANUAL_METHODS,
  METHOD_LABELS,
  type ManualMethod,
} from '@/features/payments/paymentFormat';
import { useRecordManualPayment } from '../api';

export interface RecordPaymentDialogProps {
  open: boolean;
  onClose: () => void;
  invoiceId: string;
  invoiceNumber: number;
  /** Current server balance (upper bound; the RPC re-checks it). */
  balanceCents: number;
  currency: string;
}

function schemaFor(balanceCents: number, currency: string) {
  return z.object({
    method: z.enum(MANUAL_METHODS),
    amount: zCents
      .refine((v) => v > 0, 'Enter an amount greater than zero.')
      .refine(
        (v) => v <= balanceCents,
        `The amount can’t be more than the balance due (${formatCents(balanceCents, { currency })}).`,
      ),
    tip: zCents.nullable().transform((v) => v ?? 0),
    note: zOptionalText(1000),
  });
}

type FormInput = z.input<ReturnType<typeof schemaFor>>;
type FormOutput = z.output<ReturnType<typeof schemaFor>>;

/** Cash / check / bank transfer / other → record_manual_payment. */
export function RecordPaymentDialog(props: RecordPaymentDialogProps) {
  return (
    <Dialog
      open={props.open}
      onClose={props.onClose}
      title={`Record a payment on invoice #${props.invoiceNumber}`}
      description="For money received outside the card terminal. Tips never reduce the balance."
    >
      {props.open && <RecordPaymentForm {...props} />}
    </Dialog>
  );
}

function RecordPaymentForm({
  onClose,
  invoiceId,
  balanceCents,
  currency,
}: RecordPaymentDialogProps) {
  const toast = useToast();
  const record = useRecordManualPayment(invoiceId);
  const schema = useMemo(() => schemaFor(balanceCents, currency), [balanceCents, currency]);
  const form = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(schema),
    defaultValues: { method: 'cash', amount: balanceCents, tip: null, note: '' },
  });
  const { errors, isSubmitting } = form.formState;

  const submit = form.handleSubmit(async (values) => {
    try {
      await record.mutateAsync({
        amountCents: values.amount,
        method: values.method,
        tipCents: values.tip,
        note: values.note,
      });
      toast.success(`${formatCents(values.amount, { currency })} payment recorded`);
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  return (
    <form noValidate className="flex flex-col gap-4" onSubmit={(event) => void submit(event)}>
      <FormField label="Method" required error={errors.method?.message}>
        <Select
          {...form.register('method')}
          options={MANUAL_METHODS.map((m: ManualMethod) => ({ value: m, label: METHOD_LABELS[m] }))}
        />
      </FormField>
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <FormField
          label="Amount"
          required
          error={errors.amount?.message}
          help={`Balance due: ${formatCents(balanceCents, { currency })}`}
        >
          <Controller
            control={form.control}
            name="amount"
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
        <FormField label="Tip" error={errors.tip?.message}>
          <Controller
            control={form.control}
            name="tip"
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
      <FormField label="Note" error={errors.note?.message} help="Check number, reference…">
        <Textarea rows={2} {...form.register('note')} />
      </FormField>
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="secondary" onClick={onClose} disabled={isSubmitting}>
          Cancel
        </Button>
        <Button type="submit" variant="money" loading={isSubmitting}>
          Record payment
        </Button>
      </div>
    </form>
  );
}
