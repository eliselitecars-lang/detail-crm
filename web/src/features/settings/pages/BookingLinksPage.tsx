import { zodResolver } from '@hookform/resolvers/zod';
import { ExternalLink, Link2, Pencil, Plus, QrCode as QrIcon, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z } from 'zod';
import {
  Badge,
  Button,
  buttonClasses,
  Card,
  ConfirmDialog,
  CopyField,
  DateInput,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  QrCode,
  SectionCard,
  Switch,
  Textarea,
  useToast,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { addLocalDays, formatLocalDate, isLocalDate, shopLocalToUtcIso } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { zOptionalText, zRequiredText } from '@/lib/validation';
import { couponLastDay } from '../coupons';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import { ServiceChecklist } from '../components/ServiceChecklist';
import {
  bookingLinkUrl,
  useBookingLinks,
  useDeleteBookingLink,
  useSaveBookingLink,
  type BookingLink,
} from '../data/bookingLinks';
import { useServiceOptions, type ServiceOption } from '../data/pickers';
import { useSettingsAccess } from '../useSettingsAccess';

const MAX_SERVICES = 50;

/** Services a link may offer: active, not archived, not products (booking_links_validate). */
function offerable(services: readonly ServiceOption[]): ServiceOption[] {
  return services.filter((s) => s.active && s.kind !== 'product');
}

export default function BookingLinksPage() {
  const { readOnly, canEdit } = useSettingsAccess();
  const links = useBookingLinks();
  const services = useServiceOptions();
  const [editing, setEditing] = useState<{ link: BookingLink | null } | null>(null);

  return (
    <SettingsSectionLayout
      section="booking-links"
      readOnly={readOnly}
      actions={
        canEdit && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ link: null })}
          >
            New link
          </Button>
        )
      }
    >
      <p className="text-muted text-sm">
        Send a private link to a customer or group (a dealership, fleet or VIP) to offer only the
        services you choose — including services you don’t show on your public booking page. Prices
        come from your catalog and the usual availability rules apply.
      </p>
      <QueryView query={links} label="booking links">
        {(rows) => (
          <QueryView query={services} label="services">
            {(catalog) =>
              rows.length === 0 ? (
                <Card>
                  <EmptyState
                    icon={<Link2 aria-hidden="true" />}
                    title="No private links yet"
                    description="Create a link that offers a hand-picked set of services."
                    action={
                      canEdit && (
                        <Button variant="secondary" onClick={() => setEditing({ link: null })}>
                          New link
                        </Button>
                      )
                    }
                  />
                </Card>
              ) : (
                <ul className="flex flex-col gap-4">
                  {rows.map((link) => (
                    <li key={link.id}>
                      <LinkCard
                        link={link}
                        catalog={catalog}
                        canEdit={canEdit}
                        onEdit={() => setEditing({ link })}
                      />
                    </li>
                  ))}
                </ul>
              )
            }
          </QueryView>
        )}
      </QueryView>
      {editing && services.data && (
        <LinkDialog link={editing.link} services={services.data} onClose={() => setEditing(null)} />
      )}
    </SettingsSectionLayout>
  );
}

function linkState(
  link: BookingLink,
  now = Date.now(),
): { label: string; tone: 'success' | 'neutral' } {
  if (!link.active) return { label: 'Off', tone: 'neutral' };
  if (link.expires_at && new Date(link.expires_at).getTime() <= now) {
    return { label: 'Expired', tone: 'neutral' };
  }
  return { label: 'Live', tone: 'success' };
}

