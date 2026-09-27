import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import {
  Button,
  Card,
  CardBody,
  CardFooter,
  DateInput,
  ErrorState,
  FormField,
  PageHeader,
  Textarea,
  useToast,
} from '@/components/ui';
import { formatLocalDate, isLocalDate, shopToday } from '@/lib/dates';
import { useShop } from '@/features/shop/shopContext';
import { useCreateQuote } from './api';
import { useCustomer, useDocDefaults, type PickerCustomer } from './shared/api';
import { CustomerCombobox, VehicleSelect } from './shared/CustomerPicker';

const MAX_TEXT = 20000;

/** /app/quotes/new?customerId= — pick the customer, then build the quote. */
export default function QuoteNewPage() {
  const { timezone } = useShop();
  const toast = useToast();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const presetId = params.get('customerId');
  const preset = useCustomer(presetId);
  const defaults = useDocDefaults();
  const create = useCreateQuote();

  // undefined = untouched (fall back to the ?customerId preset / shop default terms)
  const [picked, setPicked] = useState<PickerCustomer | null | undefined>(undefined);
  const [vehicleId, setVehicleId] = useState<string | null>(null);
  const [validUntil, setValidUntil] = useState('');
  const [notes, setNotes] = useState('');
  const [terms, setTerms] = useState<string | undefined>(undefined);
  const [submitted, setSubmitted] = useState(false);

  const customer = picked === undefined ? (preset.data ?? null) : picked;
  const termsValue = terms ?? defaults.data?.quote_terms ?? '';
  const today = shopToday(timezone);

  const errors = {
    customer: customer ? undefined : 'Choose a customer.',
    validUntil:
      validUntil === ''
        ? undefined
        : !isLocalDate(validUntil)
          ? 'Enter a valid date.'
          : validUntil < today
            ? 'The quote must be valid through today or later.'
            : undefined,
    notes: notes.length > MAX_TEXT ? 'Notes are too long.' : undefined,
    terms: termsValue.length > MAX_TEXT ? 'Terms are too long.' : undefined,
  };
  const hasErrors = Object.values(errors).some(Boolean);

  const submit = async () => {
    setSubmitted(true);
    if (hasErrors || !customer) return;
    try {
      const quote = await create.mutateAsync({
        customerId: customer.id,
        vehicleId,
        validUntil: validUntil || null,
        notes: notes.trim() || null,
        terms: termsValue.trim() || null,
      });
      toast.success(`Quote #${quote.number} created`);
      await navigate(`/app/quotes/${quote.id}`, { replace: true });
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <>
      <PageHeader
        title="New quote"
        description="Choose the customer and vehicle; you’ll add line items next."
        back={{ to: '/app/quotes', label: 'Quotes' }}
      />
      <Card className="max-w-2xl">
        <form
          noValidate
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <CardBody className="flex flex-col gap-4">
            {presetId && preset.isError && (
              <ErrorState
                compact
                title="Couldn’t load that customer"
                error={preset.error}
                onRetry={() => void preset.refetch()}
              />
            )}
            <FormField label="Customer" required error={submitted ? errors.customer : undefined}>
              <CustomerCombobox
                value={customer}
                onChange={(next) => {
                  setPicked(next);
                  setVehicleId(null);
                }}
                disabled={Boolean(presetId) && preset.isPending && picked === undefined}
              />
            </FormField>
            <FormField label="Vehicle" help="Optional. Sets the default price size in the catalog.">
              <VehicleSelect
                customerId={customer?.id ?? null}
                value={vehicleId}
                onChange={setVehicleId}
              />
            </FormField>
            <FormField
              label="Valid until"
              error={errors.validUntil}
              help={
                validUntil && !errors.validUntil
                  ? `Valid through the end of ${formatLocalDate(validUntil)} (shop time).`
                  : 'Optional. Leave empty for no expiry.'
              }
            >
              <DateInput
                value={validUntil}
                min={today}
                onChange={(event) => setValidUntil(event.target.value)}
              />
            </FormField>
            <FormField label="Notes for the customer" error={errors.notes}>
              <Textarea rows={3} value={notes} onChange={(event) => setNotes(event.target.value)} />
            </FormField>
            <FormField
              label="Terms"
              error={errors.terms}
              help={
                defaults.isError
                  ? 'Couldn’t load your default terms.'
                  : 'Defaults to your shop’s quote terms.'
              }
            >
              <Textarea
                rows={4}
                value={termsValue}
                onChange={(event) => setTerms(event.target.value)}
              />
            </FormField>
          </CardBody>
          <CardFooter className="flex justify-end gap-2">
            <Button variant="secondary" onClick={() => void navigate('/app/quotes')}>
              Cancel
            </Button>
            <Button type="submit" loading={create.isPending} disabled={submitted && hasErrors}>
              Create quote
            </Button>
          </CardFooter>
        </form>
      </Card>
    </>
  );
}
