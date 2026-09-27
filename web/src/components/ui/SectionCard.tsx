import { useId, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { Card, CardBody, CardFooter, CardHeader } from './Card';

export interface SectionCardProps {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  footer?: ReactNode;
  children: ReactNode;
  /** Remove body padding (tables, lists that run edge to edge). */
  flush?: boolean;
  className?: string;
  level?: 2 | 3;
}

/** Card with a titled header — the standard block on detail/settings pages. */
export function SectionCard({
  title,
  description,
  actions,
  footer,
  children,
  flush = false,
  className,
  level = 2,
}: SectionCardProps) {
  const headingId = useId();
  return (
    <Card as="section" aria-labelledby={headingId} className={cn('overflow-hidden', className)}>
      <CardHeader
        id={headingId}
        title={title}
        description={description}
        actions={actions}
        level={level}
      />
      {flush ? children : <CardBody>{children}</CardBody>}
      {footer && <CardFooter>{footer}</CardFooter>}
    </Card>
  );
}
