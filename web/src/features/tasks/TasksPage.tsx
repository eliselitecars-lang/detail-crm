import { ClipboardList, ListTodo, Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import {
  Badge,
  Button,
  ConfirmDialog,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  PageHeader,
  SectionCard,
  Tabs,
  useToast,
  type TabItem,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatDateTime, formatRelative } from '@/lib/dates';
import { toAppError } from '@/lib/errors';
import { useRealtime } from '@/lib/useRealtime';
import { useAuth } from '@/features/auth/authContext';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { DONE_LIMIT, useDeleteTask, useTaskMembers, useTasks, useToggleTaskDone } from './api';
import { TaskDialog } from './components/TaskDialog';
import {
  customerLabel,
  dueState,
  isMine,
  sortOpenTasks,
  type TaskRow,
  type TaskView,
} from './model';

const VIEWS: readonly TaskView[] = ['mine', 'all', 'done'];

function isView(value: string | null): value is TaskView {
  return value !== null && (VIEWS as readonly string[]).includes(value);
}

export default function TasksPage() {
  const { shopId } = useShop();
  const manager = useCan('tasks.manage');
  const [params, setParams] = useSearchParams();
  const raw = params.get('view');
  const view: TaskView = isView(raw) && (raw !== 'all' || manager) ? raw : 'mine';
  const [editing, setEditing] = useState<TaskRow | 'new' | null>(null);

  useRealtime({ table: 'tasks', shopId });

  const setView = (next: TaskView) => {
    const nextParams = new URLSearchParams(params);
    if (next === 'mine') nextParams.delete('view');
    else nextParams.set('view', next);
    setParams(nextParams, { replace: true });
  };

  const tabs: TabItem<TaskView>[] = [
    {
      value: 'mine',
      label: 'My tasks',
      content: <OpenList mode="mine" onEdit={setEditing} onNew={() => setEditing('new')} />,
    },
    ...(manager
      ? [
          {
            value: 'all' as const,
            label: 'All open',
            content: <OpenList mode="all" onEdit={setEditing} onNew={() => setEditing('new')} />,
          },
        ]
      : []),
    { value: 'done', label: 'Done', content: <DoneList onEdit={setEditing} /> },
  ];

  return (
    <>
      <PageHeader
        title="Tasks"
        description={
          manager
            ? 'Internal to-dos and reminders for your team. Assigned people are notified.'
            : 'Your to-dos and reminders.'
        }
        actions={
          <Button leadingIcon={<Plus />} onClick={() => setEditing('new')}>
            New task
          </Button>
        }
      />
      <Tabs label="Task lists" value={view} onChange={setView} items={tabs} />
      {editing !== null && (
        <TaskDialog task={editing === 'new' ? null : editing} onClose={() => setEditing(null)} />
      )}
    </>
  );
}

function OpenList({
  mode,
  onEdit,
  onNew,
}: {
  mode: 'mine' | 'all';
  onEdit: (task: TaskRow) => void;
  onNew: () => void;
}) {
  const { memberId } = useShop();
  const { user } = useAuth();
  const tasks = useTasks('open');
  const rows = sortOpenTasks(
    (tasks.data ?? []).filter((t) => mode === 'all' || isMine(t, memberId, user?.id ?? '')),
  );

  if (tasks.isPending) return <LoadingState variant="rows" rows={4} label="Loading tasks…" />;
  if (tasks.isError)
    return (
      <ErrorState
        error={tasks.error}
        title="Couldn’t load tasks"
        onRetry={() => void tasks.refetch()}
        retrying={tasks.isRefetching}
      />
    );
  if (rows.length === 0)
    return (
      <SectionCard title={mode === 'mine' ? 'My tasks' : 'All open tasks'}>
        <EmptyState
          icon={<ListTodo aria-hidden="true" />}
          title={mode === 'mine' ? 'Nothing on your list' : 'No open tasks'}
          description="Add a to-do or a reminder, optionally linked to a job or customer."
          action={
            <Button size="sm" leadingIcon={<Plus />} onClick={onNew}>
              New task
            </Button>
          }
        />
      </SectionCard>
    );
  return (
    <SectionCard
      title={mode === 'mine' ? 'My tasks' : 'All open tasks'}
      description={`${rows.length} open`}
      flush
    >
      <TaskList rows={rows} onEdit={onEdit} label={mode === 'mine' ? 'My tasks' : 'Open tasks'} />
    </SectionCard>
  );
}

function DoneList({ onEdit }: { onEdit: (task: TaskRow) => void }) {
  const tasks = useTasks('done');
  if (tasks.isPending) return <LoadingState variant="rows" rows={4} label="Loading done tasks…" />;
  if (tasks.isError)
    return (
      <ErrorState
        error={tasks.error}
        title="Couldn’t load done tasks"
        onRetry={() => void tasks.refetch()}
        retrying={tasks.isRefetching}
      />
    );
  const rows = tasks.data;
  if (rows.length === 0)
    return (
      <SectionCard title="Done">
        <EmptyState
          icon={<ClipboardList aria-hidden="true" />}
          title="No finished tasks yet"
          description="Tasks you tick off show up here."
        />
      </SectionCard>
    );
  return (
    <SectionCard
      title="Done"
      description={rows.length >= DONE_LIMIT ? `The latest ${DONE_LIMIT}` : undefined}
      flush
    >
      <TaskList rows={rows} onEdit={onEdit} label="Done tasks" />
    </SectionCard>
  );
}

function TaskList({
  rows,
  onEdit,
  label,
}: {
  rows: readonly TaskRow[];
  onEdit: (task: TaskRow) => void;
  label: string;
}) {
  const { timezone } = useShop();
  const { user } = useAuth();
  const toast = useToast();
  const manager = useCan('tasks.manage');
  const canSeeCustomers = useCan('customers.viewAssigned');
  const members = useTaskMembers();
  const toggle = useToggleTaskDone();
  const remove = useDeleteTask();
  const [deleting, setDeleting] = useState<TaskRow | null>(null);
  // The tick the member just gave, shown at once: the controlled checkbox
  // would otherwise snap back until the (async) optimistic cache update lands.
  const [ticked, setTicked] = useState<ReadonlyMap<string, boolean>>(new Map());
  const nameOf = new Map((members.data ?? []).map((m) => [m.member_id, m.display_name]));
  const setTick = (id: string, value: boolean | null) =>
    setTicked((prev) => {
      const next = new Map(prev);
      if (value === null) next.delete(id);
      else next.set(id, value);
      return next;
    });

  return (
    <>
      <ul className="divide-line divide-y" aria-label={label}>
        {rows.map((task) => {
          const due = dueState(task, timezone);
          const done = ticked.get(task.id) ?? task.done_at !== null;
          const customer = customerLabel(task.customer);
          const canDelete = manager || task.created_by === user?.id;
          return (
            <li key={task.id} className="flex items-start gap-3 px-4 py-3 sm:px-5">
              <input
                type="checkbox"
                checked={done}
                aria-label={done ? `Reopen “${task.title}”` : `Mark “${task.title}” done`}
                onChange={(e) => {
                  const next = e.target.checked;
                  setTick(task.id, next);
                  toggle.mutate(
                    { id: task.id, done: next },
                    {
                      onError: (error) =>
                        toast.error('Couldn’t update the task', toAppError(error).message),
                      onSettled: () => setTick(task.id, null),
                    },
                  );
                }}
                className="border-line-strong mt-0.5 size-5 shrink-0 cursor-pointer rounded accent-[var(--dc-primary)]"
              />
              <div className="min-w-0 flex-1">
                <p
                  className={cn(
                    'text-ink text-sm font-medium break-words',
                    done && 'text-muted line-through',
                  )}
                >
                  {task.title}
                </p>
                {task.notes && (
                  <p className="text-muted mt-0.5 line-clamp-2 text-xs break-words whitespace-pre-line">
                    {task.notes}
                  </p>
                )}
                <p className="text-muted mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs">
                  {due === 'overdue' && <Badge tone="danger">Overdue</Badge>}
                  {due === 'today' && <Badge tone="warning">Due today</Badge>}
                  {task.due_at && !done && (
                    <span>
                      Due{' '}
                      <time dateTime={task.due_at}>{formatDateTime(task.due_at, timezone)}</time>
                    </span>
                  )}
                  {done && task.done_at && (
                    <span>
                      Done <time dateTime={task.done_at}>{formatRelative(task.done_at)}</time>
                    </span>
                  )}
                  {task.assignee_member_id && (
                    <span>· {nameOf.get(task.assignee_member_id) ?? 'A team member'}</span>
                  )}
                  {task.job && (
                    <Link
                      to={`/app/jobs/${task.job.id}`}
                      className="text-primary-ink font-medium hover:underline"
                    >
                      Job #{task.job.number}
                    </Link>
                  )}
                  {task.customer && customer && canSeeCustomers && (
                    <Link
                      to={`/app/customers/${task.customer.id}`}
                      className="text-primary-ink font-medium hover:underline"
                    >
                      {customer}
                    </Link>
                  )}
                </p>
              </div>
              <div className="flex shrink-0 items-center gap-0.5">
                <IconButton
                  label={`Edit “${task.title}”`}
                  icon={<Pencil className="size-4" />}
                  size="sm"
                  onClick={() => onEdit(task)}
                />
                {canDelete && (
                  <IconButton
                    label={`Delete “${task.title}”`}
                    icon={<Trash2 className="size-4" />}
                    size="sm"
                    variant="danger"
                    onClick={() => setDeleting(task)}
                  />
                )}
              </div>
            </li>
          );
        })}
      </ul>
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title="Delete this task?"
        description={deleting ? `“${deleting.title}” is removed for everyone.` : undefined}
        confirmLabel="Delete"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Task deleted');
          } catch (error) {
            toast.error(error);
          } finally {
            setDeleting(null);
          }
        }}
      />
    </>
  );
}
