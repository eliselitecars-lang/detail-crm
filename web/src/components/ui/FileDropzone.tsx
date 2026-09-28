import { Upload } from 'lucide-react';
import { useId, useRef, useState, type DragEvent, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { Button } from './Button';

export interface FileDropzoneProps {
  /**
   * Accepted types, as for <input accept>: MIME types ("application/pdf",
   * "image/*") and/or extensions (".csv"). Dropped files are checked too.
   */
  accept?: readonly string[];
  multiple?: boolean;
  /** Per-file size limit in bytes. */
  maxBytes?: number;
  /** Most files per pick / drop (multiple only). */
  maxFiles?: number;
  /** Called with the accepted files (never empty). */
  onFiles: (files: File[]) => void;
  /** Called with a message when some files were refused (type / size / count). */
  onReject?: (message: string) => void;
  disabled?: boolean;
  /** Shows a spinner on the button (upload / parse in progress). */
  busy?: boolean;
  /** Main line ("Drop a CSV file here"). */
  label?: ReactNode;
  /** Secondary line (limits, formats). */
  description?: ReactNode;
  /** Button text. */
  buttonLabel?: string;
  /** Error shown under the zone (e.g. from the parent's validation). */
  error?: ReactNode;
  className?: string;
}

/** "25 MB", "200 KB" */
export function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    const mb = bytes / (1024 * 1024);
    return `${Number.isInteger(mb) ? mb : mb.toFixed(1)} MB`;
  }
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} bytes`;
}

/** Whether `file` matches one of the accept entries (MIME, wildcard MIME or extension). */
export function fileMatchesAccept(file: Pick<File, 'name' | 'type'>, accept?: readonly string[]) {
  if (!accept || accept.length === 0) return true;
  const name = file.name.toLowerCase();
  const type = file.type.toLowerCase();
  return accept.some((entry) => {
    const rule = entry.trim().toLowerCase();
    if (rule.startsWith('.')) return name.endsWith(rule);
    if (rule.endsWith('/*')) return type.startsWith(rule.slice(0, -1));
    return type === rule;
  });
}

/**
 * Drag-and-drop file picker with a keyboard/screen-reader friendly button
 * (the drop area is an enhancement; the button always works). Validates type,
 * size and count before handing files to `onFiles`.
 */
export function FileDropzone({
  accept,
  multiple = false,
  maxBytes,
  maxFiles,
  onFiles,
  onReject,
  disabled = false,
  busy = false,
  label = multiple ? 'Drop files here' : 'Drop a file here',
  description,
  buttonLabel = multiple ? 'Choose files' : 'Choose a file',
  error,
  className,
}: FileDropzoneProps) {
  const inputId = useId();
  const descriptionId = `${inputId}-description`;
  const errorId = `${inputId}-error`;
  const inputRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const inactive = disabled || busy;

  const take = (list: FileList | null) => {
    const files = list ? Array.from(list) : [];
    if (files.length === 0) return;
    const problems: string[] = [];
    let accepted = files.filter((file) => {
      if (!fileMatchesAccept(file, accept)) {
        problems.push(`${file.name}: this type of file isn’t accepted.`);
        return false;
      }
      if (file.size === 0) {
        problems.push(`${file.name}: the file is empty.`);
        return false;
      }
      if (maxBytes !== undefined && file.size > maxBytes) {
        problems.push(`${file.name}: larger than ${formatBytes(maxBytes)}.`);
        return false;
      }
      return true;
    });
    const limit = multiple ? maxFiles : 1;
    if (limit !== undefined && accepted.length > limit) {
      problems.push(
        limit === 1 ? 'Choose one file at a time.' : `Choose up to ${limit} files at a time.`,
      );
      accepted = accepted.slice(0, limit);
    }
    if (problems.length > 0) onReject?.(problems.join(' '));
    if (accepted.length > 0) onFiles(accepted);
  };

  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    setDragging(false);
    if (inactive) return;
    take(event.dataTransfer.files);
  };

  const onDragOver = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    if (!inactive) {
      event.dataTransfer.dropEffect = 'copy';
      setDragging(true);
    }
  };

  const hasError = error !== undefined && error !== null && error !== false && error !== '';

  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <div
        onDragOver={onDragOver}
        onDragEnter={onDragOver}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        className={cn(
          'rounded-card flex flex-col items-center justify-center gap-3 border-2 border-dashed px-4 py-8 text-center transition-colors',
          dragging ? 'border-primary bg-primary-soft' : 'border-line-strong bg-surface-2',
          hasError && 'border-danger',
          inactive && 'opacity-70',
        )}
      >
        <Upload className="text-muted size-6" aria-hidden="true" />
        <div>
          <p className="text-ink text-sm font-medium">{label}</p>
          {description && (
            <p id={descriptionId} className="text-muted mt-0.5 text-xs">
              {description}
            </p>
          )}
        </div>
        <input
          ref={inputRef}
          id={inputId}
          type="file"
          className="sr-only"
          tabIndex={-1}
          aria-hidden="true"
          accept={accept?.join(',')}
          multiple={multiple}
          disabled={inactive}
          onChange={(event) => {
            take(event.target.files);
            event.target.value = '';
          }}
        />
        <Button
          variant="secondary"
          size="sm"
          loading={busy}
          disabled={disabled}
          aria-describedby={
            [description ? descriptionId : null, hasError ? errorId : null]
              .filter(Boolean)
              .join(' ') || undefined
          }
          onClick={() => inputRef.current?.click()}
        >
          {buttonLabel}
        </Button>
      </div>
      {hasError && (
        <p id={errorId} role="alert" className="text-danger-ink text-xs font-medium">
          {error}
        </p>
      )}
    </div>
  );
}
