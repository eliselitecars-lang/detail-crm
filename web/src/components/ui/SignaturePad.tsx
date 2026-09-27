import { Eraser } from 'lucide-react';
import SignaturePadLib from 'signature_pad';
import { useEffect, useImperativeHandle, useRef, useState, type Ref } from 'react';
import { cn } from '@/lib/cn';
import { Button } from './Button';

export interface SignaturePadHandle {
  clear: () => void;
  isEmpty: () => boolean;
  /** PNG data URL (transparent background), or null when empty. */
  toDataURL: () => string | null;
  /** PNG blob for uploading to the `signatures` bucket, or null when empty. */
  toBlob: () => Promise<Blob | null>;
}

export interface SignaturePadProps {
  ref?: Ref<SignaturePadHandle>;
  /** Accessible name, e.g. "Customer signature". */
  label: string;
  /** Fires with whether the pad currently has a signature. */
  onChange?: (hasSignature: boolean) => void;
  disabled?: boolean;
  className?: string;
  /** CSS height of the drawing area. */
  heightClassName?: string;
}

/**
 * Drawn signature (signature_pad). Scales for devicePixelRatio and preserves
 * the drawing across resizes. Pair it with a typed "signer name" field — the
 * drawn image alone is not an accessible way to sign.
 */
export function SignaturePad({
  ref,
  label,
  onChange,
  disabled = false,
  className,
  heightClassName = 'h-44',
}: SignaturePadProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const padRef = useRef<SignaturePadLib | null>(null);
  const [empty, setEmpty] = useState(true);
  const onChangeRef = useRef(onChange);
  useEffect(() => {
    onChangeRef.current = onChange;
  });

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const pad = new SignaturePadLib(canvas, {
      penColor: getComputedStyle(canvas).color || '#0B1220',
      minWidth: 0.8,
      maxWidth: 2.4,
    });
    padRef.current = pad;
    const handleEnd = () => {
      const isEmpty = pad.isEmpty();
      setEmpty(isEmpty);
      onChangeRef.current?.(!isEmpty);
    };
    pad.addEventListener('endStroke', handleEnd);

    const resize = () => {
      const ratio = Math.max(window.devicePixelRatio || 1, 1);
      const data = pad.toData();
      canvas.width = canvas.offsetWidth * ratio;
      canvas.height = canvas.offsetHeight * ratio;
      canvas.getContext('2d')?.scale(ratio, ratio);
      pad.clear();
      if (data.length > 0) pad.fromData(data);
    };
    resize();
    const observer = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(resize) : null;
    observer?.observe(canvas);

    return () => {
      observer?.disconnect();
      pad.removeEventListener('endStroke', handleEnd);
      pad.off();
      padRef.current = null;
    };
  }, []);

  useEffect(() => {
    const pad = padRef.current;
    if (!pad) return;
    if (disabled) pad.off();
    else pad.on();
  }, [disabled]);

  const clear = () => {
    padRef.current?.clear();
    setEmpty(true);
    onChangeRef.current?.(false);
  };

  useImperativeHandle(ref, () => ({
    clear,
    isEmpty: () => padRef.current?.isEmpty() ?? true,
    toDataURL: () => {
      const pad = padRef.current;
      return pad && !pad.isEmpty() ? pad.toDataURL('image/png') : null;
    },
    toBlob: () =>
      new Promise<Blob | null>((resolve) => {
        const pad = padRef.current;
        const canvas = canvasRef.current;
        if (!pad || !canvas || pad.isEmpty()) {
          resolve(null);
          return;
        }
        canvas.toBlob((blob) => resolve(blob), 'image/png');
      }),
  }));

  return (
    <div className={cn('flex flex-col gap-2', className)}>
      <div
        className={cn(
          'rounded-card border-line-strong bg-surface relative overflow-hidden border border-dashed',
          disabled && 'opacity-60',
        )}
      >
        <canvas
          ref={canvasRef}
          role="img"
          aria-label={`${label}${empty ? ' (empty — draw with mouse, finger or stylus)' : ' (signed)'}`}
          className={cn('text-ink block w-full touch-none', heightClassName)}
        />
        {empty && (
          <span
            aria-hidden="true"
            className="border-line-strong text-subtle pointer-events-none absolute inset-x-6 bottom-8 border-b pb-1 text-xs"
          >
            Sign here
          </span>
        )}
      </div>
      <div className="flex justify-end">
        <Button
          variant="ghost"
          size="sm"
          leadingIcon={<Eraser className="size-4" aria-hidden="true" />}
          onClick={clear}
          disabled={disabled || empty}
        >
          Clear signature
        </Button>
      </div>
    </div>
  );
}
