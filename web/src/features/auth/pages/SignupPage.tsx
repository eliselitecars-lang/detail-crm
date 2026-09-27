import { zodResolver } from '@hookform/resolvers/zod';
import { MailCheck } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router';
import type { z } from 'zod';
import { AuthLayout } from '@/components/layout/AuthLayout';
import { Button, FormField, Input } from '@/components/ui';
import { errorMessage } from '@/lib/errors';
import { useAuth } from '../authContext';
import { signUp } from '../api';
import { FormAlert } from '../FormAlert';
import { loginPath, safeNext } from '../redirects';
import { signupSchema } from '../schemas';

type FormInput = z.input<typeof signupSchema>;
type FormOutput = z.output<typeof signupSchema>;

export default function SignupPage() {
  const { status } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const next = safeNext(params.get('next'));
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormInput, unknown, FormOutput>({
    resolver: zodResolver(signupSchema),
    defaultValues: {
      fullName: '',
      email: params.get('email') ?? '',
      password: '',
      confirmPassword: '',
    },
  });

  if (status === 'signedIn' && !sentTo) return <Navigate to={next} replace />;

  if (sentTo) {
    return (
      <AuthLayout
        title="Check your email"
        footer={
          <Link
            to={loginPath(params.get('next') ?? undefined)}
            className="text-primary-ink font-medium hover:underline"
          >
            Back to sign in
          </Link>
        }
      >
        <div className="flex flex-col items-center gap-3 text-center">
          <MailCheck className="text-primary size-10" aria-hidden="true" />
          <p className="text-muted text-sm">
            We sent a confirmation link to <span className="text-ink font-medium">{sentTo}</span>.
            Open it on this device to finish creating your account.
          </p>
        </div>
      </AuthLayout>
    );
  }

  const onSubmit = handleSubmit(async (values) => {
    setSubmitError(null);
    try {
      const result = await signUp({
        email: values.email,
        password: values.password,
        fullName: values.fullName,
        next,
      });
      if (result.signedIn) await navigate(next, { replace: true });
      else setSentTo(values.email);
    } catch (error) {
      setSubmitError(errorMessage(error));
    }
  });

  return (
    <AuthLayout
      title="Create your account"
      description="Start running your detailing business in one place."
      footer={
        <>
          Already have an account?{' '}
          <Link
            to={loginPath(params.get('next') ?? undefined)}
            className="text-primary-ink font-medium hover:underline"
          >
            Sign in
          </Link>
        </>
      }
    >
      <form noValidate onSubmit={(event) => void onSubmit(event)} className="flex flex-col gap-4">
        {submitError && <FormAlert>{submitError}</FormAlert>}
        <FormField label="Your name" error={errors.fullName?.message} required>
          <Input autoComplete="name" {...register('fullName')} />
        </FormField>
        <FormField label="Email" error={errors.email?.message} required>
          <Input type="email" autoComplete="email" {...register('email')} />
        </FormField>
        <FormField
          label="Password"
          error={errors.password?.message}
          help="At least 8 characters."
          required
        >
          <Input type="password" autoComplete="new-password" {...register('password')} />
        </FormField>
        <FormField label="Confirm password" error={errors.confirmPassword?.message} required>
          <Input type="password" autoComplete="new-password" {...register('confirmPassword')} />
        </FormField>
        <Button type="submit" loading={isSubmitting} fullWidth size="lg">
          Create account
        </Button>
      </form>
    </AuthLayout>
  );
}
