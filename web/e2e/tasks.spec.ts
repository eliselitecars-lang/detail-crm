import { expect, test } from '@playwright/test';
import { membershipRow, OWNER, TECH } from './support/fixtures';
import { mockSupabase, type Json } from './support/mockSupabase';

/**
 * Staff tasks (/app/tasks): a manager assigns a dated task to a technician
 * and ticks one off; a technician works their own list and can only change
 * the title / notes / due time of a task someone else created.
 */

type Row = { [key: string]: Json };

const ownerMember = membershipRow(OWNER, 'owner');
const techMember = membershipRow(TECH, 'technician');

const TEAM = [
  {
    member_id: ownerMember.id,
    display_name: OWNER.fullName,
    role: 'owner',
    active: true,
    calendar_color: null,
  },
  {
    member_id: techMember.id,
    display_name: TECH.fullName,
    role: 'technician',
    active: true,
    calendar_color: null,
  },
];

function task(id: string, extra: Row = {}): Row {
  return {
    id,
    title: `Task ${id}`,
    notes: null,
    assignee_member_id: null,
    due_at: null,
    customer_id: null,
    job_id: null,
    done_at: null,
    created_by: OWNER.id,
    created_at: '2026-09-20T15:00:00Z',
    customer: null,
    job: null,
    ...extra,
  };
}

const TASK_A = '70000000-0000-4000-8000-000000000001';
const TASK_B = '70000000-0000-4000-8000-000000000002';

/** A tiny stateful tasks table honouring the done_at / id filters the page sends. */
function tasksTable(initial: Row[]) {
  const rows = [...initial];
  const inserts: Row[] = [];
  const patches: { id: string; patch: Row }[] = [];
  const handler = ({ url, method, body }: { url: URL; method: string; body: unknown }): Json => {
    const id = url.searchParams.get('id')?.replace(/^eq\./, '');
    if (method === 'POST') {
      const createdId = '70000000-0000-4000-8000-000000000099';
      const created = task(createdId, {
        ...(body as Row),
        created_by: OWNER.id,
      });
      inserts.push(body as Row);
      rows.unshift(created);
      return [{ id: createdId }];
    }
    if (method === 'PATCH' && id) {
      const patch = body as Row;
      patches.push({ id, patch });
      const index = rows.findIndex((r) => r.id === id);
      if (index >= 0) rows[index] = { ...rows[index], ...patch };
      return [{ id }];
    }
    const doneFilter = url.searchParams.get('done_at');
    if (doneFilter === 'is.null') return rows.filter((r) => r.done_at === null);
    if (doneFilter === 'not.is.null') return rows.filter((r) => r.done_at !== null);
    return rows;
  };
  return { handler, inserts, patches };
}

test.describe('tasks', () => {
  test('a manager assigns a dated task and ticks another off', async ({ page }) => {
    const tasks = tasksTable([
      task(TASK_A, { title: 'Order more ceramic coating', assignee_member_id: ownerMember.id }),
    ]);
    await mockSupabase(page, {
      user: OWNER,
      tables: { shop_members: [ownerMember], notifications: [], tasks: tasks.handler },
      rpc: { shop_team: TEAM },
    });

    await page.goto('/app/tasks');
    const mine = page.getByRole('list', { name: 'My tasks' });
    await expect(mine).toContainText('Order more ceramic coating');

    await page.getByRole('button', { name: 'New task' }).first().click();
    const dialog = page.getByRole('dialog', { name: 'New task' });
    await dialog.getByRole('textbox', { name: /^Title/ }).fill('Re-stock the van');
    await dialog.getByLabel('Due date').fill('2026-10-05');
    await dialog.getByRole('combobox', { name: 'Assigned to' }).selectOption(techMember.id);
    await dialog.getByRole('button', { name: 'Add task' }).click();
    await expect(page.getByText('Task added')).toBeVisible();

    expect(tasks.inserts[0]).toMatchObject({
      title: 'Re-stock the van',
      notes: null,
      assignee_member_id: techMember.id,
    });
    // No time chosen: 9:00 AM shop time (America/Chicago, CDT).
    expect(tasks.inserts[0]?.due_at).toMatch(/^2026-10-05T14:00:00/);

    // Assigned to someone else, so it's under "All open", not "My tasks".
    await expect(mine).not.toContainText('Re-stock the van');
    await page.getByRole('tab', { name: 'All open' }).click();
    await expect(page.getByRole('list', { name: 'Open tasks' })).toContainText(TECH.fullName);

    await page.getByRole('tab', { name: 'My tasks' }).click();
    await page.getByRole('checkbox', { name: 'Mark “Order more ceramic coating” done' }).check();
    await expect.poll(() => tasks.patches.length).toBe(1);
    expect(tasks.patches[0]?.id).toBe(TASK_A);
    expect(tasks.patches[0]?.patch.done_at).toEqual(expect.any(String));
    await expect(page.getByText('Nothing on your list')).toBeVisible();
    await page.getByRole('tab', { name: 'Done' }).click();
    await expect(page.getByRole('list', { name: 'Done tasks' })).toContainText(
      'Order more ceramic coating',
    );
  });

  test('a technician edits a task they were given without touching its assignment', async ({
    page,
  }) => {
    const tasks = tasksTable([
      task(TASK_B, {
        title: 'Photograph the swirl marks',
        assignee_member_id: techMember.id,
        created_by: OWNER.id,
      }),
    ]);
    await mockSupabase(page, {
      user: TECH,
      tables: { shop_members: [techMember], notifications: [], tasks: tasks.handler },
      rpc: { shop_team: TEAM },
    });

    await page.goto('/app/tasks');
    await expect(page.getByRole('tab', { name: 'All open' })).toHaveCount(0);
    const mine = page.getByRole('list', { name: 'My tasks' });
    await expect(mine).toContainText('Photograph the swirl marks');
    // Created by the owner: the technician can't delete it.
    await expect(
      page.getByRole('button', { name: 'Delete “Photograph the swirl marks”' }),
    ).toHaveCount(0);

    await page.getByRole('button', { name: 'Edit “Photograph the swirl marks”' }).click();
    const dialog = page.getByRole('dialog', { name: 'Edit task' });
    await expect(dialog.getByRole('combobox', { name: 'Assigned to' })).toHaveCount(0);
    await dialog.getByRole('textbox', { name: 'Notes' }).fill('Driver side door and hood');
    await dialog.getByRole('button', { name: 'Save task' }).click();
    await expect(page.getByText('Task saved')).toBeVisible();

    expect(tasks.patches[0]?.id).toBe(TASK_B);
    expect(tasks.patches[0]?.patch).toEqual({
      title: 'Photograph the swirl marks',
      notes: 'Driver side door and hood',
      due_at: null,
    });
  });
});
