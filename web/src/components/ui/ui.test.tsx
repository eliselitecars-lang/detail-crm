import { act, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Constants } from '@/lib/database.types';
import {
  Button,
  ConfirmDialog,
  Dialog,
  DropdownMenu,
  FormField,
  Input,
  MoneyInput,
  STATUS_MAP,
  StatusBadge,
  statusTone,
  Table,
  Tabs,
  ToastProvider,
  useToast,
  type SortState,
  type ToastApi,
} from './index';

describe('FormField', () => {
  it('wires label, help and error to the control', () => {
    const { rerender } = render(
      <FormField label="Customer email" help="We send receipts here.">
        <Input />
      </FormField>,
    );
    const input = screen.getByLabelText('Customer email');
    expect(input).toHaveAccessibleDescription('We send receipts here.');
    expect(input).not.toHaveAttribute('aria-invalid');

    rerender(
      <FormField
        label="Customer email"
        help="We send receipts here."
        error="Enter a valid email address."
        required
      >
        <Input />
      </FormField>,
    );
    expect(input).toHaveAttribute('aria-invalid', 'true');
    expect(input).toBeRequired();
    expect(input).toHaveAccessibleDescription('Enter a valid email address.');
  });
});

describe('Button', () => {
  it('disables and marks busy while loading', () => {
    render(<Button loading>Save</Button>);
    const button = screen.getByRole('button', { name: 'Save' });
    expect(button).toBeDisabled();
    expect(button).toHaveAttribute('aria-busy', 'true');
  });
});

describe('MoneyInput', () => {
  function Harness({ onCents }: { onCents: (c: number | null) => void }) {
    const [value, setValue] = useState<number | null>(1250);
    return (
      <FormField label="Price">
        <MoneyInput
          value={value}
          onChange={(cents) => {
            setValue(cents);
            onCents(cents);
          }}
        />
      </FormField>
    );
  }

  it('shows cents as dollars, emits integer cents and normalizes on blur', async () => {
    const onCents = vi.fn();
    const user = userEvent.setup();
    render(<Harness onCents={onCents} />);
    const input = screen.getByLabelText('Price');
    expect(input).toHaveValue('12.50');
    await user.clear(input);
    await user.type(input, '19.9');
    expect(onCents).toHaveBeenLastCalledWith(1990);
    await user.type(input, '99'); // third decimal is rejected
    expect(input).toHaveValue('19.99');
    expect(onCents).toHaveBeenLastCalledWith(1999);
    await user.clear(input);
    await user.type(input, '7.5');
    await user.tab();
    expect(input).toHaveValue('7.50');
    expect(onCents).toHaveBeenLastCalledWith(750);
  });

  it('rejects letters and negatives', async () => {
    const onCents = vi.fn();
    const user = userEvent.setup();
    render(<Harness onCents={onCents} />);
    const input = screen.getByLabelText('Price');
    await user.clear(input);
    await user.type(input, 'abc-5');
    expect(input).toHaveValue('5');
    expect(onCents).toHaveBeenLastCalledWith(500);
  });
});

