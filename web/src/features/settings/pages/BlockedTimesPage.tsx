import { zodResolver } from '@hookform/resolvers/zod';
import { CalendarOff, Pencil, Plus, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Controller, useForm, useWatch } from 'react-hook-form';
import {
  Badge,
  Button,
  Card,
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
import {
  useBlockedTimes,
  useDeleteBlockedTime,
  useSaveBlockedTime,
  useShopMembers,
  type BlockedTime,
  type MemberOption,
} from '../api';
import { blockToFormInput, describeBlock } from '../blockedTimes';
import { QueryView, SettingsSectionLayout } from '../components/SettingsSectionLayout';
import {
  blockedTimeSchema,
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
    { key: 'when', header: 'When', primary: true, cell: (b) => describeBlock(b, timezone) },
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
      header: 'Reason',
      cell: (b) => b.reason ?? <span className="text-muted">—</span>,
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
                description="Block holidays, closures or someone’s time off so nothing gets booked then."
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
        title="Delete this blocked time?"
        description={
          deleting
            ? `${describeBlock(deleting, timezone)} will be open for booking again.`
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

  const onSubmit = handleSubmit(async (values) => {
    try {
      await save.mutateAsync({ id: block?.id, ...values });
      toast.success(block ? 'Blocked time updated' : 'Time blocked');
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
      title={block ? 'Edit blocked time' : 'Block time'}
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
        <FormField label="Applies to" help="Whole shop also closes online booking for that time.">
          <Select {...register('memberId')}>
            <option value="">Whole shop</option>
            {members.map((m) => (
              <option key={m.id} value={m.id}>
                {m.display_name}
                {m.active ? '' : ' (inactive)'}
              </option>
            ))}
          </Select>
        </FormField>
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
          label="Reason"
          error={errors.reason?.message}
          help="Optional, e.g. Holiday or Training."
        >
          <Input maxLength={500} {...register('reason')} />
        </FormField>
      </form>
    </Dialog>
  );
}
