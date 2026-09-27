import { ClipboardList, Plus } from 'lucide-react';
import { Link, useSearchParams } from 'react-router';
import {
  buttonClasses,
  Card,
  EmptyState,
  ErrorState,
  LoadingState,
  PageHeader,
  Pagination,
  StatusBadge,
  Table,
  type Column,
  type SortState,
} from '@/components/ui';
import { formatDate, formatTimeRange } from '@/lib/dates';
import { formatCents } from '@/lib/money';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { JOB_PAGE_SIZE, useJobs, useTeam, type JobListRow } from './api';
import { JobFiltersBar } from './components/JobFiltersBar';
import {
  customerName,
  DEFAULT_JOB_FILTERS,
  hasActiveFilters,
  jobFiltersToParams,
  parseJobFilters,
  servicesSummary,
  vehicleLabel,
  type JobFilters,
  type JobSortKey,
} from './model';

type ColumnKey = JobSortKey | 'customer' | 'vehicle' | 'services' | 'status' | 'team';

export default function JobsPage() {
  const { shopId, timezone, currency } = useShop();
  const canManage = useCan('jobs.manage');
  const canViewAll = useCan('jobs.view');
  const canSeeMoney = useCan('invoices.viewAssigned');
  const [params, setParams] = useSearchParams();
  const filters = parseJobFilters(params);

  const update = (next: Partial<JobFilters>) => {
    const merged: JobFilters = { ...filters, page: 1, ...next };
    setParams(jobFiltersToParams(merged), { replace: true });
  };

  useRealtime({ table: 'jobs', shopId });
  const jobs = useJobs(filters);
  const team = useTeam();
  const members = new Map((team.data ?? []).map((m) => [m.memberId, m.name]));

  const columns: Column<JobListRow, ColumnKey>[] = [
    { key: 'number', header: 'Job', primary: true, sortable: true, cell: (j) => `#${j.number}` },
    {
      key: 'when',
      header: 'When',
      sortable: true,
      cell: (j) =>
        j.scheduled_start && j.scheduled_end ? (
          <span className="whitespace-nowrap">
            <span className="block">{formatDate(j.scheduled_start, timezone)}</span>
            <span className="text-muted block text-xs">
              {formatTimeRange(j.scheduled_start, j.scheduled_end, timezone)}
            </span>
          </span>
        ) : (
          <span className="text-muted">Not scheduled</span>
        ),
    },
    { key: 'customer', header: 'Customer', cell: (j) => customerName(j.customer) },
    {
      key: 'vehicle',
      header: 'Vehicle',
      hideOnMobile: true,
      cell: (j) => (j.vehicle ? vehicleLabel(j.vehicle) : '—'),
    },
    {
      key: 'services',
      header: 'Services',
      hideOnMobile: true,
      cell: (j) => servicesSummary(j.line_items.map((l) => l.name)),
    },
    { key: 'status', header: 'Status', cell: (j) => <StatusBadge kind="job" status={j.status} /> },
  ];
  if (canSeeMoney) {
    columns.push({
      key: 'total',
      header: 'Total',
      align: 'right',
      sortable: true,
      cell: (j) => <span className="tabular-nums">{formatCents(j.total_cents, { currency })}</span>,
    });
  }
  columns.push({
    key: 'team',
    header: 'Assigned',
    hideOnMobile: true,
    cell: (j) =>
      j.assignments.length === 0 ? (
        <span className="text-muted">Unassigned</span>
      ) : (
        j.assignments.map((a) => members.get(a.member_id) ?? 'Team member').join(', ')
      ),
  });

  const sort: SortState<ColumnKey> = {
    key: filters.sort,
    direction: filters.ascending ? 'asc' : 'desc',
  };
  const filtered = hasActiveFilters(filters);

  const newJobLink = (
    <Link to="/app/jobs/new" className={buttonClasses({ variant: 'primary' })}>
      <Plus className="size-4" aria-hidden="true" />
      New job
    </Link>
  );

  return (
    <>
      <PageHeader
        title="Jobs"
        description={
          canViewAll ? 'Work orders from request to completion.' : 'Jobs assigned to you.'
        }
        actions={canManage ? newJobLink : undefined}
      />
      <Card>
        <JobFiltersBar
          filters={filters}
          onChange={update}
          onClear={() => setParams(jobFiltersToParams(DEFAULT_JOB_FILTERS), { replace: true })}
          team={canViewAll ? (team.data ?? []) : null}
        />
        {jobs.isPending ? (
          <LoadingState variant="rows" rows={6} label="Loading jobs…" />
        ) : jobs.isError ? (
          <ErrorState
            error={jobs.error}
            onRetry={() => void jobs.refetch()}
            retrying={jobs.isRefetching}
          />
        ) : jobs.data.rows.length === 0 ? (
          <EmptyState
            icon={<ClipboardList aria-hidden="true" />}
            title={filtered ? 'No jobs match these filters' : 'No jobs yet'}
            description={
              filtered
                ? 'Try other statuses, dates or search terms.'
                : canManage
                  ? 'Create a job to put work on the calendar.'
                  : 'Jobs assigned to you will show up here.'
            }
            action={!filtered && canManage ? newJobLink : undefined}
          />
        ) : (
          <>
            <Table
              caption="Jobs"
              columns={columns}
              rows={jobs.data.rows}
              getRowId={(j) => j.id}
              rowHref={(j) => `/app/jobs/${j.id}`}
              sort={sort}
              onSortChange={(next) => {
                if (next.key === 'when' || next.key === 'number' || next.key === 'total') {
                  update({ sort: next.key, ascending: next.direction === 'asc' });
                }
              }}
            />
            <Pagination
              className="border-line border-t px-4 py-3"
              page={filters.page}
              pageSize={JOB_PAGE_SIZE}
              total={jobs.data.total}
              onPageChange={(page) => update({ page })}
            />
          </>
        )}
      </Card>
    </>
  );
}
