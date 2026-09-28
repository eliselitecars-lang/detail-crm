import { ArrowDown, ArrowUp, GripVertical, Navigation } from 'lucide-react';
import { lazy, Suspense, useMemo, useState, type DragEvent } from 'react';
import {
  buttonClasses,
  EmptyState,
  ErrorState,
  IconButton,
  LoadingState,
  useToast,
} from '@/components/ui';
import { cn } from '@/lib/cn';
import { formatTimeRange, type LocalDate } from '@/lib/dates';
import { formatAddress } from '@/features/jobs/model';
import { useRoutePositions, useSetRouteOrder, useShopPlace } from './api';
import type { CalendarRow } from './model';
import {
  continuingStops,
  googleRouteUrl,
  isLocated,
  moveInList,
  routeStops,
  type RoutePlace,
  type RouteStop,
} from './route';

const LeafletMap = lazy(() => import('./LeafletMap'));

export interface DayMapViewProps {
  /** The shown day (shop wall clock): its route is the mobile jobs starting that day. */
  date: LocalDate;
  /** calendar_events rows overlapping the day, already narrowed by the page's filters. */
  rows: readonly CalendarRow[];
  timezone: string;
  onOpenJob: (jobId: string) => void;
}

/**
 * The day's mobile jobs on a map, in route order (P-18). Staff reorder the
 * stops (drag, or the arrow buttons) — saved with set_route_order — and hand
 * the route to Google Maps. Stops the iPhone app has not located yet are
 * listed but not mapped.
 */
