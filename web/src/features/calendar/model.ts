/**
 * Calendar mapping: calendar_events rows → FullCalendar event inputs
 * (colours from design tokens only), client-side team/resource filters and
 * business_hours → FullCalendar businessHours. Instants stay ISO strings; the
 * calendar renders them in the SHOP timezone (luxon3 plugin), never the
 * browser's.
 */
import type { BusinessHoursInput, EventInput } from '@fullcalendar/core';
import { statusLabel } from '@/components/ui';
import {
  formatInTz,
  localTimeToMinutes,
  shopDayRangeUtc,
  shopWeekday,
  type LocalDate,
} from '@/lib/dates';
import type { JobStatus } from '@/features/jobs/model';

export interface CalendarRow {
  event_type: string;
  id: string;
  job_number: number | null;
  status: JobStatus | null;
  starts_at: string;
  ends_at: string;
  is_busy_block: boolean;
  customer_id: string | null;
  customer_name: string | null;
  vehicle_id: string | null;
  vehicle_label: string | null;
  location_type: 'shop' | 'mobile' | null;
  service_address: string | null;
  resource_id: string | null;
  assigned_member_ids: string[];
  member_id: string | null;
  title: string | null;
  /** 'job' or the blocked time's calendar_event_kind (calendar_events v2). */
  event_kind: string;
  series_id: string | null;
  color: string | null;
  service_lat: number | null;
  service_lng: number | null;
}

/** blocked_times.kind (0050). */
export type EventKind = 'closed' | 'time_off' | 'meeting' | 'consultation' | 'reminder' | 'other';

export const EVENT_KINDS: readonly EventKind[] = [
  'closed',
  'time_off',
  'meeting',
  'consultation',
  'reminder',
  'other',
];

export const EVENT_KIND_LABELS: Record<EventKind, string> = {
  closed: 'Closed',
  time_off: 'Time off',
  meeting: 'Meeting',
  consultation: 'Consultation',
  reminder: 'Reminder',
  other: 'Event',
};

export function isEventKind(value: string): value is EventKind {
  return (EVENT_KINDS as readonly string[]).includes(value);
}

/** What FullCalendar keeps on each event for the page's handlers and content. */
export interface EventMeta {
  kind: 'job' | EventKind;
  seriesId: string | null;
  /** Blocked times: the block row and this occurrence's start. */
  blockId?: string;
  occurrenceStart?: string;
  /** Consultations / reminders: the customer (managers only). */
  customerName?: string | null;
  /** A closure's shading (FullCalendar background event: never clicked). */
  background?: true;
}

export interface CalendarFilters {
  memberId: string | null;
  resourceId: string | null;
}

interface Palette {
  bg: string;
  border: string;
  text: string;
}

const token = (name: string) => `var(--dc-${name})`;

export const STATUS_PALETTE: Record<JobStatus, Palette> = {
  requested: { bg: token('warning-soft'), border: token('warning'), text: token('warning-ink') },
  scheduled: { bg: token('primary-soft'), border: token('primary'), text: token('primary-ink') },
  confirmed: { bg: token('primary'), border: token('primary'), text: token('primary-fg') },
  en_route: { bg: token('primary'), border: token('primary-hover'), text: token('primary-fg') },
  in_progress: { bg: token('success-soft'), border: token('success'), text: token('success-ink') },
  completed: { bg: token('surface-2'), border: token('success'), text: token('success-ink') },
  cancelled: { bg: token('surface-2'), border: token('line-strong'), text: token('muted') },
  no_show: { bg: token('danger-soft'), border: token('danger'), text: token('danger-ink') },
};

export const BUSY_PALETTE: Palette = {
  bg: token('surface-3'),
  border: token('line-strong'),
  text: token('muted'),
};

export const LEGEND_STATUSES: readonly JobStatus[] = [
  'requested',
  'scheduled',
  'confirmed',
  'en_route',
  'in_progress',
  'completed',
  'no_show',
];

/** Does a row pass the client-side team/resource filters? */
export function matchesFilters(row: CalendarRow, filters: CalendarFilters): boolean {
  if (row.event_type === 'blocked_time') {
    // Shop-wide blocks always show; a member's block shows for that member.
    return (
      row.member_id === null || filters.memberId === null || row.member_id === filters.memberId
    );
  }
  if (filters.memberId && !row.assigned_member_ids.includes(filters.memberId)) return false;
  if (filters.resourceId && row.resource_id !== filters.resourceId) return false;
  return true;
}

