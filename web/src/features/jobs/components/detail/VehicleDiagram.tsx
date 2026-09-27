import type { MouseEvent, ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { clampUnit, VIEW_LABELS, type VehicleView } from '../../model';

const W = 400;
const H = 240;

/** Schematic outlines (original artwork; tokens only — currentColor + CSS vars). */
function Outline({ view }: { view: VehicleView }): ReactNode {
  const body = 'fill-[var(--dc-surface-2)] stroke-current';
  const glass = 'fill-[var(--dc-surface-3)] stroke-current';
  const wheel = 'fill-[var(--dc-line-strong)] stroke-current';
  switch (view) {
    case 'left':
    case 'right':
      return (
        <g transform={view === 'right' ? `translate(${W} 0) scale(-1 1)` : undefined} strokeWidth={2}>
          <path
            className={body}
            d="M30 165 L30 135 Q32 118 60 112 L120 104 L165 66 Q176 58 196 58 L270 58 Q290 58 302 70 L338 108 L362 116 Q374 122 374 138 L374 165 Z"
          />
          <path className={glass} d="M132 104 L170 70 Q178 64 192 64 L228 64 L228 104 Z" />
          <path className={glass} d="M238 64 L270 64 Q284 64 294 74 L322 104 L238 104 Z" />
          <line x1="232" y1="106" x2="232" y2="160" className="stroke-current" />
          <circle cx="100" cy="168" r="30" className={wheel} />
          <circle cx="300" cy="168" r="30" className={wheel} />
        </g>
      );
    case 'front':
    case 'rear':
      return (
        <g strokeWidth={2}>
          <path
            className={body}
            d="M70 190 L70 128 Q72 108 96 104 L120 62 Q126 52 140 52 L260 52 Q274 52 280 62 L304 104 Q328 108 330 128 L330 190 Z"
          />
          <path className={glass} d="M128 100 L146 64 L254 64 L272 100 Z" />
          {view === 'front' ? (
            <>
              <rect x="88" y="124" width="54" height="18" rx="6" className={glass} />
              <rect x="258" y="124" width="54" height="18" rx="6" className={glass} />
              <rect x="160" y="146" width="80" height="22" rx="4" className={glass} />
            </>
          ) : (
            <>
              <rect x="84" y="120" width="44" height="26" rx="4" className={glass} />
              <rect x="272" y="120" width="44" height="26" rx="4" className={glass} />
              <rect x="170" y="150" width="60" height="16" rx="3" className={glass} />
            </>
          )}
          <rect x="78" y="190" width="42" height="26" rx="6" className={wheel} />
          <rect x="280" y="190" width="42" height="26" rx="6" className={wheel} />
        </g>
      );
    case 'top':
      return (
        <g strokeWidth={2}>
          <rect x="40" y="50" width="320" height="140" rx="46" className={body} />
          <path className={glass} d="M118 60 L150 72 L150 168 L118 180 Q104 120 118 60 Z" />
          <rect x="160" y="74" width="120" height="92" rx="10" className={glass} />
          <path className={glass} d="M300 66 L320 72 Q330 120 320 168 L300 174 Z" />
        </g>
      );
    case 'interior':
      return (
        <g strokeWidth={2}>
          <rect x="40" y="30" width="320" height="180" rx="30" className={body} />
          <rect x="70" y="52" width="80" height="60" rx="10" className={glass} />
          <rect x="70" y="128" width="80" height="60" rx="10" className={glass} />
          <rect x="190" y="52" width="140" height="136" rx="14" className={glass} />
          <circle cx="110" cy="82" r="14" className="fill-none stroke-current" />
          <line x1="160" y1="60" x2="160" y2="180" className="stroke-current" />
        </g>
      );
  }
}

export interface DiagramMark {
  id: string;
  x: number;
  y: number;
  number: number;
}

export interface VehicleDiagramProps {
  view: VehicleView;
  marks: readonly DiagramMark[];
  /** Called with 0..1 coordinates; omit when the inspection is locked. */
  onAdd?: (x: number, y: number) => void;
  className?: string;
}

/**
 * Tap-to-mark vehicle diagram. The whole drawing is one button: a pointer
 * click places the mark where tapped; keyboard activation places it in the
 * centre (the mark's note describes the exact spot).
 */
export function VehicleDiagram({ view, marks, onAdd, className }: VehicleDiagramProps) {
  const svg = (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      className="text-muted block h-auto w-full"
      aria-hidden="true"
      focusable="false"
    >
      <Outline view={view} />
      {marks.map((m) => (
        <g key={m.id} transform={`translate(${m.x * W} ${m.y * H})`}>
          <circle r="11" className="fill-[var(--dc-danger)] stroke-[var(--dc-surface)]" strokeWidth={2} />
          <text
            textAnchor="middle"
            dominantBaseline="central"
            className="fill-white text-[11px] font-semibold"
          >
            {m.number}
          </text>
        </g>
      ))}
    </svg>
  );

  const frame = cn('rounded-control border-line bg-surface block w-full border p-2', className);
  if (!onAdd) {
    return (
      <div className={frame} role="img" aria-label={`${VIEW_LABELS[view]} view with ${marks.length} damage marks`}>
        {svg}
      </div>
    );
  }

  const onClick = (event: MouseEvent<HTMLButtonElement>) => {
    const box = event.currentTarget.querySelector('svg')?.getBoundingClientRect();
    if (event.detail === 0 || !box || box.width === 0 || box.height === 0) {
      onAdd(0.5, 0.5);
      return;
    }
    onAdd(
      clampUnit((event.clientX - box.left) / box.width),
      clampUnit((event.clientY - box.top) / box.height),
    );
  };

  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(frame, 'hover:border-primary cursor-crosshair')}
      aria-label={`${VIEW_LABELS[view]} view, ${marks.length} damage marks. Activate to add a damage mark.`}
    >
      {svg}
    </button>
  );
}
