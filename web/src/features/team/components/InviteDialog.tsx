import { zodResolver } from '@hookform/resolvers/zod';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import { Button, Dialog, FormField, Input, RadioGroup, useToast } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { zEmail } from '@/lib/validation';
import { invitableRoles, ROLE_LABELS, type ShopRole } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { useSendInvite } from '../api';
import { announceInvite } from '../inviteNotice';
import { ROLE_DESCRIPTIONS } from '../model';
import { BillingErrorLink } from '@/features/billing/BillingErrorLink';

const inviteSchema = z.object({
  email: zEmail,
  role: z.enum(['admin', 'manager', 'technician']),
});
type InviteInput = z.input<typeof inviteSchema>;
type InviteOutput = z.output<typeof inviteSchema>;

export interface InviteDialogProps {
  open: boolean;
  onClose: () => void;
}

/** Invite by email; role choices come from invitableRoles (never owner). */
export function InviteDialog({ open, onClose }: InviteDialogProps) {
  const { role } = useShop();
  const toast = useToast();
  const send = useSendInvite();
  const roles = invitableRoles(role).filter((r): r is Exclude<ShopRole, 'owner'> => r !== 'owner');
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<InviteInput, unknown, InviteOutput>({
    resolver: zodResolver(inviteSchema),
    defaultValues: { email: '', role: 'technician' },
  });

  const close = () => {
    reset();
    send.reset();
    onClose();
  };

  const onSubmit = handleSubmit(async (values) => {
    try {
      const result = await send.mutateAsync(values);
      announceInvite(toast, result, false);
      close();
    } catch {
      // shown below via send.error
    }
  });

  return (
    <Dialog
      open={open}
      onClose={close}
      dismissible={!send.isPending}
      title="Invite a team member"
      description="They get an email with a link to join this shop. Invites expire after 7 days."
      footer={
        <>
          <Button variant="secondary" onClick={close} disabled={send.isPending}>
            Cancel
          </Button>
          <Button type="submit" form="invite-form" loading={send.isPending}>
            Send invite
          </Button>
        </>
      }
    >
      <form
        id="invite-form"
        noValidate
        onSubmit={(event) => void onSubmit(event)}
        className="flex flex-col gap-4"
      >
        {send.error && (
          <p role="alert" className="text-danger-ink text-sm">
            {errorMessage(send.error)}
            <BillingErrorLink error={send.error} />
          </p>
        )}
        <FormField label="Email" error={errors.email?.message} required>
          <Input type="email" autoComplete="off" {...register('email')} />
        </FormField>
        <Controller
          control={control}
          name="role"
          render={({ field }) => (
            <RadioGroup<Exclude<ShopRole, 'owner'>>
              label="Role"
              variant="cards"
              value={field.value}
              onChange={field.onChange}
              options={roles.map((r) => ({
                value: r,
                label: ROLE_LABELS[r],
                description: ROLE_DESCRIPTIONS[r],
              }))}
              error={errors.role?.message}
            />
          )}
        />
      </form>
    </Dialog>
  );
}
