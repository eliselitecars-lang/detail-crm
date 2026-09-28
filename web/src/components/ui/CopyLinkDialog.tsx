import type { ReactNode } from 'react';
import { Button } from './Button';
import { CopyField } from './CopyField';
import { Dialog } from './Dialog';

export interface CopyLinkDialogProps {
  /** The link to show; null closes the dialog. */
  link: string | null;
  onClose: () => void;
  title?: ReactNode;
  description?: ReactNode;
  /** Accessible name of the link ("Form link"). */
  label: string;
  copiedMessage?: string;
}

/**
 * Where a link is shown when the browser refused to copy it (clipboard
 * blocked, or — Safari — the write came after an await and lost the click's
 * user activation). Unlike a toast it stays until closed, so the link can be
 * copied at any pace: the Copy button here is a fresh click, and the text
 * can be selected by hand.
 */
export function CopyLinkDialog({
  link,
  onClose,
  title = 'Copy this link',
  description = 'Your browser didn’t let us copy it automatically. Copy it here.',
  label,
  copiedMessage = 'Link copied',
}: CopyLinkDialogProps) {
  return (
    <Dialog
      open={link !== null}
      onClose={onClose}
      title={title}
      description={description}
      footer={
        <Button variant="secondary" onClick={onClose}>
          Done
        </Button>
      }
    >
      {link !== null && <CopyField value={link} label={label} copiedMessage={copiedMessage} />}
    </Dialog>
  );
}