export function jobEventId(id: string): string {
  return `job:${id}`;
}

/** Blocked times repeat under one id, so the occurrence's start keeps event ids unique. */
export function blockEventId(id: string, startsAt: string): string {
  return `block:${id}@${startsAt}`;
}

/** The shading drawn under a closure (see toEventInputs). */
export function closureShadeEventId(id: string, startsAt: string): string {
  return `${blockEventId(id, startsAt)}#shade`;
}

/** "job:<uuid>" → uuid (null for blocks / foreign ids). */
export function jobIdFromEventId(eventId: string): string | null {
  return eventId.startsWith('job:') ? eventId.slice(4) : null;
}

/** A blocked time's kind ('closed' for rows from before kinds existed). */
export function rowEventKind(row: Pick<CalendarRow, 'event_kind' | 'member_id'>): EventKind {
  if (isEventKind(row.event_kind)) return row.event_kind;
  return row.member_id ? 'time_off' : 'closed';
}

export function eventTitle(row: CalendarRow): string {
  if (row.event_type === 'blocked_time') {
    const kind = rowEventKind(row);
    const base = row.title ?? (kind === 'closed' ? 'Blocked' : EVENT_KIND_LABELS[kind]);
    return row.customer_name ? `${base} · ${row.customer_name}` : base;
  }
  if (row.is_busy_block) return 'Busy';
  const number = row.job_number !== null ? `#${row.job_number}` : 'Job';
  return row.title ? `${number} · ${row.title}` : number;
}

/** Kind colours (tokens) for calendar events without their own colour. */
const EVENT_PALETTE: Record<EventKind, Palette> = {
  closed: { bg: token('surface-3'), border: token('line-strong'), text: token('ink') },
  time_off: { bg: token('surface-3'), border: token('line-strong'), text: token('muted') },
  meeting: { bg: token('surface-2'), border: token('primary'), text: token('ink') },
  consultation: { bg: token('surface-2'), border: token('success'), text: token('ink') },
  reminder: { bg: token('surface-2'), border: token('warning'), text: token('ink') },
  other: { bg: token('surface-2'), border: token('line-strong'), text: token('ink') },
};

export function toEventInputs(
  rows: readonly CalendarRow[],
  filters: CalendarFilters,
  canReschedule: boolean,
  /** Managers open calendar events to edit them. */
  canEditEvents = false,
): EventInput[] {
  return rows
    .filter((row) => matchesFilters(row, filters))
    .flatMap((row): EventInput[] => {
      if (row.event_type === 'blocked_time') {
        const kind = rowEventKind(row);
        const meta: EventMeta = {
          kind,
          seriesId: null,
          blockId: row.id,
          occurrenceStart: row.starts_at,
          customerName: row.customer_name,
        };
        // Every calendar event is an event block (time off, meetings,
        // consultations, reminders, closures), so managers can open it — and
        // it is listed in the month and list views. A shop closure also
        // shades the time grid behind the jobs; FullCalendar never fires
        // eventClick for that background part.
        const palette = EVENT_PALETTE[kind];
        const shade: EventInput[] =
          kind === 'closed'
            ? [
                {
                  id: closureShadeEventId(row.id, row.starts_at),
                  start: row.starts_at,
                  end: row.ends_at,
                  title: '',
                  display: 'background',
                  backgroundColor: token('line-strong'),
                  editable: false,
                  classNames: ['dc-blocked-time'],
                  extendedProps: { ...meta, background: true } satisfies EventMeta,
                },
              ]
            : [];
        const block: EventInput = {
          id: blockEventId(row.id, row.starts_at),
          start: row.starts_at,
          end: row.ends_at,
          title: eventTitle(row),
          backgroundColor: palette.bg,
          borderColor: row.color ?? palette.border,
          textColor: palette.text,
          editable: false,
          interactive: canEditEvents,
          classNames: ['dc-calendar-event', `dc-event-${kind}`],
          extendedProps: meta,
        };
        return [...shade, block];
      }
      const palette = row.is_busy_block || !row.status ? BUSY_PALETTE : STATUS_PALETTE[row.status];
      const movable =
        canReschedule &&
        !row.is_busy_block &&
        row.status !== null &&
        row.status !== 'completed' &&
        row.status !== 'cancelled' &&
        row.status !== 'no_show';
      const meta: EventMeta = { kind: 'job', seriesId: row.series_id };
      return [
        {
          id: jobEventId(row.id),
          start: row.starts_at,
          end: row.ends_at,
          title: eventTitle(row),
          backgroundColor: palette.bg,
          borderColor: palette.border,
          textColor: palette.text,
          editable: movable,
          startEditable: movable,
          durationEditable: movable,
          interactive: !row.is_busy_block,
          classNames: row.is_busy_block ? ['dc-busy-block'] : ['dc-job'],
          extendedProps: meta,
        },
      ];
    });
}

