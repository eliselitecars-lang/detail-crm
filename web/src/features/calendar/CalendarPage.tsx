import type { DatesSetArg, DateSelectArg, EventClickArg, EventDropArg } from '@fullcalendar/core';
import dayGridPlugin from '@fullcalendar/daygrid';
import interactionPlugin, { type EventResizeDoneArg } from '@fullcalendar/interaction';
import listPlugin from '@fullcalendar/list';
import luxonPlugin from '@fullcalendar/luxon3';
import FullCalendar from '@fullcalendar/react';
import timeGridPlugin from '@fullcalendar/timegrid';
import { ChevronLeft, ChevronRight, Plus } from 'lucide-react';
import { useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router';
import {
  Button,
  buttonClasses,
  Card,
  Checkbox,
  ConfirmDialog,
  ErrorState,
  FormField,
  IconButton,
  PageHeader,
  Select,
  Spinner,
  statusLabel,
  useToast,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatInTz, formatTimeRange, shopLocalToUtcIso } from '@/lib/dates';
import { readLocal, writeLocal } from '@/lib/storage';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useReschedule, useResources, useTeam } from '@/features/jobs/api';
import { useBusinessHours, useCalendarEvents, type CalendarRange } from './api';
import {
  CALENDAR_VIEWS,
  isCalendarView,
  jobIdFromEventId,
  LEGEND_STATUSES,
  scrollTimeFor,
  STATUS_PALETTE,
  toBusinessHours,
  toEventInputs,
  type CalendarFilters,
  type CalendarView,
} from './model';

const VIEW_KEY = 'detailcrm:calendarView';

interface PendingMove {
  jobId: string;
  label: string;
  fromStart: string;
  fromEnd: string;
  toStart: string;
  toEnd: string;
  revert: () => void;
}

function initialView(): CalendarView {
  const saved = readLocal(VIEW_KEY);
  if (isCalendarView(saved)) return saved;
  return window.innerWidth < 640 ? 'listWeek' : 'timeGridWeek';
}

function toIso(value: string): string {
  return new Date(value).toISOString();
}