describe('Dialog', () => {
  it('traps focus, closes on Escape and restores focus', async () => {
    const user = userEvent.setup();
    function Harness() {
      const [open, setOpen] = useState(false);
      return (
        <>
          <Button onClick={() => setOpen(true)}>Open</Button>
          <Dialog
            open={open}
            onClose={() => setOpen(false)}
            title="Edit job"
            footer={<Button>Save job</Button>}
          >
            <Input aria-label="Job name" />
          </Dialog>
        </>
      );
    }
    render(<Harness />);
    const opener = screen.getByRole('button', { name: 'Open' });
    await user.click(opener);
    const dialog = screen.getByRole('dialog', { name: 'Edit job' });
    expect(dialog).toHaveAttribute('aria-modal', 'true');
    expect(within(dialog).getByRole('button', { name: 'Close' })).toHaveFocus();
    await user.tab();
    expect(within(dialog).getByLabelText('Job name')).toHaveFocus();
    await user.tab();
    expect(within(dialog).getByRole('button', { name: 'Save job' })).toHaveFocus();
    await user.tab(); // wraps
    expect(within(dialog).getByRole('button', { name: 'Close' })).toHaveFocus();
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(opener).toHaveFocus();
  });

  it('ConfirmDialog focuses Cancel and uses alertdialog for danger', async () => {
    const onConfirm = vi.fn();
    const user = userEvent.setup();
    render(
      <ConfirmDialog
        open
        onClose={() => undefined}
        onConfirm={onConfirm}
        title="Void invoice?"
        tone="danger"
        confirmLabel="Void"
      />,
    );
    expect(screen.getByRole('alertdialog', { name: 'Void invoice?' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus();
    await user.click(screen.getByRole('button', { name: 'Void' }));
    expect(onConfirm).toHaveBeenCalledOnce();
  });
});

describe('Tabs', () => {
  it('supports arrow-key navigation with roving tabindex', async () => {
    const user = userEvent.setup();
    function Harness() {
      const [value, setValue] = useState<'a' | 'b' | 'c'>('a');
      return (
        <Tabs
          label="Job sections"
          value={value}
          onChange={setValue}
          items={[
            { value: 'a', label: 'Details', content: <p>Details panel</p> },
            { value: 'b', label: 'Photos', count: 3, content: <p>Photos panel</p> },
            { value: 'c', label: 'Payments', content: <p>Payments panel</p> },
          ]}
        />
      );
    }
    render(<Harness />);
    const details = screen.getByRole('tab', { name: 'Details' });
    expect(details).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('tabpanel')).toHaveTextContent('Details panel');
    await user.click(details);
    await user.keyboard('{ArrowRight}');
    expect(screen.getByRole('tab', { name: /Photos/ })).toHaveFocus();
    expect(screen.getByRole('tabpanel')).toHaveTextContent('Photos panel');
    await user.keyboard('{End}');
    expect(screen.getByRole('tab', { name: 'Payments' })).toHaveAttribute('aria-selected', 'true');
    await user.keyboard('{ArrowRight}');
    expect(screen.getByRole('tab', { name: 'Details' })).toHaveAttribute('aria-selected', 'true');
  });
});

describe('DropdownMenu', () => {
  it('opens with the keyboard, moves with arrows and returns focus on Escape', async () => {
    const user = userEvent.setup();
    const onEdit = vi.fn();
    render(
      <DropdownMenu
        items={[
          { key: 'edit', label: 'Edit', onSelect: onEdit },
          { key: 'sep', separator: true },
          { key: 'delete', label: 'Delete', tone: 'danger', onSelect: () => undefined },
        ]}
        trigger={(props) => (
          <button type="button" {...props}>
            Actions
          </button>
        )}
      />,
    );
    const trigger = screen.getByRole('button', { name: 'Actions' });
    trigger.focus();
    await user.keyboard('{ArrowDown}');
    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    await vi.waitFor(() => expect(screen.getByRole('menuitem', { name: 'Edit' })).toHaveFocus());
    await user.keyboard('{ArrowDown}');
    expect(screen.getByRole('menuitem', { name: 'Delete' })).toHaveFocus();
    await user.keyboard('{Escape}');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();

    await user.click(trigger);
    await user.click(await screen.findByRole('menuitem', { name: 'Edit' }));
    expect(onEdit).toHaveBeenCalledOnce();
  });
});

describe('StatusBadge', () => {
  it('labels known statuses and humanizes unknown ones', () => {
    render(
      <>
        <StatusBadge kind="job" status="en_route" />
        <StatusBadge kind="invoice" status="partially_paid" />
        <StatusBadge kind="job" status="waiting_parts" />
      </>,
    );
    expect(screen.getByText('On the way')).toBeInTheDocument();
    expect(screen.getByText('Partially paid')).toBeInTheDocument();
    expect(screen.getByText('Waiting parts')).toBeInTheDocument();
  });

  it('labels a cancelled message and covers every message status', () => {
    render(<StatusBadge kind="message" status="cancelled" />);
    expect(screen.getByText('Cancelled')).toBeInTheDocument();
    expect(statusTone('message', 'cancelled')).toBe('neutral');
    for (const status of Constants.public.Enums.message_status) {
      expect(Object.keys(STATUS_MAP.message)).toContain(status);
    }
  });
});

describe('Table', () => {
  it('reports sort changes and exposes aria-sort', async () => {
    const user = userEvent.setup();
    const onSortChange = vi.fn();
    const rows = [
      { id: '1', name: 'Ada', total: 1000 },
      { id: '2', name: 'Bo', total: 500 },
    ];
    function Harness({ sort }: { sort: SortState<'name' | 'total'> }) {
      return (
        <Table
          caption="Customers"
          rows={rows}
          getRowId={(r) => r.id}
          sort={sort}
          onSortChange={onSortChange}
          rowHref={(r) => `/app/customers/${r.id}`}
          columns={[
            { key: 'name', header: 'Name', cell: (r) => r.name, sortable: true, primary: true },
            {
              key: 'total',
              header: 'Total',
              cell: (r) => String(r.total),
              sortable: true,
              align: 'right',
            },
          ]}
        />
      );
    }
    const router = createMemoryRouter([
      { path: '*', element: <Harness sort={{ key: 'name', direction: 'asc' }} /> },
    ]);
    render(<RouterProvider router={router} />);
    const table = screen.getByRole('table', { name: 'Customers' });
    expect(within(table).getByRole('columnheader', { name: /Name/ })).toHaveAttribute(
      'aria-sort',
      'ascending',
    );
    await user.click(within(table).getByRole('button', { name: /Name/ }));
    expect(onSortChange).toHaveBeenCalledWith({ key: 'name', direction: 'desc' });
    await user.click(within(table).getByRole('button', { name: /Total/ }));
    expect(onSortChange).toHaveBeenLastCalledWith({ key: 'total', direction: 'asc' });
    expect(within(table).getByRole('link', { name: 'Ada' })).toHaveAttribute(
      'href',
      '/app/customers/1',
    );
  });
});

describe('Toast', () => {
  it('announces success and maps thrown errors to friendly text', async () => {
    const user = userEvent.setup();
    function Harness() {
      const toast = useToast();
      return (
        <>
          <Button onClick={() => toast.success('Invoice sent')}>ok</Button>
          <Button
            onClick={() =>
              toast.error({ code: '42501', message: 'permission denied for table invoices' })
            }
          >
            fail
          </Button>
        </>
      );
    }
    render(
      <ToastProvider>
        <Harness />
      </ToastProvider>,
    );
    await user.click(screen.getByRole('button', { name: 'ok' }));
    expect(screen.getByRole('status')).toHaveTextContent('Invoice sent');
    await user.click(screen.getByRole('button', { name: 'fail' }));
    expect(screen.getByRole('alert')).toHaveTextContent("You don't have permission to do that.");
    await user.click(screen.getAllByRole('button', { name: 'Dismiss notification' })[0]!);
    expect(screen.queryByText('Invoice sent')).not.toBeInTheDocument();
  });
});

describe('Toast timers', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  function renderToasts() {
    const api: { current: ToastApi | null } = { current: null };
    function Capture() {
      api.current = useToast();
      return null;
    }
    const view = render(
      <ToastProvider>
        <Capture />
      </ToastProvider>,
    );
    const toast = () => {
      if (!api.current) throw new Error('toast api not captured');
      return api.current;
    };
    return { ...view, toast };
  }

  it('schedules nothing after the provider unmounts with toasts pending', () => {
    vi.useFakeTimers();
    const { toast, unmount } = renderToasts();
    act(() => {
      toast().success('Saved');
      toast().error('Failed');
    });
    expect(vi.getTimerCount()).toBe(2);
    unmount();
    expect(vi.getTimerCount()).toBe(0);
  });

  it('drops the timers of toasts pushed off the stack', () => {
    vi.useFakeTimers();
    const { toast } = renderToasts();
    act(() => {
      for (let i = 1; i <= 7; i += 1) toast().info(`Toast ${i}`);
    });
    expect(screen.getAllByRole('status')).toHaveLength(5);
    expect(screen.queryByText('Toast 1')).not.toBeInTheDocument();
    expect(screen.queryByText('Toast 2')).not.toBeInTheDocument();
    expect(vi.getTimerCount()).toBe(5);
    act(() => {
      vi.advanceTimersByTime(5000);
    });
    expect(screen.queryAllByRole('status')).toHaveLength(0);
    expect(vi.getTimerCount()).toBe(0);
  });
});

describe('Toast error actions', () => {
  it('adds the registered action to recognised errors only, until it is removed', async () => {
    const api: { current: ToastApi | null } = { current: null };
    function Capture() {
      api.current = useToast();
      return null;
    }
    render(
      <ToastProvider>
        <Capture />
      </ToastProvider>,
    );
    const toast = () => {
      if (!api.current) throw new Error('toast api not captured');
      return api.current;
    };
    const onClick = vi.fn();
    const refused = { code: 'PT402', message: 'Paused.' };
    let remove: () => void = () => undefined;
    act(() => {
      remove = toast().setErrorAction((error) =>
        error === refused ? { label: 'Go somewhere', onClick } : undefined,
      );
      toast().error(refused);
      toast().error(new Error('other'));
      toast().error('A plain message');
    });
    const action = screen.getByRole('button', { name: 'Go somewhere' });
    expect(screen.getAllByRole('button', { name: 'Go somewhere' })).toHaveLength(1);
    await userEvent.click(action);
    expect(onClick).toHaveBeenCalledTimes(1);
    act(() => {
      remove();
      toast().error(refused);
    });
    expect(screen.queryByRole('button', { name: 'Go somewhere' })).not.toBeInTheDocument();
  });
});
