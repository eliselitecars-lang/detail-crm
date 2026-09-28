import { zodResolver } from '@hookform/resolvers/zod';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link, useNavigate } from 'react-router';
import type { z } from 'zod';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, buttonClasses, FormField, Input, LoadingState, useToast } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { useAuth } from '../authContext';
import { updatePassword } from '../api';
import { FormAlert } from '../FormAlert';
import { startupRefusal } from '@/lib/authUrlSession';
import { endPasswordRecovery } from '../recoverySession';
import { readRecoveryLinkError } from '../redirects';
import { resetPasswordSchema } from '../schemas';

type FormInput = z.input<typeof resetPasswordSchema>;
type FormOutput = z.output<typeof resetPasswordSchema>;

export default function ResetPasswordPage() {
  const { status, user, recovery, recoveryChecking } = useAuth();
  const navigate = useNavigate();
  const toast = useToast();
  const [linkError] = useState(() => readRecoveryLinkError(window.location.href));
  // A reset link for another account than the one signed in here is ignored
  // (lib/authUrlSession.ts): it never replaces this browser's session.
  const [otherAccount] = useState(() => startupRefusal() === 'other_account');
  const [submitError, setSubmitError] = useState<string | null>(null);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(resetPasswordSchema),
    defaultValues: { password: '', confirmPassword: '' },
  });

  const requestNew = (
    <Link to="/forgot-password" className="text-primary-ink font-medium hover:underline">
      Request a new reset link
    </Link>
  );

  // The form below changes the password WITHOUT the current one, so it is
  // offered only to a session that just redeemed a valid reset link — never
  // to an ordinary signed-in session (shared or unattended browser).
  if (linkError === null && (status === 'loading' || (status === 'signedIn' && recoveryChecking))) {
    return (
      <AuthLayout title="Set a new password">
        <LoadingState label="Checking your reset link…" />
      </AuthLayout>
    );
  }

  if (otherAccount && linkError === null) {
    return (
      <AuthLayout title="Set a new password" footer={requestNew}>
        <div className="flex flex-col gap-4">
          <FormAlert>
            This reset link is for a different account than the one signed in here. Sign out, then
            open the link from the email again.
          </FormAlert>
          <Link to="/app" className={buttonClasses({ variant: 'secondary', fullWidth: true })}>
            Back to the app
          </Link>
        </div>
      </AuthLayout>
    );
  }

  if (linkError !== null || status !== 'signedIn') {
    return (
      <AuthLayout title="Set a new password" footer={requestNew}>
        <FormAlert>
          {linkError ?? 'This reset link is invalid or has expired. Request a new one.'}
        </FormAlert>
      </AuthLayout>
    );
  }

  if (!recovery) {
    return (
      <AuthLayout title="Set a new password" footer={requestNew}>
        <div className="flex flex-col gap-4">
          <FormAlert>
            To set a new password, open the reset link from your latest email in this browser. If it
            has expired or was already used, request a new one.
          </FormAlert>
          <Link to="/app" className={buttonClasses({ variant: 'secondary', fullWidth: true })}>
            Back to the app
          </Link>
        </div>
      </AuthLayout>
    );
  }

  const onSubmit = handleSubmit(async ({ password }) => {
    setSubmitError(null);
    try {
      await updatePassword(password);
      toast.success('Password updated');
      await navigate('/app', { replace: true });
      endPasswordRecovery(); // after leaving the page, so it never flashes the "open the link" notice
    } catch (error) {
      setSubmitError(errorMessage(error));
    }
  });

  return (
    <AuthLayout
      title="Set a new password"
      description={
        // Named, so a reset link for someone else's account is recognisable.
        user?.email ? (
          <>
            Choose a new password for <span className="text-ink break-all">{user.email}</span>.
          </>
        ) : (
          'Choose a new password for your account.'
        )
      }
    >
      <form noValidate onSubmit={(event) => void onSubmit(event)} className="flex flex-col gap-4">
        {submitError && <FormAlert>{submitError}</FormAlert>}
        <FormField
          label="New password"
          error={errors.password?.message}
          help="At least 8 characters."
          required
        >
          <Input type="password" autoComplete="new-password" {...register('password')} />
        </FormField>
        <FormField label="Confirm new password" error={errors.confirmPassword?.message} required>
          <Input type="password" autoComplete="new-password" {...register('confirmPassword')} />
        </FormField>
        <Button type="submit" loading={isSubmitting} fullWidth size="lg">
          Update password
        </Button>
      </form>
    </AuthLayout>
  );
}
