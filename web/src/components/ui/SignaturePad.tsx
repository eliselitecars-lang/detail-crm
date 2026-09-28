import { Eraser } from 'lucide-react';
import SignaturePadLib from 'signature_pad';
import { useEffect, useImperativeHandle, useRef, useState, type Ref } from 'react';
import { cn } from '@/lib/cn';
import { Button } from './Button';
import { FormField } from './FormField';
import { Input } from './Input';
import { RadioGroup } from './RadioGroup';

export interface SignaturePadHandle {
  clear: () => void;
  isEmpty: () => boolean;
  /** PNG data URL (transparent background), or null when empty. */
  toDataURL: () => string | null;
  /** PNG blob for uploading to the `signatures` bucket, or null when empty. */
  toBlob: () => Promise<Blob | null>;
}

export type SignatureMode = 'draw' | 'type';

export interface SignaturePadProps {
  ref?: Ref<SignaturePadHandle>;
  /** Accessible name, e.g. "Customer signature". */
  label: string;
  /** Fires with whether the pad currently has a signature (drawn or typed). */
  onChange?: (hasSignature: boolean) => void;
  disabled?: boolean;
  className?: string;
  /** CSS height of the drawing area. */
  heightClassName?: string;
  /** Offered as the typed signature when someone switches to "Type" (e.g. the signer's name). */
  typedDefault?: string;
}

/** Longest typed signature (the signer name fields allow 200; a signature line is shorter). */
export const TYPED_SIGNATURE_MAX = 100;

const TYPED_FONT =
  '"Segoe Script", "Brush Script MT", "Snell Roundhand", "Apple Chancery", "URW Chancery L", cursive';

/**
 * Renders a typed signature onto the canvas (device pixels), shrinking the
 * font until it fits. The same canvas is exported, so a typed signature
 * uploads exactly like a drawn one (the server requires a signature image).
 */
function drawTyped(canvas: HTMLCanvasElement, text: string, color: string) {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  ctx.save();
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const value = text.trim();
  if (value) {
    const maxWidth = canvas.width * 0.9;
    let size = Math.max(Math.round(canvas.height * 0.42), 12);
    ctx.font = `italic ${size}px ${TYPED_FONT}`;
    while (size > 12 && ctx.measureText(value).width > maxWidth) {
      size -= 2;
      ctx.font = `italic ${size}px ${TYPED_FONT}`;
    }
    ctx.fillStyle = color;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(value, canvas.width / 2, canvas.height * 0.62, maxWidth);
  }
  ctx.restore();
}

/**
 * A signature, drawn (signature_pad; scales for devicePixelRatio and keeps
 * the drawing across resizes) or typed. Drawing needs a pointer, so "Type"
 * is always offered: a keyboard or screen-reader user types their
 * signature, which is rendered onto the same canvas and exported as the
 * same PNG (WCAG 2.1.1). Pair it with a typed "signer name" field.
 */
