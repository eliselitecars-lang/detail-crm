import { zodResolver } from '@hookform/resolvers/zod';
import { CalendarOff, Pencil, Plus, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  Badge,
  Button,
  Card,
  Checkbox,
  ConfirmDialog,
  DateInput,
  Dialog,
  EmptyState,
  FormField,
  IconButton,
  Input,
  Select,
  Switch,
  Table,
  TimeInput,
  useToast,
  type Column,
} from '@/components/ui';
import { useShop } from '@/features/shop/shopContext';
import { WEEKDAY_NAMES } from '@/lib/dates';
import {
  useBlockedTimes,
  useDeleteBlockedTime,
  useSaveBlockedTime,
  useShopMembers,
  type BlockedTime,
  type MemberOption,
} from '../api';
import {
  blockToFormInput,
  describeBlock,
  describeRecurrence,
  EVENT_KIND_LABELS,
  readRecurrence,
} from '../blockedTimes';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  blockedTimeSchema,
  EVENT_KINDS,
  type BlockedTimeFormInput,
  type BlockedTimeFormValues,
} from '../schemas';
import { useSettingsAccess } from '../useSettingsAccess';

type Editing = { block: BlockedTime | null } | null;

export default function BlockedTimesPage() {
  const { canManageBlockedTimes } = useSettingsAccess();
  const { timezone } = useShop();
  const [showPast, setShowPast] = useState(false);
  const [editing, setEditing] = useState<Editing>(null);
  const [deleting, setDeleting] = useState<BlockedTime | null>(null);
  const query = useBlockedTimes(showPast);
  const members = useShopMembers();
  const remove = useDeleteBlockedTime();
  const toast = useToast();

  const memberName = useMemo(() => {
    const map = new Map((members.data ?? []).map((m) => [m.id, m.display_name]));
    return (id: string | null) => (id === null ? null : (map.get(id) ?? 'Team member'));
  }, [members.data]);

  const columns: Column<BlockedTime>[] = [
    {
      key: 'when',
      header: 'When',
      primary: true,
      cell: (b) => {
        const repeat = describeRecurrence(readRecurrence(b.recurrence));
        return (
          <span className="flex flex-col">
            <span>{describeBlock(b, timezone)}</span>
            {repeat && <span className="text-muted text-xs">{repeat}</span>}
          </span>
        );
      },
    },
    {
      key: 'kind',
      header: 'Type',
      cell: (b) => (
        <span className="inline-flex flex-wrap gap-1">
          <Badge tone={b.kind === 'closed' ? 'warning' : 'neutral'}>
            {EVENT_KIND_LABELS[b.kind]}
          </Badge>
          {b.affects_capacity && b.kind !== 'closed' && b.kind !== 'time_off' && (
            <Badge tone="info">Blocks booking</Badge>
          )}
        </span>
      ),
    },
    {
      key: 'who',
      header: 'Applies to',
      cell: (b) =>
        b.member_id === null ? (
          <Badge tone="warning">Whole shop</Badge>
        ) : (
          <span>{memberName(b.member_id)}</span>
        ),
    },
    {
      key: 'reason',
      header: 'Title / reason',
      cell: (b) => b.title ?? b.reason ?? <span className="text-muted">—</span>,
    },
    ...(canManageBlockedTimes
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (b: BlockedTime) => (
              <div className="flex justify-end gap-1">
                <IconButton
                  label={`Edit blocked time ${describeBlock(b, timezone)}`}
                  icon={<Pencil />}
                  size="sm"
                  onClick={() => setEditing({ block: b })}
                />
                <IconButton
                  label={`Delete blocked time ${describeBlock(b, timezone)}`}
                  icon={<Trash2 />}
                  size="sm"
                  variant="danger"
                  onClick={() => setDeleting(b)}
                />
              </div>
            ),
          },
        ]
      : []),
  ];

  return (
    <SettingsSectionLayout
      section="blocked-times"
      actions={
        canManageBlockedTimes && (
          <Button
            leadingIcon={<Plus className="size-4" aria-hidden="true" />}
            onClick={() => setEditing({ block: null })}
          >
            Block time
          </Button>
        )
      }
    >
      <Switch
        label="Show past blocked times"
        checked={showPast}
        onCheckedChange={setShowPast}
        className="max-w-sm"
      />
      <QueryView query={query} label="blocked times">
        {(blocks) =>
          blocks.length === 0 ? (
            <Card>
              <EmptyState
                icon={<CalendarOff aria-hidden="true" />}
                title={showPast ? 'No blocked times yet' : 'No upcoming blocked times'}
                description="Block holidays, closures or someone’s time off so nothing gets booked then. Meetings and other events can be added here or on the calendar."
                action={
                  canManageBlockedTimes && (
                    <Button variant="secondary" onClick={() => setEditing({ block: null })}>
                      Block time
                    </Button>
                  )
                }
              />
            </Card>
          ) : (
            <Card className="overflow-hidden">
              <Table
                caption="Blocked times"
                columns={columns}
                rows={blocks}
                getRowId={(b) => b.id}
              />
            </Card>
          )
        }
      </QueryView>

      {editing && (
        <BlockedTimeDialog
          block={editing.block}
          members={(members.data ?? []).filter(
            (m) => m.active || m.id === editing.block?.member_id,
          )}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        title="Delete this event?"
        description={
          deleting
            ? deleting.recurrence
              ? `Every repeat of this event is deleted (${describeBlock(deleting, timezone)} onward).`
              : `${describeBlock(deleting, timezone)} will be open for booking again.`
            : undefined
        }
        confirmLabel="Delete"
        loading={remove.isPending}
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Blocked time deleted');
            setDeleting(null);
          } catch (error) {
            toast.error(error);
          }
        }}
      />
    </SettingsSectionLayout>
  );
}

