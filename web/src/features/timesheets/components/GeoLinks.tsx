import { MapPin } from 'lucide-react';
import { formatAccuracy, geoStamp, mapLink, type TimeEntry } from '../model';

/**
 * "Clocked in here" / "Clocked out here" map links for an entry's recorded
 * device locations (the iPhone app stamps them when the member allows
 * location access). Opens Google Maps in a new tab; nothing is loaded here.
 */
export function GeoLinks({ entry, compact = false }: { entry: TimeEntry; compact?: boolean }) {
  const stamps = (['in', 'out'] as const)
    .map((which) => ({ which, stamp: geoStamp(entry, which) }))
    .filter((s) => s.stamp !== null);
  if (stamps.length === 0) {
    return compact ? <span className="text-subtle">—</span> : null;
  }
  return (
    <span className="flex flex-col gap-0.5">
      {stamps.map(({ which, stamp }) =>
        stamp ? (
          <a
            key={which}
            href={mapLink(stamp)}
            target="_blank"
            rel="noopener noreferrer"
            className="text-primary-ink inline-flex items-center gap-1 text-sm hover:underline"
          >
            <MapPin className="size-3.5 shrink-0" aria-hidden="true" />
            {which === 'in' ? 'Clocked in here' : 'Clocked out here'}
            {stamp.accuracyM !== null && (
              <span className="text-muted text-xs">({formatAccuracy(stamp.accuracyM)})</span>
            )}
            <span className="sr-only"> (opens a map in a new tab)</span>
          </a>
        ) : null,
      )}
    </span>
  );
}