export function DayMapView({ date, rows, timezone, onOpenJob }: DayMapViewProps) {
  const toast = useToast();
  const jobIds = useMemo(
    () => routeStops(rows, new Map(), date, timezone).map((s) => s.jobId),
    [rows, date, timezone],
  );
  const continuing = useMemo(() => continuingStops(rows, date, timezone), [rows, date, timezone]);
  const positions = useRoutePositions(jobIds);
  const shopPlace = useShopPlace(true);
  const saveOrder = useSetRouteOrder();
  /** Optimistic order while a reorder is saved (local, reversible — README → Mutations). */
  const [order, setOrder] = useState<string[] | null>(null);
  const [dragging, setDragging] = useState<number | null>(null);
  const [announcement, setAnnouncement] = useState('');

  const stops = useMemo(
    () => routeStops(rows, positions.data ?? new Map(), date, timezone),
    [rows, positions.data, date, timezone],
  );
  const ordered = useMemo(() => {
    if (!order) return stops;
    const byId = new Map(stops.map((s) => [s.jobId, s]));
    const list = order.map((id) => byId.get(id)).filter((s) => s !== undefined);
    // stops that appeared meanwhile go last
    return [...list, ...stops.filter((s) => !order.includes(s.jobId))];
  }, [order, stops]);

  const place = shopPlace.data;
  const origin: RoutePlace | null =
    place && typeof place.lat === 'number' && typeof place.lng === 'number'
      ? { lat: place.lat, lng: place.lng }
      : place
        ? formatAddress({
            line1: place.address_line1,
            line2: null,
            city: place.city,
            region: place.region,
            postalCode: place.postal_code,
          })
        : null;
  const route = googleRouteUrl(ordered, origin);
  const located = ordered.filter(isLocated);
  const numberOf = new Map(ordered.map((s, i) => [s.jobId, i + 1]));

  const reorder = (from: number, to: number) => {
    const ids = moveInList(
      ordered.map((s) => s.jobId),
      from,
      to,
    );
    if (ids.every((id, i) => id === ordered[i]?.jobId)) return;
    setOrder(ids);
    const moved = ordered[from];
    setAnnouncement(moved ? `${moved.title} is now stop ${to + 1}.` : '');
    saveOrder.mutate(ids, {
      onError: (error) => {
        setOrder(null);
        toast.error(error, 'The route order was not saved');
      },
    });
  };

  const onDrop = (index: number) => (event: DragEvent<HTMLLIElement>) => {
    event.preventDefault();
    if (dragging !== null) reorder(dragging, index);
    setDragging(null);
  };

  if (positions.isError) {
    return (
      <ErrorState
        compact
        title="Couldn’t load the route"
        error={positions.error}
        onRetry={() => void positions.refetch()}
      />
    );
  }
  if (jobIds.length > 0 && positions.isPending) return <LoadingState label="Loading the route…" />;
  if (ordered.length === 0) {
    return (
      <div className="flex flex-col gap-4">
        <EmptyState
          compact
          title={
            continuing.length > 0 ? 'No mobile jobs start this day' : 'No mobile jobs this day'
          }
          description="Jobs at a customer’s address show here, in the order you drive them."
        />
        <ContinuingStops stops={continuing} timezone={timezone} onOpenJob={onOpenJob} />
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-5">
      <div className="lg:col-span-3">
        {located.length > 0 || (place && typeof place.lat === 'number') ? (
          <Suspense fallback={<LoadingState label="Loading the map…" />}>
            <LeafletMap
              className="border-line rounded-card text-primary z-0 h-80 border sm:h-[28rem]"
              stops={located.map((s) => ({
                jobId: s.jobId,
                order: numberOf.get(s.jobId) ?? 0,
                label: s.title,
                lat: s.lat,
                lng: s.lng,
              }))}
              shop={
                place && typeof place.lat === 'number' && typeof place.lng === 'number'
                  ? { lat: place.lat, lng: place.lng, label: 'The shop' }
                  : null
              }
              onOpenJob={onOpenJob}
            />
          </Suspense>
        ) : (
          <div className="border-line bg-surface-2 rounded-card text-muted flex h-40 items-center justify-center border p-4 text-center text-sm">
            None of these stops is located yet. Open each job in the iPhone app to place it on the
            map.
          </div>
        )}
      </div>
      <section aria-label="Stops in route order" className="flex flex-col gap-3 lg:col-span-2">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h3 className="text-ink text-sm font-semibold">
            {ordered.length} stop{ordered.length === 1 ? '' : 's'}
          </h3>
          {route && (
            <a
              href={route.url}
              target="_blank"
              rel="noreferrer"
              className={buttonClasses({ variant: 'secondary', size: 'sm' })}
            >
              <Navigation className="size-4" aria-hidden="true" />
              Open route in Google Maps
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          )}
        </div>
        {route && route.included < route.total && (
          <p className="text-muted text-xs">
            Google Maps routes through up to 10 stops: the link covers the first {route.included} of{' '}
            {route.total}.
          </p>
        )}
        <p className="text-muted text-xs">Drag the stops, or use the arrows, to set the order.</p>
        <p className="sr-only" aria-live="polite">
          {announcement}
        </p>
        <ol className="flex flex-col gap-2">
          {ordered.map((stop, index) => (
            <li
              key={stop.jobId}
              draggable
              onDragStart={(e) => {
                setDragging(index);
                e.dataTransfer.effectAllowed = 'move';
              }}
              onDragOver={(e) => e.preventDefault()}
              onDrop={onDrop(index)}
              onDragEnd={() => setDragging(null)}
              className={cn(
                'border-line bg-surface rounded-control flex items-start gap-2 border p-2',
                dragging === index && 'opacity-60',
              )}
            >
              <GripVertical
                className="text-muted mt-1 size-4 shrink-0 cursor-grab"
                aria-hidden="true"
              />
              <span
                aria-hidden="true"
                className={cn(
                  'mt-0.5 flex size-6 shrink-0 items-center justify-center rounded-full text-xs font-semibold',
                  isLocated(stop) ? 'bg-primary text-primary-fg' : 'bg-surface-3 text-muted',
                )}
              >
                {index + 1}
              </span>
              <div className="min-w-0 flex-1">
                <button
                  type="button"
                  onClick={() => onOpenJob(stop.jobId)}
                  className="text-ink block max-w-full truncate text-left text-sm font-medium hover:underline"
                >
                  <span className="sr-only">Stop {index + 1}: </span>
                  {stop.title}
                </button>
                <p className="text-muted text-xs">
                  {formatTimeRange(stop.startsAt, stop.endsAt, timezone)}
                  {stop.address ? ` · ${stop.address}` : ''}
                </p>
                {!isLocated(stop) && (
                  <p className="text-warning-ink text-xs">
                    Not located yet — open the job in the iPhone app.
                  </p>
                )}
              </div>
              <span className="flex shrink-0 flex-col">
                <IconButton
                  size="sm"
                  label={`Move ${stop.title} earlier`}
                  icon={<ArrowUp className="size-4" />}
                  disabled={index === 0 || saveOrder.isPending}
                  onClick={() => reorder(index, index - 1)}
                />
                <IconButton
                  size="sm"
                  label={`Move ${stop.title} later`}
                  icon={<ArrowDown className="size-4" />}
                  disabled={index === ordered.length - 1 || saveOrder.isPending}
                  onClick={() => reorder(index, index + 1)}
                />
              </span>
            </li>
          ))}
        </ol>
        <ContinuingStops stops={continuing} timezone={timezone} onOpenJob={onOpenJob} />
      </section>
    </div>
  );
}

/**
 * Multi-day or overnight mobile jobs that began on an earlier day: shown for
 * the record, but not stops of this day's route (set_route_order orders the
 * jobs that start on one day).
 */
function ContinuingStops({
  stops,
  timezone,
  onOpenJob,
}: {
  stops: readonly RouteStop[];
  timezone: string;
  onOpenJob: (jobId: string) => void;
}) {
  if (stops.length === 0) return null;
  return (
    <section aria-label="Continuing from an earlier day" className="flex flex-col gap-2">
      <h3 className="text-ink text-sm font-semibold">Continuing from an earlier day</h3>
      <p className="text-muted text-xs">
        These jobs started before this day, so they are not stops of this day’s route.
      </p>
      <ul className="flex flex-col gap-2">
        {stops.map((stop) => (
          <li
            key={stop.jobId}
            className="border-line bg-surface-2 rounded-control flex flex-col border p-2"
          >
            <button
              type="button"
              onClick={() => onOpenJob(stop.jobId)}
              className="text-ink block max-w-full truncate text-left text-sm font-medium hover:underline"
            >
              {stop.title}
            </button>
            <p className="text-muted text-xs">
              {formatTimeRange(stop.startsAt, stop.endsAt, timezone)}
              {stop.address ? ` · ${stop.address}` : ''}
            </p>
          </li>
        ))}
      </ul>
    </section>
  );
}
