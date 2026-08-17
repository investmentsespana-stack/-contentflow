export type IrreversibleOperation = {
  operationId: string;
  file: string;
  scope: string;
  kind: string;
  line?: number;
};

export type OverrideAnnotation = {
  annotationId: string;
  file: string;
  scope: string;
  operationKinds?: string[];
  line?: number;
};

export type OverridePairRecord = {
  operationId: string;
  file: string;
  scope: string;
  kind: string;
  status: 'paired' | 'unannotated';
  annotationId: string | null;
};

function sameLexicalScope(operationScope: string, annotationScope: string): boolean {
  return operationScope.trim() === annotationScope.trim();
}

function supportsKind(annotation: OverrideAnnotation, kind: string): boolean {
  return !annotation.operationKinds || annotation.operationKinds.length === 0 || annotation.operationKinds.includes(kind);
}

/**
 * Reconciles irreversible operations with override annotations.
 * Pairing is fail-closed: an annotation only authorizes an operation when
 * both records are in the same file and exact lexical scope, and the
 * annotation explicitly supports the operation kind when kinds are declared.
 */
export function pairIrreversibleOperationsWithOverrides(
  operations: IrreversibleOperation[],
  annotations: OverrideAnnotation[],
): OverridePairRecord[] {
  const seenOperationIds = new Set<string>();
  const seenAnnotationIds = new Set<string>();

  for (const annotation of annotations) {
    if (!annotation.annotationId?.trim()) throw new Error('OVERRIDE_ANNOTATION_ID_REQUIRED');
    if (seenAnnotationIds.has(annotation.annotationId)) throw new Error('DUPLICATE_OVERRIDE_ANNOTATION_ID');
    seenAnnotationIds.add(annotation.annotationId);
    if (!annotation.file?.trim() || !annotation.scope?.trim()) throw new Error('OVERRIDE_ANNOTATION_LOCATION_REQUIRED');
  }

  return operations.map((operation) => {
    if (!operation.operationId?.trim()) throw new Error('IRREVERSIBLE_OPERATION_ID_REQUIRED');
    if (seenOperationIds.has(operation.operationId)) throw new Error('DUPLICATE_IRREVERSIBLE_OPERATION_ID');
    seenOperationIds.add(operation.operationId);
    if (!operation.file?.trim() || !operation.scope?.trim() || !operation.kind?.trim()) {
      throw new Error('IRREVERSIBLE_OPERATION_METADATA_REQUIRED');
    }

    const candidates = annotations.filter((annotation) =>
      annotation.file === operation.file &&
      sameLexicalScope(operation.scope, annotation.scope) &&
      supportsKind(annotation, operation.kind),
    );

    if (candidates.length > 1) throw new Error('AMBIGUOUS_OVERRIDE_ANNOTATION');

    const match = candidates[0] ?? null;
    return {
      operationId: operation.operationId,
      file: operation.file,
      scope: operation.scope,
      kind: operation.kind,
      status: match ? 'paired' : 'unannotated',
      annotationId: match?.annotationId ?? null,
    };
  });
}
