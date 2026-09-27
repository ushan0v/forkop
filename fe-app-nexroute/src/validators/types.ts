export interface ValidationResult {
  valid: boolean;
  message: string;
}

interface BulkValidationResultItem<T> extends ValidationResult {
  value: T;
}

export interface BulkValidationResult<T> {
  valid: boolean;
  results: BulkValidationResultItem<T>[];
}
