import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  Button,
  Dialog,
  FormField,
  Input,
  MoneyInput,
  RadioGroup,
  Switch,
  useToast,
} from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { bpsToPercentInput } from '@/lib/money';
import { ROLE_LABELS, type ShopRole } from '@/features/shop/permissions';
import { useShop } from '@/features/shop/shopContext';
import { useSaveCompensation, useUpdateMember } from '../api';
import {
  compensationFormSchema,
  memberDetailsSchema,
  ROLE_DESCRIPTIONS,
  type Compensation,
  type CompensationFormInput,
  type CompensationFormOutput,
  type MemberDetailsInput,
  type TeamMember,
} from '../model';

function FormError({ error }: { error: unknown }) {
  if (!error) return null;
  return (
    <p role="alert" className="text-danger-ink text-sm">
      {errorMessage(error)}
    </p>
  );
}

// ---------------------------------------------------------------------------

export function ChangeRoleDialog({
  member,
  roles,
  onClose,
}: {
  member: TeamMember;
  /** Roles the actor may assign (from canChangeMemberRole). */
  roles: readonly ShopRole[];
  onClose: () => void;
}) {
  const toast = useToast();
  const update = useUpdateMember();
  const [role, setRole] = useState<ShopRole>(member.role);
  const options: ShopRole[] = [member.role, ...roles.filter((r) => r !== member.role)];

  const save = async () => {
    if (role === member.role) return onClose();
    try {
      await update.mutateAsync({ memberId: member.member_id, patch: { role } });
      toast.success(`Role changed to ${ROLE_LABELS[role]}`, member.display_name);
      onClose();
    } catch {
      // shown via update.error
    }
  };

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!update.isPending}
      title={`Change role · ${member.display_name}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button
            onClick={() => void save()}
            loading={update.isPending}
            disabled={role === member.role}
          >
            Save role
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-3">
        <FormError error={update.error} />
        <RadioGroup<ShopRole>
          label="Role"
          hideLabel
          variant="cards"
          value={role}
          onChange={setRole}
          options={options.map((r) => ({
            value: r,
            label: r === member.role ? `${ROLE_LABELS[r]} (current)` : ROLE_LABELS[r],
            description: ROLE_DESCRIPTIONS[r],
          }))}
        />
      </div>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------

export function CompensationDialog({
  member,
  current,
  onClose,
}: {
  member: TeamMember;
  current: Compensation | undefined;
  onClose: () => void;
}) {
  const { currency } = useShop();
  const save = useSaveCompensation();
  const {
    control,
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<CompensationFormInput, unknown, CompensationFormOutput>({
    resolver: zodResolver(compensationFormSchema),
    defaultValues: {
      hourlyRateCents: current?.hourly_rate_cents ?? 0,
      commission: bpsToPercentInput(current?.commission_bps ?? 0),
      salesCommission: bpsToPercentInput(current?.sales_commission_bps ?? 0),
    },
  });

  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync({
        member_id: member.member_id,
        hourly_rate_cents: values.hourlyRateCents,
        commission_bps: values.commission,
        sales_commission_bps: values.salesCommission,
      });
      onClose();
    } catch {
      // shown via save.error
    }
  });

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={`Pay · ${member.display_name}`}
      description="Used for labor cost and commission in reports. Only owners and admins see pay; the team member can see their own."
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form="comp-form" variant="money" loading={save.isPending}>
            Save pay
          </Button>
        </>
      }
    >
      <form
        id="comp-form"
        noValidate
        onSubmit={(event) => void onSubmit(event)}
        className="flex flex-col gap-4"
      >
        <FormError error={save.error} />
        <FormField
          label={`Hourly rate (${currency.toUpperCase()})`}
          error={errors.hourlyRateCents?.message}
          help="0 if they aren’t paid hourly."
        >
          <Controller
            control={control}
            name="hourlyRateCents"
            render={({ field }) => (
              <MoneyInput
                value={field.value}
                onChange={(cents) => field.onChange(cents ?? 0)}
                onBlur={field.onBlur}
                name={field.name}
              />
            )}
          />
        </FormField>
        <FormField
          label="Commission (%)"
          error={errors.commission?.message}
          help="Share of completed-job revenue before tax. 0 for none."
        >
          <Input inputMode="decimal" {...register('commission')} />
        </FormField>
        <FormField
          label="Sales commission (%)"
          error={errors.salesCommission?.message}
          help="Share of the jobs they sold (the job’s “Sold by”), before tax. 0 for none."
        >
          <Input inputMode="decimal" {...register('salesCommission')} />
        </FormField>
      </form>
    </Dialog>
  );
}

// ---------------------------------------------------------------------------

export function MemberDetailsDialog({
  member,
  bookable,
  onClose,
}: {
  member: TeamMember;
  /** shop_members.bookable; undefined while unknown (the switch is hidden). */
  bookable: boolean | undefined;
  onClose: () => void;
}) {
  const toast = useToast();
  const update = useUpdateMember();
  const [takesBookings, setTakesBookings] = useState(bookable ?? true);
  const {
    register,
    handleSubmit,
    control,
    setValue,
    formState: { errors },
  } = useForm<MemberDetailsInput>({
    resolver: zodResolver(memberDetailsSchema),
    defaultValues: {
      displayName: member.display_name,
      calendarColor: member.calendar_color ?? '',
    },
  });
  const color = useWatch({ control, name: 'calendarColor' });

  const onSubmit = handleSubmit(async (values) => {
    try {
      await update.mutateAsync({
        memberId: member.member_id,
        patch: {
          display_name: values.displayName.trim(),
          calendar_color: values.calendarColor.trim() === '' ? null : values.calendarColor.trim(),
          ...(bookable !== undefined && takesBookings !== bookable
            ? { bookable: takesBookings }
            : {}),
        },
      });
      toast.success('Saved');
      onClose();
    } catch {
      // shown via update.error
    }
  });

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!update.isPending}
      title={`Edit · ${member.display_name}`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={update.isPending}>
            Cancel
          </Button>
          <Button type="submit" form="member-form" loading={update.isPending}>
            Save
          </Button>
        </>
      }
    >
      <form
        id="member-form"
        noValidate
        onSubmit={(event) => void onSubmit(event)}
        className="flex flex-col gap-4"
      >
        <FormError error={update.error} />
        <FormField label="Display name" error={errors.displayName?.message} required>
          <Input {...register('displayName')} maxLength={100} />
        </FormField>
        <FormField
          label="Calendar colour"
          error={errors.calendarColor?.message}
          help="Hex colour for their jobs on the calendar, e.g. #1F6FEB. Leave empty for automatic."
        >
          <div className="flex items-center gap-2">
            <input
              type="color"
              aria-label="Pick a colour"
              value={/^#[0-9a-fA-F]{6}$/.test(color) ? color : '#1F6FEB'}
              onChange={(e) =>
                setValue('calendarColor', e.target.value.toUpperCase(), { shouldValidate: true })
              }
              className="border-line-strong rounded-control h-9 w-12 shrink-0 cursor-pointer border bg-transparent p-1"
            />
            <Input {...register('calendarColor')} placeholder="#1F6FEB" maxLength={7} />
          </div>
        </FormField>
        {bookable !== undefined && (
          <Switch
            label="Counts toward online booking capacity"
            description="When online booking counts your team’s availability (Settings → Booking), each active member with this on can take one online booking at a time; their time off lowers it."
            checked={takesBookings}
            onCheckedChange={setTakesBookings}
          />
        )}
      </form>
    </Dialog>
  );
}
