/** Job report helpers (pure, unit-tested). */
import type { JobReport, ReportMark, ReportPhoto } from './api';

export interface PhotoPair {
  before: ReportPhoto;
  after: ReportPhoto;
}

/**
 * Before and after photos side by side, in the order they were taken; the
 * unmatched ones (and every other kind) stay in the gallery.
 */
export function pairBeforeAfter(photos: readonly ReportPhoto[]): {
  pairs: PhotoPair[];
  rest: ReportPhoto[];
} {
  const before = photos.filter((p) => p.kind === 'before');
  const after = photos.filter((p) => p.kind === 'after');
  const count = Math.min(before.length, after.length);
  const pairs: PhotoPair[] = [];
  for (let i = 0; i < count; i += 1) {
    const b = before[i];
    const a = after[i];
    if (b && a) pairs.push({ before: b, after: a });
  }
  const paired = new Set(pairs.flatMap((p) => [p.before.id, p.after.id]));
  return { pairs, rest: photos.filter((p) => !paired.has(p.id)) };
}

const KIND_WORDS: Record<ReportPhoto['kind'], string> = {
  before: 'Before',
  after: 'After',
  inspection: 'Inspection',
  other: 'Job',
};

/** Accessible name of a photo / video: its caption, else "<Kind> photo N". */
export function photoLabel(photo: ReportPhoto, index: number): string {
  if (photo.caption) return photo.caption;
  const noun = photo.media_type === 'video' ? 'video' : 'photo';
  return `${KIND_WORDS[photo.kind]} ${noun} ${index + 1}`;
}

export function vehicleText(vehicle: JobReport['vehicle']): string | null {
  if (!vehicle) return null;
  const main = [vehicle.year, vehicle.make, vehicle.model].filter(Boolean).join(' ');
  const text = [main, vehicle.color].filter(Boolean).join(', ');
  return text || null;
}

/** Marks grouped by diagram view, numbered 1..n across the whole inspection. */
export function marksByView(
  marks: readonly ReportMark[],
): { view: ReportMark['view']; marks: (ReportMark & { number: number })[] }[] {
  const order: ReportMark['view'][] = ['front', 'rear', 'left', 'right', 'top', 'interior'];
  const numbered = marks.map((m, i) => ({ ...m, number: i + 1 }));
  return order
    .map((view) => ({ view, marks: numbered.filter((m) => m.view === view) }))
    .filter((g) => g.marks.length > 0);
}