export default function CalendarPage() {
  const { shopId, timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const navigate = useNavigate();
  const toast = useToast();
  const calendarRef = useRef<FullCalendar>(null);

  const [view, setView] = useState<CalendarView>(initialView);
  const [title, setTitle] = useState('');
  const [range, setRange] = useState<CalendarRange | null>(null);
  const [filters, setFilters] = useState<CalendarFilters>({ memberId: null, resourceId: null });
  const [includeCancelled, setIncludeCancelled] = useState(false);
  const [pendingMove, setPendingMove] = useState<PendingMove | null>(null);

  useRealtime({ table: 'jobs', shopId });
  const events = useCalendarEvents(range, includeCancelled);
  const hours = useBusinessHours();
  const team = useTeam();
  const resources = useResources();
  const reschedule = useReschedule();

  const rows = useMemo(() => events.data ?? [], [events.data]);
  const rowsById = useMemo(() => new Map(rows.map((r) => [r.id, r])), [rows]);
  const eventInputs = useMemo(
    () => toEventInputs(rows, filters, canManage),
    [rows, filters, canManage],
  );
  const businessHours = useMemo(() => toBusinessHours(hours.data ?? []), [hours.data]);
  const jobCount = eventInputs.filter(
    (e) => typeof e.id === 'string' && e.id.startsWith('job:'),
  ).length;

  const api = () => calendarRef.current?.getApi();

  const changeView = (next: CalendarView) => {
    setView(next);
    writeLocal(VIEW_KEY, next);
    api()?.changeView(next);
  };

  const onDatesSet = (arg: DatesSetArg) => {
    setTitle(arg.view.title);
    const next = { from: toIso(arg.startStr), to: toIso(arg.endStr) };
    setRange((prev) => (prev && prev.from === next.from && prev.to === next.to ? prev : next));
  };

  const onEventClick = (info: EventClickArg) => {
    info.jsEvent.preventDefault();
    const jobId = jobIdFromEventId(info.event.id);
    const row = jobId ? rowsById.get(jobId) : undefined;
    if (!jobId || !row || row.is_busy_block) return;
    void navigate(`/app/jobs/${jobId}`);
  };

  const onMoved = (info: EventDropArg | EventResizeDoneArg) => {
    const jobId = jobIdFromEventId(info.event.id);
    const row = jobId ? rowsById.get(jobId) : undefined;
    const { start, end } = info.event;
    if (!jobId || !row || !start || !end) {
      info.revert();
      return;
    }
    setPendingMove({
      jobId,
      label: row.job_number !== null ? `Job #${row.job_number}` : 'this job',
      fromStart: row.starts_at,
      fromEnd: row.ends_at,
      toStart: start.toISOString(),
      toEnd: end.toISOString(),
      revert: info.revert,
    });
  };

  const onSelect = (info: DateSelectArg) => {
    api()?.unselect();
    const query = new URLSearchParams();
    if (info.allDay) {
      query.set('start', shopLocalToUtcIso(info.startStr.slice(0, 10), '09:00', timezone));
    } else {
      query.set('start', toIso(info.startStr));
      query.set('end', toIso(info.endStr));
    }
    void navigate(`/app/jobs/new?${query.toString()}`);
  };

  const confirmMove = async () => {
    if (!pendingMove) return;
    try {
      await reschedule.mutateAsync({
        jobId: pendingMove.jobId,
        start: pendingMove.toStart,
        end: pendingMove.toEnd,
      });
      toast.success(`${pendingMove.label} rescheduled`);
    } catch (error) {
      pendingMove.revert();
      toast.error(error);
    }
    setPendingMove(null);
  };

  const cancelMove = () => {
    if (reschedule.isPending) return;
    pendingMove?.revert();
    setPendingMove(null);
  };

  const describeWhen = (startIso: string, endIso: string) =>
    `${formatInTz(startIso, timezone, 'EEE, MMM d')} · ${formatTimeRange(startIso, endIso, timezone)}`;

  const activeTeam = (team.data ?? []).filter((m) => m.active);
  const activeResources = (resources.data ?? []).filter((r) => r.active && !r.archived_at);

  return (
    <>
      <PageHeader
        title="Calendar"
        description={`Times shown in the shop’s time zone (${timezone}).`}
        actions={
          canManage ? (
            <Link to="/app/jobs/new" className={buttonClasses({ variant: 'primary' })}>
              <Plus className="size-4" aria-hidden="true" />
              New job
            </Link>
          ) : undefined
        }
      />
      <Card className="overflow-hidden">
        <div className="border-line flex flex-col gap-3 border-b p-3 sm:p-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 items-center gap-1">
              <Button size="sm" variant="secondary" onClick={() => api()?.today()}>
                Today
              </Button>
              <IconButton
                label="Previous"
                icon={<ChevronLeft className="size-4" />}
                onClick={() => api()?.prev()}
              />
              <IconButton
                label="Next"
                icon={<ChevronRight className="size-4" />}
                onClick={() => api()?.next()}
              />
              <h2 className="text-ink ml-1 truncate text-base font-semibold" aria-live="polite">
                {title}
              </h2>
              {events.isFetching && <Spinner className="text-muted ml-2 size-4" />}
            </div>
            <div
              role="group"
              aria-label="Calendar view"
              className="border-line-strong rounded-control flex border p-0.5"
            >
              {CALENDAR_VIEWS.map((v) => (
                <button
                  key={v.value}
                  type="button"
                  aria-pressed={view === v.value}
                  onClick={() => changeView(v.value)}
                  className={cn(
                    'rounded-control px-2.5 py-1 text-xs font-medium',
                    view === v.value
                      ? 'bg-primary-soft text-primary-ink'
                      : 'text-muted hover:text-ink',
                  )}
                >
                  {v.label}
                </button>
              ))}
            </div>
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <FormField label="Team member">
              <Select
                selectSize="sm"
                value={filters.memberId ?? ''}
                onChange={(e) => setFilters((f) => ({ ...f, memberId: e.target.value || null }))}
                options={[
                  { value: '', label: 'Everyone' },
                  ...activeTeam.map((m) => ({ value: m.memberId, label: m.name })),
                ]}
              />
            </FormField>
            <FormField label="Bay / van">
              <Select
                selectSize="sm"
                value={filters.resourceId ?? ''}
                onChange={(e) =>
                  setFilters((f) => ({ ...f, resourceId: e.target.value || null }))
                }
                options={[
                  { value: '', label: 'All' },
                  ...activeResources.map((r) => ({ value: r.id, label: r.name })),
                ]}
              />
            </FormField>
            <div className="flex items-end pb-1.5">
              <Checkbox
                label="Show cancelled"
                checked={includeCancelled}
                onChange={(e) => setIncludeCancelled(e.target.checked)}
              />
            </div>
          </div>
        </div>

        {events.isError && (
          <ErrorState
            compact
            title="Couldn’t load the calendar"
            error={events.error}
            onRetry={() => void events.refetch()}
            retrying={events.isRefetching}
          />
        )}
        {events.isSuccess && jobCount === 0 && (
          <p role="status" className="text-muted px-4 pt-3 text-sm">
            No jobs in this range
            {filters.memberId || filters.resourceId ? ' for these filters' : ''}.
            {canManage ? ' Select a time slot to create one.' : ''}
          </p>
        )}

        <div className="p-2 sm:p-3">
          <FullCalendar
            ref={calendarRef}
            plugins={[luxonPlugin, dayGridPlugin, timeGridPlugin, listPlugin, interactionPlugin]}
            timeZone={timezone}
            initialView={view}
            headerToolbar={false}
            height={view === 'timeGridDay' || view === 'timeGridWeek' ? 680 : 'auto'}
            events={eventInputs}
            businessHours={businessHours}
            scrollTime={scrollTimeFor(hours.data ?? [])}
            nowIndicator
            dayMaxEvents
            eventInteractive
            selectable={canManage}
            selectMirror
            editable={canManage}
            eventTimeFormat={{ hour: 'numeric', minute: '2-digit', meridiem: 'short' }}
            slotLabelFormat={{ hour: 'numeric', meridiem: 'short' }}
            datesSet={onDatesSet}
            eventClick={onEventClick}
            eventDrop={onMoved}
            eventResize={onMoved}
            select={onSelect}
            noEventsText="No jobs in this range"
          />
        </div>

        <ul
          aria-label="Status colours"
          className="border-line flex flex-wrap gap-x-4 gap-y-1.5 border-t px-4 py-3"
        >
          {LEGEND_STATUSES.map((status) => (
            <li key={status} className="text-muted flex items-center gap-1.5 text-xs">
              <span
                aria-hidden="true"
                className="size-3 rounded-sm border"
                style={{
                  backgroundColor: STATUS_PALETTE[status].bg,
                  borderColor: STATUS_PALETTE[status].border,
                }}
              />
              {statusLabel('job', status)}
            </li>
          ))}
          <li className="text-muted flex items-center gap-1.5 text-xs">
            <span
              aria-hidden="true"
              className="bg-surface-3 border-line-strong size-3 rounded-sm border"
            />
            Busy / blocked
          </li>
        </ul>
      </Card>

      <ConfirmDialog
        open={pendingMove !== null}
        onClose={cancelMove}
        onConfirm={confirmMove}
        loading={reschedule.isPending}
        title={pendingMove ? `Reschedule ${pendingMove.label}?` : 'Reschedule?'}
        confirmLabel="Reschedule"
        description={
          pendingMove ? (
            <>
              <span className="block">
                New time: <strong>{describeWhen(pendingMove.toStart, pendingMove.toEnd)}</strong>
              </span>
              <span className="block">
                Was: {describeWhen(pendingMove.fromStart, pendingMove.fromEnd)}
              </span>
            </>
          ) : undefined
        }
      />
    </>
  );
}
