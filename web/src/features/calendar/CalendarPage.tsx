import type { DatesSetArg, DateSelectArg, EventClickArg, EventDropArg } from '@fullcalendar/core';
import dayGridPlugin from '@fullcalendar/daygrid';
import interactionPlugin, { type EventResizeDoneArg } from '@fullcalendar/interaction';
import listPlugin from '@fullcalendar/list';
import luxonPlugin from '@fullcalendar/luxon3';
import FullCalendar from '@fullcalendar/react';
import timeGridPlugin from '@fullcalendar/timegrid';
import { CalendarPlus, ChevronLeft, ChevronRight, Plus } from 'lucide-react';
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
import {
  addLocalDays,
  formatInTz,
  formatLocalDate,
  formatTimeRange,
  shopDayRangeUtc,
  shopLocalToUtcIso,
  shopToday,
  type LocalDate,
} from '@/lib/dates';
import { readLocal, writeLocal } from '@/lib/storage';
import { useRealtime } from '@/lib/useRealtime';
import { useShop } from '@/features/shop/shopContext';
import { useCan } from '@/features/shop/useCan';
import { useReschedule, useResources, useTeam } from '@/features/jobs/api';
import { useBusinessHours, useCalendarEvents, type CalendarRange } from './api';
import { DayMapView } from './DayMapView';
import { EventContent } from './EventContent';
import { EventDialog, type EventDialogTarget } from './EventDialog';
import {
  CALENDAR_VIEWS,
  eventMeta,
  hasCustomContent,
  isCalendarView,
  isGridView,
  jobIdFromEventId,
  LEGEND_STATUSES,
  matchesFilters,
  resourceColumns,
  resourceDayBounds,
  scrollTimeFor,
  STATUS_PALETTE,
  toBusinessHours,
  toEventInputs,
  UNASSIGNED_COLUMN_NAME,
  type CalendarFilters,
  type CalendarView,
} from './model';
import { ResourceDayView, type ResourceMove } from './ResourceDayView';

const VIEW_KEY = 'detailcrm:calendarView';

interface PendingMove {
  jobId: string;
  label: string;
  fromStart: string;
  fromEnd: string;
  toStart: string;
  toEnd: string;
  /** Set when the job also moves to another bay / van (resource view). */
  toResource?: { id: string | null; name: string; fromName: string };
  /** An occurrence of a repeating job: only this visit moves. */
  repeats: boolean;
  revert: () => void;
  settle?: () => void;
}

function initialView(): CalendarView {
  const saved = readLocal(VIEW_KEY);
  if (isCalendarView(saved)) return saved;
  return window.innerWidth < 640 ? 'listWeek' : 'timeGridWeek';
}

