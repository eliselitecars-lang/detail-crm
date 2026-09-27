import { useState } from 'react';
import {
  Button,
  FormField,
  Input,
  MoneyInput,
  SectionCard,
  Select,
  useToast,
} from '@/components/ui';
import { bpsToPercentInput, parsePercentToBps } from '@/lib/money';
import { describeDiscount, isDiscountKind, type DiscountKind } from './discount';

export interface DiscountEditorProps {
  kind: DiscountKind;
  /** percent: basis points; fixed: cents. */
  value: number;
  currency: string;
  editable: boolean;
  onSave: (kind: DiscountKind, value: number) => Promise<unknown>;
}

const KIND_OPTIONS = [
  { value: 'none', label: 'No discount' },
  { value: 'percent', label: 'Percent off' },
  { value: 'fixed', label: 'Amount off' },
] as const;

/** Document-level discount (applied by the server to the subtotal, capped). */
export function DiscountEditor({ kind, value, currency, editable, onSave }: DiscountEditorProps) {
  const toast = useToast();
  const [draftKind, setDraftKind] = useState<DiscountKind>(kind);
  const [percent, setPercent] = useState(kind === 'percent' ? bpsToPercentInput(value) : '');
  const [cents, setCents] = useState<number | null>(kind === 'fixed' ? value : null);
  const [saving, setSaving] = useState(false);
  const [synced, setSynced] = useState({ kind, value });

  // Adopt server changes (e.g. after a refetch) when not editing.
  if (synced.kind !== kind || synced.value !== value) {
    setSynced({ kind, value });
    setDraftKind(kind);
    setPercent(kind === 'percent' ? bpsToPercentInput(value) : '');
    setCents(kind === 'fixed' ? value : null);
  }

  const percentBps = parsePercentToBps(percent);
  const error =
    draftKind === 'percent' && percentBps === null
      ? 'Enter a percentage between 0 and 100.'
      : draftKind === 'fixed' && cents === null
        ? 'Enter an amount.'
        : undefined;
  const nextValue =
    draftKind === 'percent' ? (percentBps ?? 0) : draftKind === 'fixed' ? (cents ?? 0) : 0;
  const dirty = draftKind !== kind || nextValue !== value;

  const save = async () => {
    if (error) return;
    setSaving(true);
    try {
      await onSave(draftKind, nextValue);
      toast.success('Discount saved');
    } catch (err) {
      toast.error(err);
    } finally {
      setSaving(false);
    }
  };

  if (!editable) {
    return (
      <SectionCard title="Discount">
        <p className="text-ink text-sm">{describeDiscount(kind, value, currency)}</p>
      </SectionCard>
    );
  }

  return (
    <SectionCard title="Discount" description="Applied to the subtotal before tax.">
      <form
        className="flex flex-col gap-3"
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          void save();
        }}
      >
        <FormField label="Discount type">
          <Select
            value={draftKind}
            options={KIND_OPTIONS}
            onChange={(event) => {
              if (isDiscountKind(event.target.value)) setDraftKind(event.target.value);
            }}
          />
        </FormField>
        {draftKind === 'percent' && (
          <FormField label="Percent" error={percent === '' ? undefined : error}>
            <Input
              inputMode="decimal"
              trailing="%"
              value={percent}
              onChange={(event) => setPercent(event.target.value)}
            />
          </FormField>
        )}
        {draftKind === 'fixed' && (
          <FormField label="Amount" error={cents === null ? undefined : error}>
            <MoneyInput value={cents} onChange={setCents} />
          </FormField>
        )}
        <div className="flex justify-end">
          <Button
            type="submit"
            size="sm"
            variant="secondary"
            loading={saving}
            disabled={!dirty || Boolean(error)}
          >
            Save discount
          </Button>
        </div>
      </form>
    </SectionCard>
  );
}