function LinkCard({
  link,
  catalog,
  canEdit,
  onEdit,
}: {
  link: BookingLink;
  catalog: readonly ServiceOption[];
  canEdit: boolean;
  onEdit: () => void;
}) {
  const { shop, timezone } = useShop();
  const toast = useToast();
  const remove = useDeleteBookingLink();
  const [showQr, setShowQr] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const url = bookingLinkUrl(shop.slug, link.token);
  const byId = new Map(catalog.map((s) => [s.id, s]));
  const names = link.service_ids.map((id) => byId.get(id)?.name).filter(Boolean);
  const unavailable = link.service_ids.filter((id) => {
    const s = byId.get(id);
    return !s || !s.active || s.kind === 'product';
  }).length;
  const state = linkState(link);
  const lastDay = couponLastDay(link.expires_at, timezone);

  return (
    <SectionCard
      title={link.name}
      description={
        <>
          {names.length > 0 ? names.join(', ') : 'No services'}
          {lastDay && ` · Works through ${formatLocalDate(lastDay)}`}
        </>
      }
      actions={
        <span className="flex items-center gap-1">
          <Badge tone={state.tone} dot>
            {state.label}
          </Badge>
          {canEdit && (
            <>
              <IconButton
                label={`Edit ${link.name}`}
                icon={<Pencil />}
                size="sm"
                onClick={onEdit}
              />
              <IconButton
                label={`Delete ${link.name}`}
                icon={<Trash2 />}
                size="sm"
                variant="danger"
                onClick={() => setConfirmDelete(true)}
              />
            </>
          )}
        </span>
      }
    >
      <div className="flex flex-col gap-3">
        <CopyField
          value={url}
          label={`Link for ${link.name}`}
          copiedMessage="Link copied"
          actions={
            <>
              <Button
                variant="ghost"
                leadingIcon={<QrIcon className="size-4" aria-hidden="true" />}
                aria-expanded={showQr}
                onClick={() => setShowQr((v) => !v)}
              >
                QR code
              </Button>
              <a
                href={url}
                target="_blank"
                rel="noreferrer"
                className={buttonClasses({ variant: 'ghost' })}
              >
                <ExternalLink className="size-4" aria-hidden="true" />
                Open
                <span className="sr-only"> {link.name} in a new tab</span>
              </a>
            </>
          }
        />
        {showQr && (
          <QrCode
            value={url}
            label={`QR code for the booking link ${link.name}`}
            fileName={`${shop.slug}-${link.name}`}
          />
        )}
        {link.note && <p className="text-muted text-sm whitespace-pre-wrap">{link.note}</p>}
        {unavailable > 0 && (
          <p
            role="note"
            className="bg-warning-soft text-warning-ink rounded-control px-3 py-2 text-xs"
          >
            {unavailable} service{unavailable === 1 ? ' is' : 's are'} no longer active and won’t be
            offered.
          </p>
        )}
      </div>
      <ConfirmDialog
        open={confirmDelete}
        onClose={() => setConfirmDelete(false)}
        tone="danger"
        title={`Delete the link ${link.name}?`}
        description="People who open it will see that the link isn’t available. Bookings already made through it are kept."
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          try {
            await remove.mutateAsync(link.id);
            toast.success('Link deleted');
            setConfirmDelete(false);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SectionCard>
  );
}

function linkSchema(timeZone: string) {
  return z
    .object({
      name: zRequiredText('Name', 120),
      serviceIds: z
        .array(z.string())
        .min(1, 'Choose at least one service.')
        .max(MAX_SERVICES, `Choose up to ${MAX_SERVICES} services.`),
      note: zOptionalText(1000),
      lastDay: z.string().refine((v) => v === '' || isLocalDate(v), 'Enter a valid date.'),
      active: z.boolean(),
    })
    .transform((v) => ({
      name: v.name,
      service_ids: v.serviceIds,
      note: v.note,
      active: v.active,
      // the link works through the whole last day, shop time
      expires_at: isLocalDate(v.lastDay)
        ? shopLocalToUtcIso(addLocalDays(v.lastDay, 1), '00:00', timeZone)
        : null,
    }));
}

function LinkDialog({
  link,
  services,
  onClose,
}: {
  link: BookingLink | null;
  services: readonly ServiceOption[];
  onClose: () => void;
}) {
  const { timezone } = useShop();
  const toast = useToast();
  const save = useSaveBookingLink();
  const schema = useMemo(() => linkSchema(timezone), [timezone]);
  const choices = useMemo(() => offerable(services), [services]);
  const allowed = new Set(choices.map((s) => s.id));
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<z.input<typeof schema>, unknown, z.output<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: link?.name ?? '',
      // services deactivated since are dropped (the server only accepts active ones)
      serviceIds: (link?.service_ids ?? []).filter((id) => allowed.has(id)),
      note: link?.note ?? '',
      lastDay: couponLastDay(link?.expires_at ?? null, timezone) ?? '',
      active: link?.active ?? true,
    },
  });

  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync({ id: link?.id, ...values });
      toast.success(link ? 'Link saved' : 'Link created');
      onClose();
    } catch (error) {
      toast.error(toAppError(error));
    }
  });

  const formId = 'booking-link-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={link ? `Edit ${link.name}` : 'New private booking link'}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {link ? 'Save' : 'Create link'}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        noValidate
        onSubmit={(e) => void onSubmit(e)}
        className="flex flex-col gap-4"
      >
        <FormField
          label="Name"
          required
          error={errors.name?.message}
          help="For you and the customer, e.g. “Fleet washes” or “Spring coating special”."
        >
          <Input maxLength={120} autoComplete="off" {...register('name')} />
        </FormField>
        <Controller
          control={control}
          name="serviceIds"
          render={({ field }) => (
            <ServiceChecklist
              legend="Services offered"
              services={choices}
              value={field.value}
              onChange={field.onChange}
              showBookable
              max={MAX_SERVICES}
              error={errors.serviceIds?.message}
            />
          )}
        />
        <FormField
          label="Message on the booking page"
          error={errors.note?.message}
          help="Optional, shown to people who open the link."
        >
          <Textarea rows={2} maxLength={1000} {...register('note')} />
        </FormField>
        <FormField
          label="Last day it works"
          error={errors.lastDay?.message}
          help="Leave empty to keep it open."
        >
          <DateInput className="max-w-48" {...register('lastDay')} />
        </FormField>
        <Controller
          control={control}
          name="active"
          render={({ field }) => (
            <Switch
              label="Link is on"
              description="Turn off to stop new bookings through it without deleting it."
              checked={field.value}
              onCheckedChange={field.onChange}
            />
          )}
        />
      </form>
    </Dialog>
  );
}
