import { Download } from 'lucide-react';
import { useEffect, useState } from 'react';
import { cn } from '@/lib/cn';
import { fileStem } from '@/lib/download';
import { downloadQr, qrSvg, svgDataUrl } from '@/lib/qr';
import { Button } from './Button';
import { Spinner } from './Spinner';
import { useToast } from './toastContext';

export interface QrCodeProps {
  /** The text (link) to encode. */
  value: string;
  /** Accessible description of the image ("QR code for your booking page"). */
  label: string;
  /** Download file name stem (sanitised). */
  fileName?: string;
  /** Rendered size in CSS pixels. */
  size?: number;
  /** Hide the PNG / SVG download buttons. */
  hideDownloads?: boolean;
  className?: string;
}

/**
 * A QR code of `value` (generated in the browser) with PNG / SVG downloads
 * for print. Black on white regardless of theme, so phones can scan it.
 */
export function QrCode({
  value,
  label,
  fileName = 'qr-code',
  size = 160,
  hideDownloads = false,
  className,
}: QrCodeProps) {
  const toast = useToast();
  const [state, setState] = useState<{ value: string; src: string | null; failed: boolean }>({
    value: '',
    src: null,
    failed: false,
  });

  useEffect(() => {
    let cancelled = false;
    qrSvg(value).then(
      (svg) => {
        if (!cancelled) setState({ value, src: svgDataUrl(svg), failed: false });
      },
      () => {
        if (!cancelled) setState({ value, src: null, failed: true });
      },
    );
    return () => {
      cancelled = true;
    };
  }, [value]);

  const current = state.value === value;
  const stem = fileStem(fileName, 'qr-code');
  const download = (format: 'png' | 'svg') => {
    downloadQr(value, stem, format).catch((error: unknown) => toast.error(error));
  };

  return (
    <div className={cn('flex flex-wrap items-center gap-4', className)}>
      <div
        className="border-line rounded-card flex shrink-0 items-center justify-center overflow-hidden border bg-white p-1"
        style={{ width: size, height: size }}
      >
        {current && state.src ? (
          <img src={state.src} alt={label} width={size - 8} height={size - 8} />
        ) : current && state.failed ? (
          <p className="px-2 text-center text-xs text-neutral-600">Couldn’t make the QR code.</p>
        ) : (
          <Spinner label="Making the QR code…" />
        )}
      </div>
      {!hideDownloads && (
        <div className="flex flex-col gap-2">
          <Button
            variant="secondary"
            size="sm"
            disabled={!current || !state.src}
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            onClick={() => download('png')}
          >
            Download PNG
          </Button>
          <Button
            variant="secondary"
            size="sm"
            disabled={!current || !state.src}
            leadingIcon={<Download className="size-4" aria-hidden="true" />}
            onClick={() => download('svg')}
          >
            Download SVG
          </Button>
        </div>
      )}
    </div>
  );
}
