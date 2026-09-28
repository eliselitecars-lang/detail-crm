/**
 * Detail CRM UI kit. Import from '@/components/ui'. Every component uses the
 * design tokens in src/index.css (light + dark) — never hard-code colours.
 */
export { Avatar, initials, type AvatarProps } from './Avatar';
export { Badge, type BadgeProps, type BadgeTone } from './Badge';
export {
  Button,
  buttonClasses,
  type ButtonProps,
  type ButtonSize,
  type ButtonVariant,
} from './Button';
export {
  Card,
  CardBody,
  CardFooter,
  CardHeader,
  type CardHeaderProps,
  type CardProps,
} from './Card';
export { Checkbox, type CheckboxProps } from './Checkbox';
export { Combobox, type ComboboxProps } from './Combobox';
export { ConfirmDialog, type ConfirmDialogProps } from './ConfirmDialog';
export { CopyField, type CopyFieldProps } from './CopyField';
export { DateInput, TimeInput, type DateInputProps, type TimeInputProps } from './DateTimeInputs';
export { Dialog, type DialogProps } from './Dialog';
export { Drawer, type DrawerProps } from './Drawer';
export {
  DropdownMenu,
  type DropdownMenuEntry,
  type DropdownMenuItem,
  type DropdownMenuProps,
} from './DropdownMenu';
export {
  FileDropzone,
  fileMatchesAccept,
  formatBytes,
  type FileDropzoneProps,
} from './FileDropzone';
export { FormField, type FormFieldProps } from './FormField';
export { controlClasses, useFormFieldControl } from './formFieldContext';
export { IconButton, type IconButtonProps } from './IconButton';
export { Input, type InputProps } from './Input';
export { KeyValueList, type KeyValueItem, type KeyValueListProps } from './KeyValue';
export { MoneyInput, type MoneyInputProps } from './MoneyInput';
export { PageHeader, type PageHeaderProps } from './PageHeader';
export { Pagination, pageRange, type PaginationProps } from './Pagination';
export { PhoneInput, type PhoneInputProps } from './PhoneInput';
export { QrCode, type QrCodeProps } from './QrCode';
export { Portal } from './Portal';
export { RadioGroup, type RadioGroupProps, type RadioOption } from './RadioGroup';
export { SearchInput, type SearchInputProps } from './SearchInput';
export { SectionCard, type SectionCardProps } from './SectionCard';
export { Select, type SelectOption, type SelectProps } from './Select';
export { SignaturePad, type SignaturePadHandle, type SignaturePadProps } from './SignaturePad';
export { Skeleton, SkeletonRows } from './Skeleton';
export { Spinner } from './Spinner';
export {
  EmptyState,
  ErrorState,
  LoadingState,
  type EmptyStateProps,
  type ErrorStateProps,
  type LoadingStateProps,
} from './States';
export {
  STATUS_MAP,
  StatusBadge,
  statusLabel,
  statusTone,
  type StatusBadgeProps,
  type StatusKind,
  type StatusOf,
} from './StatusBadge';
export { Switch, type SwitchProps } from './Switch';
export { Table, type Column, type SortDirection, type SortState, type TableProps } from './Table';
export { Tabs, type TabItem, type TabsProps } from './Tabs';
export { Textarea, type TextareaProps } from './Textarea';
export { ToastProvider } from './Toast';
export { useToast, type ToastApi, type ToastInput, type ToastTone } from './toastContext';
export { Tooltip, type TooltipProps } from './Tooltip';