export default function CalendarPage() {
  const { shopId, timezone } = useShop();
  const canManage = useCan('jobs.manage');
  const canAdmin = useCan('settings.manage');
  const canManageEvents = useCan('blockedTimes.manage');
  const navigate = useNavigate();
  const toast = useToast();
  const calendarRef = useRef<FullCalendar>(null);

  const [view, setView] = useState<CalendarView>(initialView);
  const [title, setTitle] = useState('');
  const [range, setRange] = useState<CalendarRange | null>(null);
  // Grid views: the visible local dates (from datesSet). Resource view: the
  // shown day. Each seeds the other when the user switches between them.
  const [visible, setVisible] = useState<{ start: LocalDate; end: LocalDate } | null>(null);
  const [focusDate, setFocusDate] = useState<LocalDate>(() => shopToday(timezone));
  /** The bay / van view and the day map show one day (focusDate). */
  const resourceMode = !isGridView(view);
  const bayMode = view === 'resourceDay';
  const mapMode = view === 'dayMap';
  const [filters, setFilters] = useState<CalendarFilters>({ memberId: null, resourceId: null });
  const [includeCancelled, setIncludeCancelled] = useState(false);
  const [pendingMove, setPendingMove] = useState<PendingMove | null>(null);
  const [eventTarget, setEventTarget] = useState<EventDialogTarget | null>(null);

  useRealtime({ table: 'jobs', shopId });
  const activeRange = useMemo(
    () => (resourceMode ? shopDayRangeUtc(focusDate, timezone) : range),
    [resourceMode, focusDate, timezone, range],
  );
  const events = useCalendarEvents(activeRange, includeCancelled);
  const hours = useBusinessHours();
  const team = useTeam();
  const resources = useResources();
  const reschedule = useReschedule();

  const rows = useMemo(() => events.data?.rows ?? [], [events.data]);
  const rowsById = useMemo(() => new Map(rows.map((r) => [r.id, r])), [rows]);
  const eventInputs = useMemo(
    () => toEventInputs(rows, filters, canManage, canManageEvents),
    [rows, filters, canManage, canManageEvents],
  );
  /** The day map lists what the Team member / Bay filters leave (as the grid does). */
  const mapRows = useMemo(
    () => (mapMode ? rows.filter((r) => matchesFilters(r, filters)) : []),
    [mapMode, rows, filters],
  );
  const businessHours = useMemo(() => toBusinessHours(hours.data ?? []), [hours.data]);
  const jobCount = eventInputs.filter(
    (e) => typeof e.id === 'string' && e.id.startsWith('job:'),
  ).length;

  const api = () => calendarRef.current?.getApi();

  const changeView = (next: CalendarView) => {
    setView(next);
    writeLocal(VIEW_KEY, next);
    if (!isGridView(next)) {
      // Into the bay / van day view: today if it is on screen, else the first visible day.
      if (!resourceMode && visible) {
        const now = shopToday(timezone);
        setFocusDate(now >= visible.start && now < visible.end ? now : visible.start);
      }
      return;
    }
    // Leaving the resource view remounts the grid at focusDate (initialDate).
    if (!resourceMode) api()?.changeView(next);
  };

  /** A new event starts on the shown day, or today when it is on screen. */
  const newEventDate = (): LocalDate => {
    if (resourceMode || !visible) return focusDate;
    const now = shopToday(timezone);
    return now >= visible.start && now < visible.end ? now : visible.start;
  };

  const goToday = () => (resourceMode ? setFocusDate(shopToday(timezone)) : api()?.today());
  const step = (days: -1 | 1) =>
    resourceMode
      ? setFocusDate((d) => addLocalDays(d, days))
      : days < 0
        ? api()?.prev()
        : api()?.next();

  const onDatesSet = (arg: DatesSetArg) => {
    setTitle(arg.view.title);
    const start = formatInTz(arg.view.currentStart, timezone, 'yyyy-MM-dd');
    setVisible({ start, end: formatInTz(arg.view.currentEnd, timezone, 'yyyy-MM-dd') });
    setFocusDate(start);
    // arg.start/end are real instants (luxon3 converts from the shop zone).
    const next = { from: arg.start.toISOString(), to: arg.end.toISOString() };
    setRange((prev) => (prev && prev.from === next.from && prev.to === next.to ? prev : next));
  };

  /** A calendar event (blocked time) opens its dialog for managers. */
  const openBlock = (extendedProps: Record<string, unknown>): boolean => {
    const meta = eventMeta(extendedProps);
    if (!meta || meta.kind === 'job' || !meta.blockId || !meta.occurrenceStart) return false;
    if (canManageEvents) {
      setEventTarget({
        mode: 'edit',
        blockId: meta.blockId,
        occurrenceStart: meta.occurrenceStart,
      });
    }
    return true;
  };

  const onEventClick = (info: EventClickArg) => {
    info.jsEvent.preventDefault();
    if (openBlock(info.event.extendedProps)) return;
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
      repeats: row.series_id !== null,
      revert: info.revert,
    });
  };

  const onSelect = (info: DateSelectArg) => {
    api()?.unselect();
    const query = new URLSearchParams();
    if (info.allDay) {
      query.set('start', shopLocalToUtcIso(info.startStr.slice(0, 10), '09:00', timezone));
    } else {
      query.set('start', info.start.toISOString());
      query.set('end', info.end.toISOString());
    }
    void navigate(`/app/jobs/new?${query.toString()}`);
  };

  const resourceName = (id: string | null) =>
    id === null
      ? UNASSIGNED_COLUMN_NAME
      : ((resources.data ?? []).find((r) => r.id === id)?.name ?? 'Unavailable bay / van');

  const onResourceMove = (move: ResourceMove) => {
    const row = rowsById.get(move.jobId);
    if (!row) {
      move.revert();
      return;
    }
    const changesResource =
      move.toResourceId !== undefined && move.toResourceId !== (row.resource_id ?? null);
    setPendingMove({
      jobId: move.jobId,
      label: row.job_number !== null ? `Job #${row.job_number}` : 'this job',
      fromStart: row.starts_at,
      fromEnd: row.ends_at,
      toStart: move.start,
      toEnd: move.end,
      repeats: row.series_id !== null,
      ...(changesResource && move.toResourceId !== undefined
        ? {
            toResource: {
              id: move.toResourceId,
              name: resourceName(move.toResourceId),
              fromName: resourceName(row.resource_id),
            },
          }
        : {}),
      revert: move.revert,
      ...(move.settle ? { settle: move.settle } : {}),
    });
  };

  const onResourceSelect = (resourceId: string | null, start: string, end: string) => {
    const query = new URLSearchParams({ start, end });
    if (resourceId) query.set('resourceId', resourceId);
    void navigate(`/app/jobs/new?${query.toString()}`);
  };

  const confirmMove = async () => {
    if (!pendingMove) return;
    try {
      await reschedule.mutateAsync({
        jobId: pendingMove.jobId,
        start: pendingMove.toStart,
        end: pendingMove.toEnd,
        ...(pendingMove.toResource ? { resourceId: pendingMove.toResource.id } : {}),
      });
      // the refetched rows now hold the job; drop the drag's temporary copy
      pendingMove.settle?.();
      toast.success(
        pendingMove.toResource
          ? `${pendingMove.label} moved to ${pendingMove.toResource.name}`
          : `${pendingMove.label} rescheduled`,
      );
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
  const columns = useMemo(
    () => resourceColumns(resources.data ?? [], rows, filters.resourceId),
    [resources.data, rows, filters.resourceId],
  );
  const bounds = useMemo(
    () => resourceDayBounds(hours.data ?? [], rows, focusDate, timezone),
    [hours.data, rows, focusDate, timezone],
  );
  const heading = resourceMode ? formatLocalDate(focusDate, 'EEEE, MMMM d, yyyy') : title;

  return (
    <>
      <PageHeader
        title="Calendar"
        description={`Times shown in the shop’s time zone (${timezone}).`}
        actions={
          canManage || canManageEvents ? (
            <div className="flex flex-wrap gap-2">
              {canManageEvents && (
                <Button
                  variant="secondary"
                  leadingIcon={<CalendarPlus className="size-4" aria-hidden="true" />}
                  onClick={() =>
                    setEventTarget({
                      mode: 'new',
                      start: { date: newEventDate(), time: '09:00' },
                    })
                  }
                >
                  New event
                </Button>
              )}
              {canManage && (
                <Link to="/app/jobs/new" className={buttonClasses({ variant: 'primary' })}>
                  <Plus className="size-4" aria-hidden="true" />
                  New job
                </Link>
              )}
            </div>
          ) : undefined
        }
      />
      <Card className="overflow-hidden">
        <div className="border-line flex flex-col gap-3 border-b p-3 sm:p-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="flex min-w-0 items-center gap-1">
              <Button size="sm" variant="secondary" onClick={goToday}>
                Today
              </Button>
              <IconButton
                label={resourceMode ? 'Previous day' : 'Previous'}
                icon={<ChevronLeft className="size-4" />}
                onClick={() => step(-1)}
              />
              <IconButton
                label={resourceMode ? 'Next day' : 'Next'}
                icon={<ChevronRight className="size-4" />}
                onClick={() => step(1)}
              />
              <h2 className="text-ink ml-1 truncate text-base font-semibold" aria-live="polite">
                {heading}
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
                onChange={(e) => setFilters((f) => ({ ...f, resourceId: e.target.value || null }))}
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
        {events.data?.truncated && (
          <p role="status" className="text-warning-ink px-4 pt-3 text-sm">
            This range has more events than the calendar can show at once, so the latest ones are
            missing. Switch to the week or day view to see them all.
          </p>
        )}
        {events.isPending && activeRange !== null && (
          <p role="status" className="text-muted px-4 pt-3 text-sm">
            Loading jobs…
          </p>
        )}
        {/* the day map has its own empty state */}
        {events.isSuccess && jobCount === 0 && !mapMode && (
          <p role="status" className="text-muted px-4 pt-3 text-sm">
            No jobs in this range
            {filters.memberId || filters.resourceId ? ' for these filters' : ''}.
            {canManage ? ' Select a time slot to create one.' : ''}
          </p>
        )}

        {bayMode && resources.isError && (
          <ErrorState
            compact
            title="Couldn’t load bays and vans"
            error={resources.error}
            onRetry={() => void resources.refetch()}
            retrying={resources.isRefetching}
          />
        )}
        {bayMode && resources.isSuccess && activeResources.length === 0 && (
          <p role="status" className="text-muted px-4 pt-3 text-sm">
            No bays or vans set up yet — every job shows under “{UNASSIGNED_COLUMN_NAME}”.
            {canAdmin && (
              <>
                {' '}
                <Link to="/app/settings/resources" className="text-primary-ink underline">
                  Add bays and vans
                </Link>
              </>
            )}
          </p>
        )}

        <div className="p-2 sm:p-3" aria-busy={events.isFetching}>
          {mapMode ? (
            events.isSuccess ? (
              <DayMapView
                key={focusDate}
                date={focusDate}
                rows={mapRows}
                timezone={timezone}
                onOpenJob={(jobId) => void navigate(`/app/jobs/${jobId}`)}
              />
            ) : null
          ) : resourceMode ? (
            resources.isPending ? (
              <p role="status" className="text-muted px-2 py-6 text-sm">
                Loading bays and vans…
              </p>
            ) : (
              <ResourceDayView
                date={focusDate}
                timezone={timezone}
                columns={columns}
                rows={rows}
                filters={filters}
                canManage={canManage}
                businessHours={businessHours}
                slotMinTime={bounds.slotMinTime}
                slotMaxTime={bounds.slotMaxTime}
                onOpenJob={(jobId) => void navigate(`/app/jobs/${jobId}`)}
                onOpenEvent={openBlock}
                onMove={onResourceMove}
                onSelect={onResourceSelect}
              />
            )
          ) : (
            <FullCalendar
              ref={calendarRef}
              plugins={[luxonPlugin, dayGridPlugin, timeGridPlugin, listPlugin, interactionPlugin]}
              timeZone={timezone}
              initialView={view}
              initialDate={focusDate}
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
              eventContent={(arg) =>
                hasCustomContent(arg.event.extendedProps) ? <EventContent arg={arg} /> : true
              }
              select={onSelect}
              // The list view's own empty text: "No jobs" only once the range
              // actually loaded (the page's error / loading lines say the rest).
              noEventsText={
                events.isSuccess
                  ? 'No jobs in this range'
                  : events.isError
                    ? 'Jobs for this range couldn’t be loaded.'
                    : 'Loading jobs…'
              }
            />
          )}
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

      {eventTarget && <EventDialog target={eventTarget} onClose={() => setEventTarget(null)} />}

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
              {pendingMove.toResource && (
                <span className="block">
                  Bay / van: <strong>{pendingMove.toResource.name}</strong> (was{' '}
                  {pendingMove.toResource.fromName})
                </span>
              )}
              {pendingMove.repeats && (
                <span className="mt-2 block">
                  This is a repeating job: only this visit moves. To change the following visits,
                  open the job and edit its schedule.
                </span>
              )}
            </>
          ) : undefined
        }
      />
    </>
  );
}
