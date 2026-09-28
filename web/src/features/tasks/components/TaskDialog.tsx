import { useId, useState } from 'react';
import {
  Button,
  Combobox,
  DateInput,
  Dialog,
  FormField,
  Input,
  Select,
  Textarea,
  TimeInput,
  useToast,
} from '@/components/ui';
import { useDebouncedValue } from '@/lib/useDebouncedValue';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useLinkSearch, useSaveTask, useTaskMembers, type PickerOption } from '../api';
import {
  customerLabel,
  draftFromTask,
  NOTES_MAX,
  taskWrite,
  TITLE_MAX,
  validateTask,
  type TaskDraft,
  type TaskErrors,
  type TaskRow,
} from '../model';

/**
 * Create / edit a task. Managers assign anyone and link any customer or job;
 * other members create tasks for themselves (or nobody), may link a job they
 * work on a new task, and afterwards change only the title, notes and due time.
 */
export function TaskDialog({ task, onClose }: { task: TaskRow | null; onClose: () => void }) {
  const toast = useToast();
  const formId = useId();
  const { timezone, memberId } = useShop();
  const { user } = useAuth();
  const manager = useCan('tasks.manage');
  const members = useTaskMembers();
  const save = useSaveTask();
  const [draft, setDraft] = useState<TaskDraft>(() => draftFromTask(task, timezone, memberId));
  const [errors, setErrors] = useState<TaskErrors>({});
  const [customerQuery, setCustomerQuery] = useState('');
  const [jobQuery, setJobQuery] = useState('');
  const customers = useLinkSearch('customer', useDebouncedValue(customerQuery, 250));
  const jobs = useLinkSearch('job', useDebouncedValue(jobQuery, 250));
  const isNew = task === null;
  const canLink = manager || isNew;
  const canAssign = manager;

  const [customerPick, setCustomerPick] = useState<PickerOption | null>(() =>
    task?.customer_id
      ? { id: task.customer_id, label: customerLabel(task.customer) ?? 'Linked customer' }
      : null,
  );
  const [jobPick, setJobPick] = useState<PickerOption | null>(() =>
    task?.job_id
      ? { id: task.job_id, label: task.job ? `Job #${task.job.number}` : 'Linked job' }
      : null,
  );

  const set = (patch: Partial<TaskDraft>) => setDraft((prev) => ({ ...prev, ...patch }));
  const activeMembers = (members.data ?? []).filter(
    (m) => m.active || m.member_id === task?.assignee_member_id,
  );

  const submit = async () => {
    const found = validateTask(draft);
    setErrors(found);
    if (Object.keys(found).length > 0) return;
    try {
      await save.mutateAsync({
        ...(task ? { id: task.id } : {}),
        values: taskWrite(draft, timezone, { manager, isNew }),
      });
      toast.success(task ? 'Task saved' : 'Task added');
      onClose();
    } catch (error) {
      toast.error(error);
    }
  };

  // Technicians: their own tasks only (RLS), never another member's.
  const assigneeOptions = canAssign
    ? [
        { value: '', label: 'Nobody' },
        ...activeMembers.map((m) => ({
          value: m.member_id,
          label: m.member_id === memberId ? `${m.display_name} (me)` : m.display_name,
        })),
      ]
    : [
        { value: memberId, label: 'Me' },
        { value: '', label: 'Nobody' },
      ];

  return (
    <Dialog
      open
      onClose={onClose}
      dismissible={!save.isPending}
      title={task ? 'Edit task' : 'New task'}
      size="lg"
      footer={
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button variant="secondary" onClick={onClose} disabled={save.isPending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} loading={save.isPending}>
            {task ? 'Save task' : 'Add task'}
          </Button>
        </div>
      }
    >
      <form
        id={formId}
        noValidate
        className="flex flex-col gap-4"
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <FormField label="Title" required error={errors.title}>
          <Input
            value={draft.title}
            maxLength={TITLE_MAX}
            onChange={(e) => set({ title: e.target.value })}
            autoComplete="off"
          />
        </FormField>
        <FormField label="Notes" error={errors.notes}>
          <Textarea
            rows={3}
            value={draft.notes}
            maxLength={NOTES_MAX}
            onChange={(e) => set({ notes: e.target.value })}
          />
        </FormField>
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            label="Due date"
            error={errors.due}
            help="The assignee gets a reminder when it’s due (9:00 AM if no time is set)."
          >
            <DateInput value={draft.dueDate} onChange={(e) => set({ dueDate: e.target.value })} />
          </FormField>
          <FormField label="Due time">
            <TimeInput value={draft.dueTime} onChange={(e) => set({ dueTime: e.target.value })} />
          </FormField>
        </div>
        {(canAssign || isNew) && (
          <FormField
            label="Assigned to"
            help={
              canAssign
                ? 'They get a notification (and a push on the iPhone app).'
                : 'Only managers can assign tasks to other people.'
            }
          >
            <Select
              value={draft.assigneeId}
              onChange={(e) => set({ assigneeId: e.target.value })}
              options={assigneeOptions}
              disabled={members.isPending && canAssign}
            />
          </FormField>
        )}
        {canLink && (
          <div className="grid gap-4 sm:grid-cols-2">
            {manager && (
              <FormField label="Customer">
                <Combobox<PickerOption>
                  value={customerPick}
                  onChange={(option) => {
                    setCustomerPick(option);
                    set({ customerId: option?.id ?? null });
                  }}
                  options={customers.data ?? []}
                  onQueryChange={setCustomerQuery}
                  getOptionValue={(o) => o.id}
                  getOptionLabel={(o) => o.label}
                  loading={customers.isFetching}
                  placeholder="Search customers…"
                  emptyText={customerQuery.trim() ? 'No matching customers' : 'Type to search'}
                  clearable
                />
              </FormField>
            )}
            <FormField
              label="Job"
              help={manager ? undefined : 'Only jobs you’re assigned to can be linked.'}
            >
              <Combobox<PickerOption>
                value={jobPick}
                onChange={(option) => {
                  setJobPick(option);
                  set({ jobId: option?.id ?? null });
                }}
                options={jobs.data ?? []}
                onQueryChange={setJobQuery}
                getOptionValue={(o) => o.id}
                getOptionLabel={(o) => o.label}
                loading={jobs.isFetching}
                placeholder="Search by job number or customer…"
                emptyText={jobQuery.trim() ? 'No matching jobs' : 'Type to search'}
                clearable
              />
            </FormField>
          </div>
        )}
        {!canLink && (task.customer_id || task.job_id) && (
          <p className="text-muted text-sm">
            Linked to{' '}
            {[
              task.job ? `job #${task.job.number}` : task.job_id ? 'a job' : null,
              task.customer ? customerLabel(task.customer) : null,
            ]
              .filter(Boolean)
              .join(' and ')}
            . Only managers can change links.
          </p>
        )}
        {user && task && task.created_by !== user.id && !manager && (
          <p className="text-subtle text-xs">This task was given to you by a manager.</p>
        )}
      </form>
    </Dialog>
  );
}
