import { useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router';
import {
  Button,
  Card,
  CardBody,
  CardFooter,
  ErrorState,
  FormField,
  PageHeader,
  Textarea,
  useToast,
} from '@/components/ui';
import { useCustomer, type PickerCustomer } from '@/features/quotes/shared/api';
import { CustomerCombobox } from '@/features/quotes/shared/CustomerPicker';
import { useCreateInvoice } from './api';

/**
 * /app/invoices/new?customerId= — an ad-hoc draft invoice (no job). Lines,
 * discount and due date are added on the invoice page; the server numbers
 * it and applies the shop's tax rate and invoice terms.
 */
export default function InvoiceNewPage() {
  const toast = useToast();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const presetId = params.get('customerId');
  const preset = useCustomer(presetId);
  const create = useCreateInvoice();
  const [picked, setPicked] = useState<PickerCustomer | null | undefined>(undefined);
  const [notes, setNotes] = useState('');
  const [submitted, setSubmitted] = useState(false);

  const customer = picked === undefined ? (preset.data ?? null) : picked;
  const customerError = customer ? undefined : 'Choose a customer.';
  const notesError = notes.length > 20000 ? 'Notes are too long.' : undefined;

  const submit = async () => {
    setSubmitted(true);
    if (!customer || notesError) return;
    try {
      const invoice = await create.mutateAsync({
        customerId: customer.id,
        notes: notes.trim() || null,
      });
      toast.success(`Invoice #${invoice.number} created`);
      await navigate(`/app/invoices/${invoice.id}`, { replace: true });
    } catch (error) {
      toast.error(error);
    }
  };

  return (
    <>
      <PageHeader
        title="New invoice"
        description="For work without a job. Invoices for jobs are created from the job page."
        back={{ to: '/app/invoices', label: 'Invoices' }}
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
            <FormField label="Customer" required error={submitted ? customerError : undefined}>
              <CustomerCombobox
                value={customer}
                onChange={setPicked}
                disabled={Boolean(presetId) && preset.isPending && picked === undefined}
              />
            </FormField>
            <FormField label="Notes for the customer" error={notesError}>
              <Textarea rows={3} value={notes} onChange={(event) => setNotes(event.target.value)} />
            </FormField>
            <p className="text-muted text-sm">
              Next you’ll add line items, a discount and the due date.
            </p>
          </CardBody>
          <CardFooter>
            <Button variant="secondary" onClick={() => void navigate('/app/invoices')}>
              Cancel
            </Button>
            <Button type="submit" loading={create.isPending}>
              Create draft invoice
            </Button>
          </CardFooter>
        </form>
      </Card>
    </>
  );
}
