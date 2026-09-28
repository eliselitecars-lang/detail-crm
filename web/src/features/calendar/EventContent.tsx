import type { EventContentArg } from '@fullcalendar/core';
import { Ban, Bell, CalendarDays, MessageSquare, Repeat, UserX, Users } from 'lucide-react';
import type { ReactNode } from 'react';
import { EVENT_KIND_LABELS, eventMeta, type EventKind } from './model';

const KIND_ICONS: Record<EventKind, ReactNode> = {
  closed: <Ban className="size-3 shrink-0" aria-hidden="true" />,
  time_off: <UserX className="size-3 shrink-0" aria-hidden="true" />,
  meeting: <Users className="size-3 shrink-0" aria-hidden="true" />,
  consultation: <MessageSquare className="size-3 shrink-0" aria-hidden="true" />,
  reminder: <Bell className="size-3 shrink-0" aria-hidden="true" />,
  other: <CalendarDays className="size-3 shrink-0" aria-hidden="true" />,
};

/**
 * FullCalendar event content with a glyph: repeating jobs (P-1) and the
 * calendar event kinds (P-17). Everything else keeps FullCalendar's default
 * rendering (see `hasCustomContent`).
 */
export function EventContent({ arg }: { arg: EventContentArg }) {
  const meta = eventMeta(arg.event.extendedProps);
  const list = arg.view.type.startsWith('list');
  const glyph =
    meta?.kind === 'job' ? (
      meta.seriesId ? (
        <>
          <Repeat className="size-3 shrink-0" aria-hidden="true" />
          <span className="sr-only">Repeats: </span>
        </>
      ) : null
    ) : meta ? (
      <>
        {KIND_ICONS[meta.kind]}
        <span className="sr-only">{EVENT_KIND_LABELS[meta.kind]}: </span>
      </>
    ) : null;
  return (
    <div className="fc-event-main-frame">
      {arg.timeText && !list && <div className="fc-event-time">{arg.timeText}</div>}
      <div className="fc-event-title-container">
        <div className="fc-event-title fc-sticky flex min-w-0 items-center gap-1">
          {glyph}
          <span className="truncate">{arg.event.title}</span>
        </div>
      </div>
    </div>
  );
}
