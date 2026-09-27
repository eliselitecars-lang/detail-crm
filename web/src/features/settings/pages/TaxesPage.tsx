import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm } from 'react-hook-form';
import { FormField, Input, SectionCard, Switch, Textarea, useToast } from '@/components/ui';
import { bpsToPercentInput } from '@/lib/money';
import { useShopSettings, useUpdateShop, type ShopSettings } from '../api';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { taxesSchema, type TaxesInput, type TaxesValues } from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

export default function TaxesPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const query = useShopSettings();
  return (
    <SettingsSectionLayout section="taxes" readOnly={readOnly}>
      <QueryView query={query} label="tax and document settings">
        {(shop) => <TaxesForm key={shop.id} shop={shop} canEdit={canEdit} />}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function toInput(shop: ShopSettings): TaxesInput {
  return {
    taxRate: bpsToPercentInput(shop.tax_rate_bps),
    quoteTerms: shop.quote_terms ?? '',
    invoiceTerms: shop.invoice_terms ?? '',
    invoiceDueDays: String(shop.invoice_due_days),
    techsCanCollectPayments: shop.techs_can_collect_payments,
  };
}

function TaxesForm({ shop, canEdit }: { shop: ShopSettings; canEdit: boolean }) {
  const toast = useToast();
  const update = useUpdateShop();
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors, isDirty },
  } = useForm<TaxesInput, unknown, TaxesValues>({
    resolver: zodResolver(taxesSchema),
    defaultValues: toInput(shop),
  });

  const onSubmit = handleSubmit(async (v) => {
    try {
      const saved = await update.mutateAsync({
        tax_rate_bps: v.taxRate,
        quote_terms: v.quoteTerms,
        invoice_terms: v.invoiceTerms,
        invoice_due_days: v.invoiceDueDays,
        techs_can_collect_payments: v.techsCanCollectPayments,
      });
      reset(toInput(saved));
      toast.success('Tax and document settings saved');
    } catch (error) {
      toast.error(error);
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <fieldset disabled={!canEdit} className="flex min-w-0 flex-col gap-4">
        <legend className="sr-only">Taxes and documents</legend>
        <SectionCard
          title="Sales tax"
          description="Applied to taxable services on new jobs, quotes and invoices. Existing documents keep their rate."
        >
          <FormField
            label="Tax rate"
            error={errors.taxRate?.message}
            help="Use 0 if you don’t charge sales tax. Up to two decimals, e.g. 9.25."
            className="max-w-xs"
          >
            <Input inputMode="decimal" trailing="%" {...register('taxRate')} />
          </FormField>
        </SectionCard>

        <SectionCard title="Quotes & invoices">
          <div className="grid gap-4">
            <FormField
              label="Quote terms"
              error={errors.quoteTerms?.message}
              help="Printed on every quote (warranty, what’s included, validity)."
            >
              <Textarea rows={4} {...register('quoteTerms')} />
            </FormField>
            <FormField
              label="Invoice terms"
              error={errors.invoiceTerms?.message}
              help="Printed on every invoice (payment terms, late fees, thank-you note)."
            >
              <Textarea rows={4} {...register('invoiceTerms')} />
            </FormField>
            <FormField
              label="Invoice due (days after issue)"
              error={errors.invoiceDueDays?.message}
              help="0 means due on receipt (0–365)."
              className="max-w-xs"
            >
              <Input inputMode="numeric" {...register('invoiceDueDays')} />
            </FormField>
          </div>
        </SectionCard>

        <SectionCard title="Payment collection">
          <Controller
            control={control}
            name="techsCanCollectPayments"
            render={({ field }) => (
              <Switch
                label="Technicians can collect payments"
                description="Lets technicians see the invoice for their assigned jobs and take card, cash or check payments. Refunds stay with owners and admins."
                checked={field.value}
                onCheckedChange={field.onChange}
                disabled={!canEdit}
              />
            )}
          />
        </SectionCard>
      </fieldset>
      {canEdit && (
        <FormActions
          dirty={isDirty}
          saving={update.isPending}
          onDiscard={() => reset(toInput(shop))}
        />
      )}
    </form>
  );
}