function BlockedTimeDialog({
  block,
  members,
  onClose,
}: {
  block: BlockedTime | null;
  members: MemberOption[];
  onClose: () => void;
}) {
  const { timezone } = useShop();
  const toast = useToast();
  const save = useSaveBlockedTime();
  const schema = useMemo(() => blockedTimeSchema(timezone), [timezone]);
  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<BlockedTimeFormInput, unknown, BlockedTimeFormValues>({
    resolver: zodResolver(schema),
    defaultValues: blockToFormInput(block, timezone),
  });
  const allDay = useWatch({ control, name: 'allDay' });
  const kind = useWatch({ control, name: 'kind' });
  const repeat = useWatch({ control, name: 'repeat' });
  const repeatEnd = useWatch({ control, name: 'repeatEnd' });

  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync({ id: block?.id, ...values });
      toast.success(block ? 'Saved' : 'Added to the calendar');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  });

  const formId = 'blocked-time-form';
  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      size="lg"
      title={block ? 'Edit event' : 'Block time'}
      description={`Times are in the shop’s time zone (${timezone.replace(/_/g, ' ')}).`}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {block ? 'Save' : 'Block time'}
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
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField label="Type">
            <Select
              options={EVENT_KINDS.map((k) => ({ value: k, label: EVENT_KIND_LABELS[k] }))}
              {...register('kind')}
            />
          </FormField>
          {kind !== 'closed' && (
            <FormField
              label={kind === 'time_off' ? 'Who is off' : 'For'}
              required={kind === 'time_off'}
              error={errors.memberId?.message}
            >
              <Select {...register('memberId')}>
                <option value="">{kind === 'time_off' ? 'Choose…' : 'Whole shop'}</option>
                {members.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.display_name}
                    {m.active ? '' : ' (inactive)'}
                  </option>
                ))}
              </Select>
            </FormField>
          )}
        </div>
        {kind === 'closed' && (
          <p className="text-muted text-xs">
            A closure applies to the whole shop and closes online booking for that time.
          </p>
        )}
        {kind !== 'closed' && kind !== 'time_off' && (
          <FormField label="Title" error={errors.title?.message} help="Shown on the calendar.">
            <Input maxLength={120} {...register('title')} />
          </FormField>
        )}
        <Controller
          control={control}
          name="allDay"
          render={({ field }) => (
            <Switch label="All day" checked={field.value} onCheckedChange={field.onChange} />
          )}
        />
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            label={allDay ? 'First day' : 'Start date'}
            required
            error={errors.startDate?.message}
          >
            <DateInput {...register('startDate')} />
          </FormField>
          {!allDay && (
            <FormField label="Start time" required error={errors.startTime?.message}>
              <TimeInput {...register('startTime')} />
            </FormField>
          )}
          <FormField
            label={allDay ? 'Last day' : 'End date'}
            required
            error={errors.endDate?.message}
          >
            <DateInput {...register('endDate')} />
          </FormField>
          {!allDay && (
            <FormField label="End time" required error={errors.endTime?.message}>
              <TimeInput {...register('endTime')} />
            </FormField>
          )}
        </div>
        <FormField
          label={kind === 'closed' || kind === 'time_off' ? 'Reason' : 'Notes'}
          error={errors.reason?.message}
          help="Optional, e.g. Holiday or Training."
        >
          <Input maxLength={500} {...register('reason')} />
        </FormField>
        {kind !== 'closed' && kind !== 'time_off' && (
          <Controller
            control={control}
            name="affectsCapacity"
            render={({ field }) => (
              <Switch
                label="Blocks online booking"
                description="On: this time counts as busy — for the person it’s for, or one job’s worth of capacity for the whole shop."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        )}
        <fieldset className="border-line flex flex-col gap-3 border-t pt-4">
          <legend className="text-ink float-left mb-1 w-full text-sm font-semibold">Repeat</legend>
          <div className="grid gap-4 sm:grid-cols-2">
            <FormField label="Repeats">
              <Select
                options={[
                  { value: '', label: 'Doesn’t repeat' },
                  { value: 'day', label: 'Daily' },
                  { value: 'week', label: 'Weekly' },
                  { value: 'month', label: 'Monthly (same date)' },
                ]}
                {...register('repeat')}
              />
            </FormField>
            {repeat !== '' && (
              <FormField
                label={`Every how many ${repeat === 'day' ? 'days' : repeat === 'week' ? 'weeks' : 'months'}`}
                error={errors.interval?.message}
              >
                <Input inputMode="numeric" {...register('interval')} />
              </FormField>
            )}
          </div>
          {repeat === 'week' && (
            <Controller
              control={control}
              name="weekdays"
              render={({ field }) => (
                <fieldset className="flex flex-col gap-1.5">
                  <legend className="text-ink mb-1 text-sm font-medium">On</legend>
                  <div className="flex flex-wrap gap-x-4 gap-y-2">
                    {WEEKDAY_NAMES.map((name, day) => (
                      <Checkbox
                        key={name}
                        label={name.slice(0, 3)}
                        aria-label={name}
                        checked={field.value.includes(day)}
                        onChange={(e) =>
                          field.onChange(
                            e.target.checked
                              ? [...field.value, day].sort()
                              : field.value.filter((d) => d !== day),
                          )
                        }
                      />
                    ))}
                  </div>
                  {errors.weekdays?.message && (
                    <p role="alert" className="text-danger-ink text-xs font-medium">
                      {errors.weekdays.message}
                    </p>
                  )}
                </fieldset>
              )}
            />
          )}
          {repeat !== '' && (
            <div className="grid gap-4 sm:grid-cols-2">
              <FormField label="Ends">
                <Select
                  options={[
                    { value: 'never', label: 'Never' },
                    { value: 'until', label: 'On a date' },
                    { value: 'count', label: 'After a number of times' },
                  ]}
                  {...register('repeatEnd')}
                />
              </FormField>
              {repeatEnd === 'until' && (
                <FormField label="Last date" required error={errors.untilDate?.message}>
                  <DateInput {...register('untilDate')} />
                </FormField>
              )}
              {repeatEnd === 'count' && (
                <FormField label="Times" required error={errors.count?.message}>
                  <Input inputMode="numeric" {...register('count')} />
                </FormField>
              )}
            </div>
          )}
          {repeat !== '' && block?.recurrence && (
            <p className="text-muted text-xs">
              Changes apply to every occurrence. To change a single one, use the calendar.
            </p>
          )}
        </fieldset>
      </form>
    </Dialog>
  );
}
