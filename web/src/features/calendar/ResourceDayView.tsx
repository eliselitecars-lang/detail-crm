/**
 * Bay / van view: one MIT timeGridDay calendar per resource, side by side
 * (FullCalendar's own resource views are premium). Dragging a job within a
 * column changes its time; dragging it into another column also moves it to
 * that bay / van (FullCalendar cross-calendar drag: eventLeave on the source,
 * eventReceive on the target). Every move is confirmed by the page.
 */
import type {
  BusinessHoursInput,
  DateSelectArg,
  EventClickArg,
  EventDropArg,
} from '@fullcalendar/core';
import interactionPlugin, {
  type EventLeaveArg,
  type EventReceiveArg,
  type EventResizeDoneArg,
} from '@fullcalendar/interaction';
import luxonPlugin from '@fullcalendar/luxon3';
import FullCalendar from '@fullcalendar/react';
import timeGridPlugin from '@fullcalendar/timegrid';
import { useMemo, useRef } from 'react';
import { Badge } from '@/components/ui';
import type { LocalDate } from '@/lib/dates';
import {
  columnEventInputs,
  jobIdFromEventId,
  type CalendarFilters,
  type CalendarRow,
  type ResourceColumn,
} from './model';

export interface ResourceMove {
  jobId: string;
  start: string;
  end: string;
  /** Present only when the job lands in another column. */
  toResourceId?: string | null;
  /** Puts the calendars back as they were (cancel / server error). */
  revert: () => void;
  /** Cleans up the temporary copy after the server accepted the move. */
  settle?: () => void;
}

interface Props {
  date: LocalDate;
  timezone: string;
  columns: readonly ResourceColumn[];
  rows: readonly CalendarRow[];
  filters: CalendarFilters;
  canManage: boolean;
  businessHours: BusinessHoursInput;
  slotMinTime: string;
  slotMaxTime: string;
  onOpenJob: (jobId: string) => void;
  onMove: (move: ResourceMove) => void;
  onSelect: (resourceId: string | null, start: string, end: string) => void;
}

const columnKey = (id: string | null) => id ?? 'none';

export function ResourceDayView({
  date,
  timezone,
  columns,
  rows,
  filters,
  canManage,
  businessHours,
  slotMinTime,
  slotMaxTime,
  onOpenJob,
  onMove,
  onSelect,
}: Props) {
  // eventLeave (source column) fires just before eventReceive (target column).
  const leaving = useRef<{ eventId: string; revert: () => void } | null>(null);

  const eventsByColumn = useMemo(
    () =>
      new Map(
        columns.map((c) => [
          columnKey(c.id),
          columnEventInputs(rows, filters, c.id, canManage && !c.inactive),
        ]),
      ),
    [columns, rows, filters, canManage],
  );

  const jobCount = (id: string | null) =>
    rows.filter(
      (r) =>
        r.event_type !== 'blocked_time' &&
        (r.resource_id ?? null) === id &&
        (filters.memberId === null || r.assigned_member_ids.includes(filters.memberId)),
    ).length;

  const onEventClick = (info: EventClickArg) => {
    info.jsEvent.preventDefault();
    const jobId = jobIdFromEventId(info.event.id);
    const row = jobId ? rows.find((r) => r.id === jobId) : undefined;
    if (!jobId || !row || row.is_busy_block) return;
    onOpenJob(jobId);
  };

  const onMovedWithin = (info: EventDropArg | EventResizeDoneArg) => {
    const jobId = jobIdFromEventId(info.event.id);
    const { start, end } = info.event;
    if (!jobId || !start || !end) {
      info.revert();
      return;
    }
    onMove({ jobId, start: start.toISOString(), end: end.toISOString(), revert: info.revert });
  };

  const onLeave = (info: EventLeaveArg) => {
    leaving.current = { eventId: info.event.id, revert: info.revert };
  };

  const onReceive = (column: ResourceColumn) => (info: EventReceiveArg) => {
    const left = leaving.current?.eventId === info.event.id ? leaving.current : null;
    leaving.current = null;
    const revert = () => {
      info.revert();
      left?.revert();
    };
    const jobId = jobIdFromEventId(info.event.id);
    const { start, end } = info.event;
    if (!jobId || !start || !end) {
      revert();
      return;
    }
    onMove({
      jobId,
      start: start.toISOString(),
      end: end.toISOString(),
      toResourceId: column.id,
      revert,
      settle: () => info.revert(),
    });
  };

  const select = (column: ResourceColumn) => (info: DateSelectArg) => {
    info.view.calendar.unselect();
    onSelect(column.id, info.start.toISOString(), info.end.toISOString());
  };

  return (
    // Jobs are focusable (eventInteractive), so keyboard focus scrolls the
    // columns into view.
    <div
      role="region"
      aria-label="Jobs by bay / van"
      // every column is the same day: no "today" tint on all of them
      className="overflow-x-auto [&_.fc-day-today]:bg-transparent!"
    >
      <div className="flex min-w-max gap-2">
        {columns.map((column) => {
          const count = jobCount(column.id);
          const editable = canManage && !column.inactive;
          return (
            <section
              key={columnKey(column.id)}
              aria-label={column.name}
              className="dc-resource-column flex w-64 shrink-0 flex-col gap-1 sm:w-72"
              data-resource={columnKey(column.id)}
            >
              <h3 className="bg-surface-2 text-ink rounded-control flex items-center justify-between gap-2 px-2 py-1.5 text-sm font-semibold">
                <span className="truncate">{column.name}</span>
                <span className="flex shrink-0 items-center gap-1">
                  {column.inactive && <Badge tone="neutral">Inactive</Badge>}
                  <span className="text-muted text-xs font-normal">
                    {count} job{count === 1 ? '' : 's'}
                  </span>
                </span>
              </h3>
              <FullCalendar
                key={date}
                plugins={[luxonPlugin, timeGridPlugin, interactionPlugin]}
                timeZone={timezone}
                initialView="timeGridDay"
                initialDate={date}
                headerToolbar={false}
                dayHeaders={false}
                allDaySlot={false}
                height="auto"
                slotMinTime={slotMinTime}
                slotMaxTime={slotMaxTime}
                events={eventsByColumn.get(columnKey(column.id)) ?? []}
                businessHours={businessHours}
                nowIndicator
                eventInteractive
                editable={editable}
                droppable={editable}
                selectable={editable}
                selectMirror
                eventTimeFormat={{ hour: 'numeric', minute: '2-digit', meridiem: 'short' }}
                slotLabelFormat={{ hour: 'numeric', meridiem: 'short' }}
                eventClick={onEventClick}
                eventDrop={onMovedWithin}
                eventResize={onMovedWithin}
                eventLeave={onLeave}
                eventReceive={onReceive(column)}
                select={select(column)}
              />
            </section>
          );
        })}
      </div>
    </div>
  );
}