/** The page's view of FullCalendar's extendedProps (null for foreign events). */
export function eventMeta(extendedProps: Record<string, unknown>): EventMeta | null {
  const kind = extendedProps.kind;
  if (kind !== 'job' && !(typeof kind === 'string' && isEventKind(kind))) return null;
  return extendedProps as unknown as EventMeta;
}

/** Events that get a glyph (repeating jobs, calendar events); others render by default. */
export function hasCustomContent(extendedProps: Record<string, unknown>): boolean {
  const meta = eventMeta(extendedProps);
  if (!meta || meta.background) return false;
  if (meta.kind === 'job') return meta.seriesId !== null;
  return true;
}

/** Accessible one-line description of a job event (list view / tooltips). */
export function describeRow(row: CalendarRow): string {
  if (row.event_type === 'blocked_time') {
    return `${EVENT_KIND_LABELS[rowEventKind(row)]}: ${eventTitle(row)}`;
  }
  if (row.is_busy_block) return 'Busy (another team member’s job)';
  const parts = [
    eventTitle(row),
    row.status ? statusLabel('job', row.status) : null,
    row.vehicle_label,
    row.location_type === 'mobile' ? (row.service_address ?? 'Mobile') : null,
    row.series_id ? 'Repeats' : null,
  ];
  return parts.filter(Boolean).join(' · ');
}

export interface BusinessHoursRow {
  weekday: number;
  opens_at: string;
  closes_at: string;
}

/** business_hours rows (shop wall clock) → FullCalendar businessHours. */
export function toBusinessHours(rows: readonly BusinessHoursRow[]): BusinessHoursInput {
  if (rows.length === 0) return false;
  return rows.map((r) => ({
    daysOfWeek: [r.weekday],
    startTime: r.opens_at.slice(0, 5),
    endTime: r.closes_at.startsWith('24:00') ? '24:00' : r.closes_at.slice(0, 5),
  }));
}

/** Earliest opening time ("HH:mm:ss") to scroll day/week views to. */
export function scrollTimeFor(rows: readonly BusinessHoursRow[]): string {
  const earliest = rows.map((r) => r.opens_at.slice(0, 5)).sort()[0];
  if (!earliest) return '07:00:00';
  const hour = Math.max(0, Number(earliest.slice(0, 2)) - 1);
  return `${String(hour).padStart(2, '0')}:00:00`;
}

/** Views rendered by the main FullCalendar instance. */
export type GridView = 'timeGridDay' | 'timeGridWeek' | 'dayGridMonth' | 'listWeek';
/** All calendar views, including the hand-rolled per-bay/van day view and the day map. */
export type CalendarView = GridView | 'resourceDay' | 'dayMap';

export const CALENDAR_VIEWS: readonly { value: CalendarView; label: string }[] = [
  { value: 'timeGridDay', label: 'Day' },
  { value: 'timeGridWeek', label: 'Week' },
  { value: 'dayGridMonth', label: 'Month' },
  { value: 'listWeek', label: 'List' },
  { value: 'resourceDay', label: 'Bays' },
  { value: 'dayMap', label: 'Map' },
];

export function isCalendarView(value: string | null): value is CalendarView {
  return CALENDAR_VIEWS.some((v) => v.value === value);
}

export function isGridView(value: CalendarView): value is GridView {
  return value !== 'resourceDay' && value !== 'dayMap';
}

// ---------------------------------------------------------------------------
// Resource (bay / van) view — FullCalendar's resource views are premium, so
// the page renders one MIT timeGridDay column per resource side by side and
// moves jobs between them with FullCalendar's cross-calendar drag.
// ---------------------------------------------------------------------------

export interface ResourceOption {
  id: string;
  name: string;
  active: boolean;
  archived_at: string | null;
}

