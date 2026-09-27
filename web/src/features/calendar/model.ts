/**
 * Calendar mapping: calendar_events rows → FullCalendar event inputs
 * (colours from design tokens only), client-side team/resource filters and
 * business_hours → FullCalendar businessHours. Instants stay ISO strings; the
 * calendar renders them in the SHOP timezone (luxon3 plugin), never the
 * browser's.
 */
import type { BusinessHoursInput, EventInput } from '@fullcalendar/core';
import { statusLabel } from '@/components/ui';
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

export function blockEventId(id: string): string {
  return `block:${id}`;
}

/** "job:<uuid>" → uuid (null for blocks / foreign ids). */
export function jobIdFromEventId(eventId: string): string | null {
  return eventId.startsWith('job:') ? eventId.slice(4) : null;
}

export function eventTitle(row: CalendarRow): string {
  if (row.event_type === 'blocked_time') return row.title ?? 'Blocked';
  if (row.is_busy_block) return 'Busy';
  const number = row.job_number !== null ? `#${row.job_number}` : 'Job';
  return row.title ? `${number} · ${row.title}` : number;
}

export function toEventInputs(
  rows: readonly CalendarRow[],
  filters: CalendarFilters,
  canReschedule: boolean,
): EventInput[] {
  return rows
    .filter((row) => matchesFilters(row, filters))
    .map((row): EventInput => {
      if (row.event_type === 'blocked_time') {
        return {
          id: blockEventId(row.id),
          start: row.starts_at,
          end: row.ends_at,
          title: eventTitle(row),
          display: 'background',
          backgroundColor: token('line-strong'),
          editable: false,
          classNames: ['dc-blocked-time'],
        };
      }
      const palette = row.is_busy_block || !row.status ? BUSY_PALETTE : STATUS_PALETTE[row.status];
      const movable =
        canReschedule &&
        !row.is_busy_block &&
        row.status !== null &&
        row.status !== 'completed' &&
        row.status !== 'cancelled' &&
        row.status !== 'no_show';
      return {
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
      };
    });
}

/** Accessible one-line description of a job event (list view / tooltips). */
export function describeRow(row: CalendarRow): string {
  if (row.is_busy_block) return 'Busy (another team member’s job)';
  const parts = [
    eventTitle(row),
    row.status ? statusLabel('job', row.status) : null,
    row.vehicle_label,
    row.location_type === 'mobile' ? (row.service_address ?? 'Mobile') : null,
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

export type CalendarView = 'timeGridDay' | 'timeGridWeek' | 'dayGridMonth' | 'listWeek';

export const CALENDAR_VIEWS: readonly { value: CalendarView; label: string }[] = [
  { value: 'timeGridDay', label: 'Day' },
  { value: 'timeGridWeek', label: 'Week' },
  { value: 'dayGridMonth', label: 'Month' },
  { value: 'listWeek', label: 'List' },
];

export function isCalendarView(value: string | null): value is CalendarView {
  return CALENDAR_VIEWS.some((v) => v.value === value);
}