export function SignaturePad({
  ref,
  label,
  onChange,
  disabled = false,
  className,
  heightClassName = 'h-44',
  typedDefault,
}: SignaturePadProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const padRef = useRef<SignaturePadLib | null>(null);
  const [mode, setModeState] = useState<SignatureMode>('draw');
  const [typed, setTyped] = useState('');
  const [drawnEmpty, setDrawnEmpty] = useState(true);
  const modeRef = useRef(mode);
  const typedRef = useRef(typed);
  const onChangeRef = useRef(onChange);
  useEffect(() => {
    onChangeRef.current = onChange;
    modeRef.current = mode;
    typedRef.current = typed;
  });

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const pad = new SignaturePadLib(canvas, {
      penColor: penColorOf(canvas),
      minWidth: 0.8,
      maxWidth: 2.4,
    });
    padRef.current = pad;
    const handleEnd = () => {
      const isEmpty = pad.isEmpty();
      setDrawnEmpty(isEmpty);
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
      if (modeRef.current === 'type') drawTyped(canvas, typedRef.current, penColorOf(canvas));
      else if (data.length > 0) pad.fromData(data);
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

  // Drawing is on only in "draw" mode (a typed signature is a preview).
  useEffect(() => {
    const pad = padRef.current;
    if (!pad) return;
    if (disabled || mode === 'type') pad.off();
    else pad.on();
  }, [disabled, mode]);

  // Keep the typed preview on the canvas.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (mode === 'type' && canvas) drawTyped(canvas, typed, penColorOf(canvas));
  }, [mode, typed]);

  const hasSignature = mode === 'type' ? typed.trim() !== '' : !drawnEmpty;

  const setMode = (next: SignatureMode) => {
    if (next === modeRef.current) return;
    padRef.current?.clear();
    setDrawnEmpty(true);
    const canvas = canvasRef.current;
    let text = '';
    if (next === 'type') {
      const current = typedRef.current.trim() ? typedRef.current : (typedDefault ?? '');
      text = current.trim().slice(0, TYPED_SIGNATURE_MAX);
    } else if (canvas) {
      drawTyped(canvas, '', penColorOf(canvas));
    }
    modeRef.current = next;
    typedRef.current = text;
    setTyped(text);
    setModeState(next);
    onChangeRef.current?.(next === 'type' && text !== '');
  };

  const changeTyped = (value: string) => {
    typedRef.current = value;
    setTyped(value);
    onChangeRef.current?.(value.trim() !== '');
  };

  const clear = () => {
    padRef.current?.clear();
    setDrawnEmpty(true);
    typedRef.current = '';
    setTyped('');
    const canvas = canvasRef.current;
    if (modeRef.current === 'type' && canvas) drawTyped(canvas, '', penColorOf(canvas));
    onChangeRef.current?.(false);
  };

  const isEmpty = () =>
    modeRef.current === 'type'
      ? typedRef.current.trim() === ''
      : (padRef.current?.isEmpty() ?? true);

  useImperativeHandle(ref, () => ({
    clear,
    isEmpty,
    toDataURL: () => {
      const canvas = canvasRef.current;
      if (!canvas || isEmpty()) return null;
      if (modeRef.current === 'type') {
        drawTyped(canvas, typedRef.current, penColorOf(canvas));
        return canvas.toDataURL('image/png');
      }
      return padRef.current?.toDataURL('image/png') ?? null;
    },
    toBlob: () =>
      new Promise<Blob | null>((resolve) => {
        const canvas = canvasRef.current;
        if (!canvas || isEmpty()) {
          resolve(null);
          return;
        }
        if (modeRef.current === 'type') drawTyped(canvas, typedRef.current, penColorOf(canvas));
        canvas.toBlob((blob) => resolve(blob), 'image/png');
      }),
  }));

  const typedValue = typed.trim();
  const canvasLabel =
    mode === 'type'
      ? `${label}${typedValue ? ` (typed: ${typedValue})` : ' (empty — type your signature below)'}`
      : `${label}${drawnEmpty ? ' (empty — draw with mouse, finger or stylus, or choose Type)' : ' (signed)'}`;

  return (
    <div className={cn('flex flex-col gap-2', className)}>
      <RadioGroup<SignatureMode>
        label={`How to sign: ${label}`}
        hideLabel
        orientation="horizontal"
        value={mode}
        onChange={setMode}
        disabled={disabled}
        options={[
          { value: 'draw', label: 'Draw' },
          { value: 'type', label: 'Type' },
        ]}
      />
      <div
        className={cn(
          'rounded-card border-line-strong bg-surface relative overflow-hidden border border-dashed',
          disabled && 'opacity-60',
        )}
      >
        <canvas
          ref={canvasRef}
          role="img"
          aria-label={canvasLabel}
          className={cn('text-ink block w-full', mode === 'draw' && 'touch-none', heightClassName)}
        />
        {!hasSignature && (
          <span
            aria-hidden="true"
            className="border-line-strong text-subtle pointer-events-none absolute inset-x-6 bottom-8 border-b pb-1 text-xs"
          >
            {mode === 'type' ? 'Your typed signature appears here' : 'Sign here'}
          </span>
        )}
      </div>
      {mode === 'type' && (
        <FormField
          label="Type your signature"
          help="Typing your name here signs the same as drawing it."
          disabled={disabled}
        >
          <Input
            value={typed}
            onChange={(event) => changeTyped(event.target.value)}
            maxLength={TYPED_SIGNATURE_MAX}
            autoComplete="off"
            spellCheck={false}
          />
        </FormField>
      )}
      <div className="flex justify-end">
        <Button
          variant="ghost"
          size="sm"
          leadingIcon={<Eraser className="size-4" aria-hidden="true" />}
          onClick={clear}
          disabled={disabled || !hasSignature}
        >
          Clear signature
        </Button>
      </div>
    </div>
  );
}

function penColorOf(canvas: HTMLCanvasElement): string {
  return getComputedStyle(canvas).color || '#0B1220';
}
