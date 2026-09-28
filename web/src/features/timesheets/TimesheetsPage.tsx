import { AlertTriangle, Clock, Pencil, Plus, Trash2 } from 'lucide-react';
import { useMemo, useState } from 'react';
import {
  Badge,
  Button,
  ConfirmDialog,
  DateInput,
  EmptyState,
  ErrorState,
  FormField,
  IconButton,
  LoadingState,
  PageHeader,
  SectionCard,
  Select,
  Table,
  useToast,
  type Column,
} from '@/components/ui';
import {
  addLocalDays,
  formatDateTime,
  formatLocalDate,
  shopDateRangeUtc,
  shopToday,
} from '@/lib/dates';
import { useRealtime } from '@/lib/useRealtime';
import { useCan } from '@/features/shop/useCan';
import { useShop } from '@/features/shop/shopContext';
import { useDeleteEntry, useTimeEntries, useTimesheetMembers } from './api';
import { ClockCard } from './components/ClockCard';
import { EntryDialog } from './components/EntryDialog';
import { GeoLinks } from './components/GeoLinks';
import {
  entryDurationMs,
  formatDuration,
  formatHoursDecimal,
  rangeError,
  summarize,
  weekStart,
  type TimeEntry,
} from './model';
import { useNow } from './useNow';

const SOURCE_LABELS = { app: 'App', web: 'Web', manual: 'Manual' } as const;

