import { useState } from 'react';
import { isHexColor, readableTextOn } from '@/components/layout/brand';
import { cn } from '@/lib/cn';

export interface AvatarProps {
  name: string | null | undefined;
  src?: string | null;
  /**
   * Background colour (e.g. shop_members.calendar_color, any "#RRGGBB" a
   * member picks). The initials take white or ink, whichever is readable.
   */
  color?: string | null;
  size?: 'xs' | 'sm' | 'md' | 'lg';
  className?: string;
}

const sizes = {
  xs: 'size-6 text-[10px]',
  sm: 'size-8 text-xs',
  md: 'size-10 text-sm',
  lg: 'size-14 text-lg',
} as const;

/** Fallback colours; white initials reach 4.5:1 on each (Avatar.test.tsx). */
export const AVATAR_PALETTE = [
  '#1F6FEB',
  '#177A42',
  '#6941C6',
  '#107569',
  '#C4320A',
  '#C11574',
  '#475467',
  '#B54708',
] as const;

export function initials(name: string | null | undefined): string {
  const parts = (name ?? '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  const first = parts[0]?.[0] ?? '';
  const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '';
  return (first + last).toUpperCase();
}

function colorFor(name: string): string {
  let hash = 0;
  for (let i = 0; i < name.length; i += 1) hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
  return AVATAR_PALETTE[hash % AVATAR_PALETTE.length] ?? '#1F6FEB';
}

export function Avatar({ name, src, color, size = 'md', className }: AvatarProps) {
  const [failed, setFailed] = useState(false);
  const label = name?.trim() || 'Unknown';
  if (src && !failed) {
    return (
      <img
        src={src}
        alt={label}
        onError={() => setFailed(true)}
        className={cn('shrink-0 rounded-full object-cover', sizes[size], className)}
      />
    );
  }
  const background = isHexColor(color) ? color : colorFor(label);
  return (
    <span
      role="img"
      aria-label={label}
      style={{ backgroundColor: background, color: readableTextOn(background) }}
      className={cn(
        'inline-flex shrink-0 items-center justify-center rounded-full font-semibold select-none',
        sizes[size],
        className,
      )}
    >
      {initials(name)}
    </span>
  );
}
