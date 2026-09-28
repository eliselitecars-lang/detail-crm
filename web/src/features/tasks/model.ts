/**
 * Staff tasks (P-32) — pure helpers (unit-tested). Rules the server enforces
 * (0081 RLS, 0084 tasks_guard): managers see and edit every task; everyone
 * else sees tasks assigned to or created by them, creates tasks for
 * themselves (or nobody) linked at most to a job they work, and can change
 * only title / notes / due time / done.
 */
import { z } from 'zod';
import { shopLocalToUtcIso, utcToShopLocal } from '@/lib/dates';

export const taskRowSchema = z.object({
  id: z.string(),
  title: z.string(),
  notes: z.string().nullable(),
  assignee_member_id: z.string().nullable(),
  due_at: z.string().nullable(),
  customer_id: z.string().nullable(),
  job_id: z.string().nullable(),
  done_at: z.string().nullable(),
  created_by: z.string().nullable(),
  created_at: z.string(),
  customer: z
    .object({
      id: z.string(),
      first_name: z.string().nullable(),
      last_name: z.string().nullable(),
      company: z.string().nullable(),
    })
    .nullable()
    .optional()
    .transform((v) => v ?? null),
  job: z
    .object({ id: z.string(), number: z.number() })
    .nullable()
    .optional()
    .transform((v) => v ?? null),
});
export type TaskRow = z.output<typeof taskRowSchema>;

export const TASK_COLUMNS =
  'id, title, notes, assignee_member_id, due_at, customer_id, job_id, done_at, created_by, created_at, customer:customers!tasks_customer_fk(id, first_name, last_name, company), job:jobs!tasks_job_fk(id, number)';

export type TaskView = 'mine' | 'all' | 'done';

export const TITLE_MAX = 200;
export const NOTES_MAX = 5000;

export function customerLabel(c: TaskRow['customer']): string | null {
  if (!c) return null;
  return [c.first_name, c.last_name].filter(Boolean).join(' ') || c.company || 'Customer';
}

export type DueState = 'overdue' | 'today' | 'later' | 'none';

/** Where an open task's due time stands (shop-local calendar days). */
export function dueState(
  task: Pick<TaskRow, 'due_at' | 'done_at'>,
  timeZone: string,
  now = new Date(),
): DueState {
  if (!task.due_at || task.done_at) return 'none';
  if (Date.parse(task.due_at) < now.getTime()) return 'overdue';
  const today = utcToShopLocal(now, timeZone).date;
  return utcToShopLocal(task.due_at, timeZone).date === today ? 'today' : 'later';
}

/** Open tasks: overdue and soonest first, undated last, then newest. */
export function sortOpenTasks(tasks: readonly TaskRow[]): TaskRow[] {
  return [...tasks].sort((a, b) => {
    if (a.due_at && b.due_at) return Date.parse(a.due_at) - Date.parse(b.due_at);
    if (a.due_at) return -1;
    if (b.due_at) return 1;
    return Date.parse(b.created_at) - Date.parse(a.created_at);
  });
}

/** "My tasks": open tasks assigned to me, and unassigned ones I created. */
export function isMine(
  task: Pick<TaskRow, 'assignee_member_id' | 'created_by'>,
  memberId: string,
  userId: string,
) {
  return (
    task.assignee_member_id === memberId ||
    (task.assignee_member_id === null && task.created_by === userId)
  );
}

export interface TaskDraft {
  title: string;
  notes: string;
  dueDate: string;
  dueTime: string;
  assigneeId: string;
  customerId: string | null;
  jobId: string | null;
}

export function draftFromTask(
  task: TaskRow | null,
  timeZone: string,
  defaultAssignee: string,
): TaskDraft {
  const due = task?.due_at ? utcToShopLocal(task.due_at, timeZone) : null;
  return {
    title: task?.title ?? '',
    notes: task?.notes ?? '',
    dueDate: due?.date ?? '',
    dueTime: due?.time ?? '',
    assigneeId: task ? (task.assignee_member_id ?? '') : defaultAssignee,
    customerId: task?.customer_id ?? null,
    jobId: task?.job_id ?? null,
  };
}

export type TaskErrors = Partial<Record<'title' | 'notes' | 'due', string>>;

export function validateTask(draft: TaskDraft): TaskErrors {
  const errors: TaskErrors = {};
  const title = draft.title.trim();
  if (!title) errors.title = 'Give the task a title.';
  else if (title.length > TITLE_MAX) errors.title = `Keep the title to ${TITLE_MAX} characters.`;
  if (draft.notes.length > NOTES_MAX) errors.notes = 'Keep the notes to 5,000 characters.';
  if (draft.dueTime && !draft.dueDate) errors.due = 'Choose a date for the due time.';
  return errors;
}

/** Due instant: the date at the given time, or at 9:00 shop time when only a date is set. */
export function dueAtFrom(
  draft: Pick<TaskDraft, 'dueDate' | 'dueTime'>,
  timeZone: string,
): string | null {
  if (!draft.dueDate) return null;
  return shopLocalToUtcIso(draft.dueDate, draft.dueTime || '09:00', timeZone);
}

export interface TaskWrite {
  title: string;
  notes: string | null;
  due_at: string | null;
  assignee_member_id?: string | null;
  customer_id?: string | null;
  job_id?: string | null;
}

/**
 * Columns to write. Non-managers may never change the assignee, customer or
 * job of an existing task (42501), so those are left out for them; on a new
 * task they may assign themselves and link a job they work.
 */
export function taskWrite(
  draft: TaskDraft,
  timeZone: string,
  { manager, isNew }: { manager: boolean; isNew: boolean },
): TaskWrite {
  const base: TaskWrite = {
    title: draft.title.trim(),
    notes: draft.notes.trim() === '' ? null : draft.notes.trim(),
    due_at: dueAtFrom(draft, timeZone),
  };
  if (manager) {
    return {
      ...base,
      assignee_member_id: draft.assigneeId || null,
      customer_id: draft.customerId,
      job_id: draft.jobId,
    };
  }
  if (isNew) return { ...base, assignee_member_id: draft.assigneeId || null, job_id: draft.jobId };
  return base;
}
