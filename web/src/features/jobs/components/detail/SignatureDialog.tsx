import { useRef, useState, type ReactNode } from 'react';
import {
  Button,
  Dialog,
  FormField,
  Input,
  SignaturePad,
  type SignaturePadHandle,
} from '@/components/ui';

export interface SignatureDialogProps {
  title: string;
  description?: ReactNode;
  /** Content shown above the signature fields (e.g. the form body). */
  children?: ReactNode;
  requireDrawing: boolean;
  defaultName?: string;
  pending: boolean;
  onClose: () => void;
  onSign: (signerName: string, signature: Blob | null) => Promise<void>;
}

/** Typed name + signature (drawn, or typed for keyboard users), collected on this device. */
export function SignatureDialog({
  title,
  description,
  children,
  requireDrawing,
  defaultName = '',
  pending,
  onClose,
  onSign,
}: SignatureDialogProps) {
  const padRef = useRef<SignaturePadHandle>(null);
  const [name, setName] = useState(defaultName);
  const [hasDrawing, setHasDrawing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setError(null);
    if (!name.trim()) {
      setError('Enter the signer’s full name.');
      return;
    }
    const blob = (await padRef.current?.toBlob()) ?? null;
    if (requireDrawing && !blob) {
      setError('Sign in the box: draw a signature, or choose Type and type it.');
      return;
    }
    await onSign(name.trim(), blob);
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title={title}
      description={description}
      size="lg"
      dismissible={!pending}
      footer={
        <>
          <Button variant="secondary" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button
            loading={pending}
            disabled={!name.trim() || (requireDrawing && !hasDrawing)}
            onClick={() => void submit()}
          >
            Sign
          </Button>
        </>
      }
    >
      <div className="flex flex-col gap-4">
        {children}
        <FormField label="Signer’s full name" required>
          <Input
            value={name}
            maxLength={200}
            autoComplete="name"
            onChange={(e) => setName(e.target.value)}
          />
        </FormField>
        {requireDrawing && (
          <SignaturePad
            ref={padRef}
            label="Customer signature"
            typedDefault={name}
            onChange={setHasDrawing}
          />
        )}
        {error && (
          <p role="alert" className="text-danger-ink text-sm">
            {error}
          </p>
        )}
      </div>
    </Dialog>
  );
}
