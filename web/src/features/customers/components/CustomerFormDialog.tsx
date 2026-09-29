import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import {
  Button,
  Dialog,
  FormField,
  Input,
  PhoneInput,
  Select,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { formatDate } from '@/lib/dates';
import { BillingErrorLink } from '@/features/billing/BillingErrorLink';
import { AppError, toAppError } from '@/lib/errors';
import { useCreateCustomer, useKnownTags, useUpdateCustomer } from '../api';
import { LIFECYCLE_LABELS, LIFECYCLES, SOURCE_LABELS, SOURCES, type CustomerRow } from '../model';
import {
  CUSTOMER_CONSTRAINT_FIELDS,
  customerFormSchema,
  customerFormToWrite,
  customerToForm,
  emptyCustomerForm,
  type CustomerFormInput,
  type CustomerFormValues,
} from '../schemas';
import { TagsEditor } from './TagsEditor';

/**
 * 0126: marketing email consent for an address that unsubscribed comes back
 * only from the customer (customers_comms_guard, 42501): from their
 * unsubscribe link (/u/:token → Resubscribe) or the client portal's
 * Marketing emails toggle. Say that, and what staff can do now.
 */
const EMAIL_RESUBSCRIBE_REFUSED_MESSAGE =
  'This email address unsubscribed from your marketing emails, so your team can’t turn marketing email back on for it — the customer can turn it back on from their unsubscribe link or the client portal. Turn off Email opt-in to save your other changes.';

function isEmailResubscribeRefusal(error: AppError): boolean {
  return error.kind === 'permission' && /only the customer can opt back in/i.test(error.message);
}

export interface CustomerFormDialogProps {
  open: boolean;
  onClose: () => void;
  /** Existing customer to edit; omit to create. */
  customer?: CustomerRow;
  /** Called with the saved customer's id. */
  onSaved?: (id: string) => void;
}

/** Create / edit a customer. Mount only while open so the form resets. */
export function CustomerFormDialog({ open, onClose, customer, onSaved }: CustomerFormDialogProps) {
  const { shopId, timezone } = useShop();
  const toast = useToast();
  const create = useCreateCustomer(shopId);
  const update = useUpdateCustomer(shopId, customer?.id ?? '');
  const tags = useKnownTags(shopId, open);
  const [formError, setFormError] = useState<AppError | null>(null);

  const {
    register,
    control,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<CustomerFormInput, unknown, CustomerFormValues>({
    resolver: zodResolver(customerFormSchema),
    mode: 'onTouched',
    defaultValues: customer ? customerToForm(customer) : emptyCustomerForm(),
  });

  const onSubmit = handleSubmit(async (values) => {
    setFormError(null);
    try {
      const payload = customerFormToWrite(values);
      let id = customer?.id;
      if (customer) await update.mutateAsync(payload);
      else id = (await create.mutateAsync(payload)).id;
      toast.success(customer ? 'Customer saved' : 'Customer added');
      if (id) onSaved?.(id);
      onClose();
    } catch (error) {
      const appError = toAppError(error);
      const field = appError.constraint ? CUSTOMER_CONSTRAINT_FIELDS[appError.constraint] : null;
      if (field) setError(field, { message: appError.message }, { shouldFocus: true });
      else if (isEmailResubscribeRefusal(appError)) {
        setFormError(
          new AppError(EMAIL_RESUBSCRIBE_REFUSED_MESSAGE, { kind: 'permission', cause: error }),
        );
      } else setFormError(appError);
    }
  });

  const formId = 'customer-form';
  const busy = isSubmitting;

  return (
    <Dialog
      open={open}
      onClose={onClose}
      dismissible={!busy}
      size="lg"
      title={customer ? 'Edit customer' : 'New customer'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={busy}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={busy}>
            {customer ? 'Save changes' : 'Add customer'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-5"
      >
        {formError && (
          <p
            role="alert"
            className="bg-danger-soft text-danger-ink rounded-control px-3 py-2 text-sm"
          >
            {formError.message}
            <BillingErrorLink error={formError} />
          </p>
        )}

        <fieldset className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-semibold">Name</legend>
          <FormField label="First name" error={errors.firstName?.message}>
            <Input autoComplete="off" {...register('firstName')} />
          </FormField>
          <FormField label="Last name" error={errors.lastName?.message}>
            <Input autoComplete="off" {...register('lastName')} />
          </FormField>
          <FormField
            label="Company"
            error={errors.company?.message}
            help="Optional — for fleet or business customers."
            className="sm:col-span-2"
          >
            <Input autoComplete="off" {...register('company')} />
          </FormField>
        </fieldset>

        <fieldset className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-semibold">Contact</legend>
          <FormField label="Mobile phone" error={errors.phone?.message}>
            <Controller
              control={control}
              name="phone"
              render={({ field }) => (
                <PhoneInput
                  name={field.name}
                  value={field.value}
                  onChange={field.onChange}
                  onBlur={field.onBlur}
                  ref={field.ref}
                  autoComplete="off"
                />
              )}
            />
          </FormField>
          <FormField label="Email" error={errors.email?.message}>
            <Input type="email" autoComplete="off" inputMode="email" {...register('email')} />
          </FormField>
          <Controller
            control={control}
            name="smsOptIn"
            render={({ field }) => (
              <Switch
                checked={field.value}
                onCheckedChange={field.onChange}
                label="Text message opt-in"
                description={
                  customer?.sms_opted_out_at
                    ? `Opted out by text on ${formatDate(customer.sms_opted_out_at, timezone)} — only the customer can opt back in by replying START.`
                    : 'Customer agreed to receive texts.'
                }
              />
            )}
          />
          <Controller
            control={control}
            name="emailOptIn"
            render={({ field }) => (
              <Switch
                checked={field.value}
                onCheckedChange={field.onChange}
                label="Email opt-in"
                description={
                  customer?.email_opted_out_at
                    ? `Opted out of all email on ${formatDate(customer.email_opted_out_at, timezone)} — nothing can be emailed to this address, including invoices, receipts and reminders. Your team can’t undo this — the customer can turn it back on from their unsubscribe link or the client portal.`
                    : 'Customer agreed to receive marketing emails (campaigns and follow-ups). Appointment, quote and invoice emails don’t depend on this.'
                }
              />
            )}
          />
        </fieldset>

        <fieldset className="grid grid-cols-1 gap-4 sm:grid-cols-6">
          <legend className="text-ink mb-2 text-sm font-semibold">Address</legend>
          <FormField
            label="Street address"
            error={errors.addressLine1?.message}
            className="sm:col-span-6"
          >
            <Input autoComplete="off" {...register('addressLine1')} />
          </FormField>
          <FormField
            label="Apt, suite, etc."
            error={errors.addressLine2?.message}
            className="sm:col-span-6"
          >
            <Input autoComplete="off" {...register('addressLine2')} />
          </FormField>
          <FormField label="City" error={errors.city?.message} className="sm:col-span-3">
            <Input autoComplete="off" {...register('city')} />
          </FormField>
          <FormField
            label="State / region"
            error={errors.region?.message}
            className="sm:col-span-3"
          >
            <Input autoComplete="off" {...register('region')} />
          </FormField>
          <FormField
            label="ZIP / postal code"
            error={errors.postalCode?.message}
            className="sm:col-span-3"
          >
            <Input autoComplete="off" {...register('postalCode')} />
          </FormField>
          <FormField
            label="Country"
            error={errors.country?.message}
            help="2-letter code, e.g. US"
            className="sm:col-span-3"
          >
            <Input autoComplete="off" maxLength={2} {...register('country')} />
          </FormField>
        </fieldset>

        <fieldset className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <legend className="text-ink mb-2 text-sm font-semibold">Details</legend>
          <FormField label="Lifecycle" error={errors.lifecycle?.message}>
            <Select
              {...register('lifecycle')}
              options={LIFECYCLES.map((v) => ({ value: v, label: LIFECYCLE_LABELS[v] }))}
            />
          </FormField>
          <FormField label="Source" error={errors.source?.message}>
            <Select
              {...register('source')}
              options={SOURCES.map((v) => ({ value: v, label: SOURCE_LABELS[v] }))}
            />
          </FormField>
          <FormField
            label="Tags"
            error={errors.tags?.message ?? errors.tags?.root?.message}
            help="Press Enter or comma to add. Use tags to filter and target campaigns."
            className="sm:col-span-2"
          >
            <Controller
              control={control}
              name="tags"
              render={({ field }) => (
                <TagsEditor
                  value={field.value}
                  onChange={field.onChange}
                  suggestions={tags.data ?? []}
                />
              )}
            />
          </FormField>
          <FormField label="Notes" error={errors.notes?.message} className="sm:col-span-2">
            <Textarea rows={4} {...register('notes')} />
          </FormField>
        </fieldset>
      </form>
    </Dialog>
  );
}
