import { ArrowLeft, ArrowRight } from 'lucide-react';
import { useEffect, useRef, type FormEvent, type ReactNode } from 'react';
import { Button, Card, CardBody, CardFooter } from '@/components/ui';

/**
 * One wizard step: a titled card whose heading takes focus when the step
 * opens (screen readers announce the new step), plus Back / Continue.
 * The body is a <form> so Enter submits "Continue".
 */
export function StepFrame({
  title,
  description,
  children,
  onBack,
  onContinue,
  continueLabel = 'Continue',
  continueDisabled = false,
  continueLoading = false,
  continueVariant = 'primary',
  autoFocus = true,
}: {
  title: string;
  description?: ReactNode;
  children: ReactNode;
  onBack?: () => void;
  onContinue: () => void;
  continueLabel?: string;
  continueDisabled?: boolean;
  continueLoading?: boolean;
  continueVariant?: 'primary' | 'money';
  autoFocus?: boolean;
}) {
  const headingRef = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (autoFocus) headingRef.current?.focus();
  }, [autoFocus]);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    if (!continueDisabled && !continueLoading) onContinue();
  };

  return (
    <Card as="section" aria-labelledby="booking-step-title">
      <form noValidate onSubmit={submit}>
        <div className="border-line border-b px-4 py-4 sm:px-5">
          <h2
            id="booking-step-title"
            ref={headingRef}
            tabIndex={-1}
            className="text-ink text-lg font-semibold outline-none"
          >
            {title}
          </h2>
          {description && <p className="text-muted mt-1 text-sm">{description}</p>}
        </div>
        <CardBody className="flex flex-col gap-5">{children}</CardBody>
        <CardFooter className="justify-between">
          {onBack ? (
            <Button
              variant="ghost"
              onClick={onBack}
              leadingIcon={<ArrowLeft className="size-4" aria-hidden="true" />}
            >
              Back
            </Button>
          ) : (
            <span />
          )}
          <Button
            type="submit"
            size="lg"
            variant={continueVariant}
            disabled={continueDisabled}
            loading={continueLoading}
            trailingIcon={<ArrowRight className="size-4" aria-hidden="true" />}
          >
            {continueLabel}
          </Button>
        </CardFooter>
      </form>
    </Card>
  );
}
