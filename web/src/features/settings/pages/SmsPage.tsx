import { zodResolver } from '@hookform/resolvers/zod';
import { MessageSquareText } from 'lucide-react';
import { useForm } from 'react-hook-form';
import { Badge, FormField, Input, SectionCard, useToast } from '@/components/ui';
import { toAppError } from '@/lib/errors';
import { formatPhone } from '@/lib/phone';
import { useShopSettings, useUpdateShop, type ShopSettings } from '../api';
import { FormActions } from '../components/FormActions';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { smsSchema, type SmsInput, type SmsValues } from '../schemas';

/** Owner/admin only (route guard: shop.manageSmsNumber). */
export default function SmsPage() {
  const query = useShopSettings();
  return (
    <SettingsSectionLayout section="sms">
      <QueryView query={query} label="SMS settings">
        {(shop) => <SmsForm key={shop.id} shop={shop} />}
      </QueryView>
    </SettingsSectionLayout>
  );
}

function SmsForm({ shop }: { shop: ShopSettings }) {
  const toast = useToast();
  const update = useUpdateShop();
  const {
    register,
    handleSubmit,
    reset,
    setError,
    formState: { errors, isDirty },
  } = useForm<SmsInput, unknown, SmsValues>({
    resolver: zodResolver(smsSchema),
    defaultValues: { smsFromNumber: shop.sms_from_number ?? '' },
  });

  const onSubmit = handleSubmit(async ({ smsFromNumber }) => {
    try {
      const saved = await update.mutateAsync({ sms_from_number: smsFromNumber });
      reset({ smsFromNumber: saved.sms_from_number ?? '' });
      toast.success(smsFromNumber ? 'SMS number saved' : 'SMS number removed');
    } catch (error) {
      const appError = toAppError(error);
      if (appError.code === '23505') {
        setError('smsFromNumber', { message: 'Another shop already uses this number.' });
        return;
      }
      toast.error(appError);
    }
  });

  return (
    <form onSubmit={(e) => void onSubmit(e)} noValidate className="flex flex-col gap-4">
      <SectionCard
        title="Sending number"
        actions={
          shop.sms_from_number ? (
            <Badge tone="success" dot>
              Texts on
            </Badge>
          ) : (
            <Badge tone="warning" dot>
              Texts off
            </Badge>
          )
        }
      >
        <div className="flex flex-col gap-4">
          <div className="text-muted flex gap-3 text-sm">
            <MessageSquareText className="text-primary mt-0.5 size-5 shrink-0" aria-hidden="true" />
            <div className="flex flex-col gap-1.5">
              <p>
                Appointment texts, reminders and two-way messages are sent from this number, and
                customer replies to it arrive in your Messages inbox.
              </p>
              <p>
                It must be a number provisioned for your shop on the platform’s Twilio account — a
                personal or other carrier number won’t work. Ask platform support for a number if
                you don’t have one yet. Without a number, text messages are skipped and only emails
                are sent.
              </p>
            </div>
          </div>
          <FormField
            label="SMS from number"
            error={errors.smsFromNumber?.message}
            help={
              shop.sms_from_number
                ? `Currently ${formatPhone(shop.sms_from_number)}. Clear the field to stop sending texts.`
                : 'US numbers can be typed like (205) 555-0123; others need a leading + and country code.'
            }
            className="max-w-sm"
          >
            <Input
              type="tel"
              inputMode="tel"
              autoComplete="off"
              placeholder="+12055550123"
              {...register('smsFromNumber')}
            />
          </FormField>
        </div>
      </SectionCard>
      <FormActions
        dirty={isDirty}
        saving={update.isPending}
        onDiscard={() => reset({ smsFromNumber: shop.sms_from_number ?? '' })}
      />
    </form>
  );
}