export interface ResourceColumn {
  /** null = jobs with no bay / van. */
  id: string | null;
  name: string;
  /** Archived / inactive resource still holding jobs in range. */
  inactive: boolean;
}

export const UNASSIGNED_COLUMN_NAME = 'No bay / van';

/**
 * Columns for the resource view: every active resource (in the shop's order),
 * any inactive/unknown resource that still has jobs in range, then the
 * "No bay / van" column. A resource filter narrows it to that one column.
 */
export function resourceColumns(
  resources: readonly ResourceOption[],
  rows: readonly CalendarRow[],
  filterResourceId: string | null,
): ResourceColumn[] {
  const columns: ResourceColumn[] = resources
    .filter((r) => r.active && !r.archived_at)
    .map((r) => ({ id: r.id, name: r.name, inactive: false }));
  const known = new Set(columns.map((c) => c.id));
  for (const row of rows) {
    if (row.event_type === 'blocked_time' || !row.resource_id || known.has(row.resource_id)) {
      continue;
    }
    known.add(row.resource_id);
    const resource = resources.find((r) => r.id === row.resource_id);
    columns.push({
      id: row.resource_id,
      name: resource ? resource.name : 'Unavailable bay / van',
      inactive: true,
    });
  }
  columns.push({ id: null, name: UNASSIGNED_COLUMN_NAME, inactive: false });
  if (filterResourceId === null) return columns;
  return columns.filter((c) => c.id === filterResourceId);
}

/**
 * Event inputs for one resource column. Calendar events (time off, meetings,
 * consultations, reminders, closures) belong to no bay / van: their blocks
 * show once, in the "No bay / van" column. A shop closure also shades every
 * column, since no bay or van is open then.
 */
export function columnEventInputs(
  rows: readonly CalendarRow[],
  filters: CalendarFilters,
  columnId: string | null,
  canReschedule: boolean,
  canEditEvents = false,
): EventInput[] {
  const inputs = toEventInputs(
    rows.filter((r) => r.event_type === 'blocked_time' || (r.resource_id ?? null) === columnId),
    { memberId: filters.memberId, resourceId: null },
    canReschedule,
    canEditEvents,
  );
  if (columnId === null) return inputs;
  return inputs.filter((input) => {
    const meta = eventMeta(input.extendedProps ?? {});
    return meta?.kind === 'job' || meta?.background === true;
  });
}

function minutesOfDay(iso: string, timeZone: string): number {
  const [h = '0', m = '0'] = formatInTz(iso, timeZone, 'HH:mm').split(':');
  return Number(h) * 60 + Number(m);
}

function slotTime(minutes: number): string {
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:00:00`;
}

/**
 * Visible hours for the resource day view: the day's business hours ± 1 h,
 * widened so no job of that day is ever cut off. Shop wall clock.
 */
export function resourceDayBounds(
  hours: readonly BusinessHoursRow[],
  rows: readonly CalendarRow[],
  date: LocalDate,
  timeZone: string,
): { slotMinTime: string; slotMaxTime: string } {
  const { from, to } = shopDayRangeUtc(date, timeZone);
  const weekday = shopWeekday(from, timeZone);
  const today = hours.filter((h) => h.weekday === weekday);
  let min = 7 * 60;
  let max = 19 * 60;
  if (today.length > 0) {
    min = Math.min(...today.map((h) => localTimeToMinutes(h.opens_at.slice(0, 5)))) - 60;
    max =
      Math.max(
        ...today.map((h) =>
          h.closes_at.startsWith('24:00') ? 1440 : localTimeToMinutes(h.closes_at.slice(0, 5)),
        ),
      ) + 60;
  }
  const fromMs = Date.parse(from);
  const toMs = Date.parse(to);
  for (const row of rows) {
    if (row.event_type === 'blocked_time') continue;
    const s = Date.parse(row.starts_at);
    const e = Date.parse(row.ends_at);
    if (e <= fromMs || s >= toMs) continue;
    min = Math.min(min, s <= fromMs ? 0 : minutesOfDay(row.starts_at, timeZone));
    max = Math.max(max, e >= toMs ? 1440 : minutesOfDay(row.ends_at, timeZone) || 1440);
  }
  const lo = Math.max(0, Math.floor(min / 60) * 60);
  const hi = Math.min(1440, Math.max(lo + 60, Math.ceil(max / 60) * 60));
  return { slotMinTime: slotTime(lo), slotMaxTime: slotTime(hi) };
}