export default function TimesheetsPage() {
  const { shopId, timezone, memberId: myMemberId, displayName } = useShop();
  const canViewAll = useCan('timeclock.viewAll');
  const canEdit = useCan('timeclock.editAll');
  const toast = useToast();
  const today = shopToday(timezone);
  const [from, setFrom] = useState(() => weekStart(today));
  const [to, setTo] = useState(() => addLocalDays(weekStart(today), 6));
  const [memberFilter, setMemberFilter] = useState('');
  const [editing, setEditing] = useState<TimeEntry | 'new' | null>(null);
  const [deleting, setDeleting] = useState<TimeEntry | null>(null);
  useRealtime({ table: 'time_entries', shopId });

  const invalidRange = rangeError(from, to);
  const bounds = invalidRange ? null : shopDateRangeUtc(from, to, timezone);
  const memberId = canViewAll ? memberFilter || null : myMemberId;
  const entries = useTimeEntries(
    { from: bounds?.from ?? '', to: bounds?.to ?? '', memberId },
    bounds !== null,
  );
  const members = useTimesheetMembers();
  const remove = useDeleteEntry();
  const hasOpen = (entries.data?.entries ?? []).some((e) => !e.clock_out);
  const now = useNow(30_000, hasOpen);

  const nameOf = useMemo(() => {
    const map = new Map((members.data ?? []).map((m) => [m.member_id, m.display_name]));
    return (id: string) => map.get(id) ?? (id === myMemberId ? displayName : 'Former member');
  }, [members.data, myMemberId, displayName]);

  const rows = entries.data?.entries ?? [];
  const totals = bounds
    ? summarize(rows, timezone, new Date(bounds.from).getTime(), new Date(bounds.to).getTime(), now)
    : [];
  totals.sort((a, b) => nameOf(a.memberId).localeCompare(nameOf(b.memberId)));
  const daily = totals
    .flatMap((t) =>
      [...t.days.entries()].map(([day, d]) => ({
        key: `${t.memberId}:${day}`,
        memberId: t.memberId,
        day,
        ...d,
      })),
    )
    .sort(
      (a, b) => b.day.localeCompare(a.day) || nameOf(a.memberId).localeCompare(nameOf(b.memberId)),
    );
  const openCount = rows.filter((e) => !e.clock_out).length;

  const setWeek = (offsetWeeks: number) => {
    const start = addLocalDays(weekStart(today), offsetWeeks * 7);
    setFrom(start);
    setTo(addLocalDays(start, 6));
  };

  const entryColumns: Column<TimeEntry>[] = [
    ...(canViewAll
      ? [
          {
            key: 'member',
            header: 'Member',
            primary: true,
            cell: (e: TimeEntry) => nameOf(e.member_id),
          },
        ]
      : []),
    {
      key: 'kind',
      header: 'Type',
      primary: !canViewAll,
      cell: (e) => (e.kind === 'shift' ? 'Shift' : e.job ? `Job #${e.job.number}` : 'Job'),
    },
    { key: 'in', header: 'Clock in', cell: (e) => formatDateTime(e.clock_in, timezone) },
    {
      key: 'out',
      header: 'Clock out',
      cell: (e) =>
        e.clock_out ? (
          formatDateTime(e.clock_out, timezone)
        ) : (
          <Badge tone="warning" dot>
            Running
          </Badge>
        ),
    },
    {
      key: 'duration',
      header: 'Duration',
      align: 'right',
      cell: (e) => (
        <span className="tabular-nums">
          {formatDuration(entryDurationMs(e, now))}
          {!e.clock_out && <span className="text-muted"> so far</span>}
        </span>
      ),
    },
    { key: 'source', header: 'Source', hideOnMobile: true, cell: (e) => SOURCE_LABELS[e.source] },
    {
      key: 'where',
      header: 'Location',
      cell: (e) => <GeoLinks entry={e} compact />,
    },
    {
      key: 'notes',
      header: 'Notes',
      hideOnMobile: true,
      cell: (e) => <span className="line-clamp-2 max-w-xs break-words">{e.notes ?? ''}</span>,
    },
    ...(canEdit
      ? [
          {
            key: 'actions',
            header: <span className="sr-only">Actions</span>,
            align: 'right' as const,
            cell: (e: TimeEntry) => (
              <span className="inline-flex gap-1">
                <IconButton
                  label={`Edit entry from ${formatDateTime(e.clock_in, timezone)}`}
                  icon={<Pencil />}
                  onClick={() => setEditing(e)}
                />
                <IconButton
                  label={`Delete entry from ${formatDateTime(e.clock_in, timezone)}`}
                  icon={<Trash2 />}
                  variant="danger"
                  onClick={() => setDeleting(e)}
                />
              </span>
            ),
          } satisfies Column<TimeEntry>,
        ]
      : []),
  ];

  let content;
  if (invalidRange) content = null;
  else if (entries.isPending)
    content = <LoadingState label="Loading time entries…" variant="rows" />;
  else if (entries.error)
    content = (
      <ErrorState
        error={entries.error}
        title="Couldn’t load time entries"
        onRetry={() => void entries.refetch()}
        retrying={entries.isRefetching}
      />
    );
  else if (rows.length === 0)
    content = (
      <EmptyState
        icon={<Clock aria-hidden="true" />}
        title="No time entries in this range"
        description={
          canEdit
            ? 'Clock in above, or add a manual entry.'
            : 'Clock in above to start tracking time.'
        }
        action={
          canEdit ? (
            <Button variant="secondary" leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              Add entry
            </Button>
          ) : undefined
        }
      />
    );
  else
    content = (
      <div className="flex flex-col gap-5">
        {openCount > 0 && (
          <p
            className="border-warning/30 bg-warning-soft text-warning-ink rounded-control flex items-start gap-2 border px-3 py-2 text-sm"
            role="status"
          >
            <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
            {openCount === 1
              ? '1 entry is still running'
              : `${openCount} entries are still running`}{' '}
            — totals count them up to now.
          </p>
        )}
        <SectionCard
          title="Totals"
          description="Job time happens during shifts, so it isn’t added to shift hours."
          flush
        >
          <Table
            caption="Totals per team member"
            getRowId={(t) => t.memberId}
            rows={totals}
            columns={[
              { key: 'member', header: 'Member', primary: true, cell: (t) => nameOf(t.memberId) },
              {
                key: 'shift',
                header: 'Shift hours',
                align: 'right',
                cell: (t) => (
                  <span className="tabular-nums" title={`${formatHoursDecimal(t.shiftMs)} h`}>
                    {formatDuration(t.shiftMs)}
                  </span>
                ),
              },
              {
                key: 'job',
                header: 'Job hours',
                align: 'right',
                cell: (t) => <span className="tabular-nums">{formatDuration(t.jobMs)}</span>,
              },
              { key: 'entries', header: 'Entries', align: 'right', cell: (t) => t.entries },
              {
                key: 'open',
                header: 'Running',
                align: 'right',
                cell: (t) => (t.open > 0 ? <Badge tone="warning">{t.open}</Badge> : '—'),
              },
            ]}
          />
        </SectionCard>
        <SectionCard
          title="By day"
          description={`Shop-local days (${timezone}); entries past midnight are split.`}
          flush
        >
          <Table
            caption="Hours per team member per day"
            getRowId={(d) => d.key}
            rows={daily}
            columns={[
              {
                key: 'day',
                header: 'Day',
                primary: true,
                cell: (d) => formatLocalDate(d.day, 'EEE, MMM d'),
              },
              ...(canViewAll
                ? [
                    {
                      key: 'member',
                      header: 'Member',
                      cell: (d: (typeof daily)[number]) => nameOf(d.memberId),
                    },
                  ]
                : []),
              {
                key: 'shift',
                header: 'Shift',
                align: 'right',
                cell: (d) => <span className="tabular-nums">{formatDuration(d.shiftMs)}</span>,
              },
              {
                key: 'job',
                header: 'Job',
                align: 'right',
                cell: (d) => <span className="tabular-nums">{formatDuration(d.jobMs)}</span>,
              },
            ]}
          />
        </SectionCard>
        <SectionCard title="Entries" flush>
          {entries.data?.truncated && (
            <p className="text-muted px-4 pt-3 text-xs sm:px-5">
              Showing the 2,000 most recent entries — narrow the range to see all.
            </p>
          )}
          <Table caption="Time entries" columns={entryColumns} rows={rows} getRowId={(e) => e.id} />
        </SectionCard>
      </div>
    );

  return (
    <>
      <PageHeader
        title="Timesheets"
        description={
          canViewAll ? 'Clock in/out and everyone’s hours.' : 'Clock in/out and your hours.'
        }
        actions={
          canEdit ? (
            <Button leadingIcon={<Plus />} onClick={() => setEditing('new')}>
              Add entry
            </Button>
          ) : undefined
        }
      />
      <div className="flex flex-col gap-5">
        <ClockCard />
        <SectionCard title={canViewAll ? 'Hours' : 'My hours'}>
          <div className="flex flex-wrap items-end gap-3">
            {canViewAll && (
              <FormField label="Team member" className="w-full sm:w-56">
                <Select
                  value={memberFilter}
                  onChange={(e) => setMemberFilter(e.target.value)}
                  disabled={members.isPending}
                  options={[
                    { value: '', label: 'Everyone' },
                    ...(members.data ?? []).map((m) => ({
                      value: m.member_id,
                      label: m.active ? m.display_name : `${m.display_name} (inactive)`,
                    })),
                  ]}
                />
              </FormField>
            )}
            <FormField label="From" className="w-[calc(50%-0.375rem)] sm:w-44">
              <DateInput value={from} onChange={(e) => setFrom(e.target.value)} />
            </FormField>
            <FormField label="To" className="w-[calc(50%-0.375rem)] sm:w-44">
              <DateInput value={to} onChange={(e) => setTo(e.target.value)} />
            </FormField>
            <div className="flex gap-2">
              <Button variant="secondary" size="sm" onClick={() => setWeek(0)}>
                This week
              </Button>
              <Button variant="secondary" size="sm" onClick={() => setWeek(-1)}>
                Last week
              </Button>
            </div>
          </div>
          {invalidRange && (
            <p role="alert" className="text-danger-ink mt-3 text-sm">
              {invalidRange}
            </p>
          )}
        </SectionCard>
        {content}
      </div>

      {editing !== null && canEdit && (
        <EntryDialog
          {...(editing === 'new' ? {} : { entry: editing })}
          members={members.data ?? []}
          {...(memberFilter ? { defaultMemberId: memberFilter } : {})}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        tone="danger"
        loading={remove.isPending}
        title="Delete this time entry?"
        description={
          deleting
            ? `${nameOf(deleting.member_id)} · ${formatDateTime(deleting.clock_in, timezone)} — this can’t be undone.`
            : undefined
        }
        confirmLabel="Delete entry"
        onConfirm={async () => {
          if (!deleting) return;
          try {
            await remove.mutateAsync(deleting.id);
            toast.success('Entry deleted');
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
