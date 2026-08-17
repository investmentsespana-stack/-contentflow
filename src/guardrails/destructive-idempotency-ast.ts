export type AstNode = {
  type: 'program' | 'function' | 'call' | 'block';
  name?: string;
  callee?: string;
  file?: string;
  line?: number;
  children?: AstNode[];
};

export type DestructiveMapping = {
  file: string;
  line: number;
  callee: string;
  protected_by: 'process_with_idempotency';
};

export type DestructiveViolation = {
  file: string;
  line: number;
  callee: string;
  reason: 'destructive_call_outside_process_with_idempotency';
};

export type DestructiveAstReport = {
  compliant_mappings: DestructiveMapping[];
  violations: DestructiveViolation[];
  zero_violations: boolean;
};

const DEFAULT_DESTRUCTIVE = new Set([
  'delete',
  'remove',
  'destroy',
  'drop',
  'truncate',
  'purge',
  'revoke',
  'overwrite',
]);

function terminalName(callee: string): string {
  const normalized = callee.replace(/\?\./g, '.');
  const parts = normalized.split('.');
  return (parts[parts.length - 1] || normalized).toLowerCase();
}

export function analyzeDestructiveAst(
  root: AstNode,
  destructiveNames: ReadonlySet<string> = DEFAULT_DESTRUCTIVE,
): DestructiveAstReport {
  const compliant_mappings: DestructiveMapping[] = [];
  const violations: DestructiveViolation[] = [];

  const walk = (node: AstNode, functionStack: string[], inheritedFile: string) => {
    const file = node.file || inheritedFile || '<unknown>';
    const nextStack =
      node.type === 'function' && node.name
        ? [...functionStack, node.name]
        : functionStack;

    if (node.type === 'call' && node.callee) {
      const calleeName = terminalName(node.callee);
      if (destructiveNames.has(calleeName)) {
        const protectedByIdempotency = nextStack.includes('process_with_idempotency');
        const line = node.line || 0;
        if (protectedByIdempotency) {
          compliant_mappings.push({
            file,
            line,
            callee: node.callee,
            protected_by: 'process_with_idempotency',
          });
        } else {
          violations.push({
            file,
            line,
            callee: node.callee,
            reason: 'destructive_call_outside_process_with_idempotency',
          });
        }
      }
    }

    for (const child of node.children || []) {
      walk(child, nextStack, file);
    }
  };

  walk(root, [], root.file || '<unknown>');
  return {
    compliant_mappings,
    violations,
    zero_violations: violations.length === 0,
  };
}

export function assertDestructiveCallsAreIdempotent(root: AstNode): DestructiveAstReport {
  const report = analyzeDestructiveAst(root);
  if (!report.zero_violations) {
    const detail = report.violations
      .map((v) => `${v.file}:${v.line}:${v.callee}`)
      .join(', ');
    throw new Error(`DESTRUCTIVE_IDEMPOTENCY_VIOLATION:${detail}`);
  }
  return report;
}
