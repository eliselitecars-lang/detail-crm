import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link } from 'react-router';
import type { z } from 'zod';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, FormField, Input } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { sendPasswordReset } from '../api';
import { FormAlert } from '../FormAlert';
import { forgotPasswordSchema } from '../schemas';

const schema = forgotPasswordSchema;
type FormInput = z.input<typeof schema>;
type FormOutput = z.output<typeof schema>;

export default function ForgotPasswordPage() {
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(schema),
    defaultValues: { email: '' },
  });

  const onSubmit = handleSubmit(async ({ email }) => {
    setSubmitError(null);
    try {
      await sendPasswordReset(email);
      setSentTo(email);
    } catch (error) {
      setSubmitError(errorMessage(error));
    }
  });

  return (
    <AuthLayout
      title="Reset your password"
      description="Enter your account email and we’ll send you a reset link."
      footer={
        <Link to="/login" className="text-primary-ink font-medium hover:underline">
          Back to sign in
        </Link>
      }
    >
      {sentTo ? (
        <FormAlert tone="success">
          If an account exists for <span className="font-medium">{sentTo}</span>, a reset link is on
          its way. The link expires after a short time.
        </FormAlert>
      ) : (
        <form noValidate onSubmit={(event) => void onSubmit(event)} className="flex flex-col gap-4">
          {submitError && <FormAlert>{submitError}</FormAlert>}
          <FormField label="Email" error={errors.email?.message} required>
            <Input type="email" autoComplete="email" {...register('email')} />
          </FormField>
          <Button type="submit" loading={isSubmitting} fullWidth size="lg">
            Send reset link
          </Button>
        </form>
      )}
    </AuthLayout>
  );
}
