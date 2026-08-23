import ts from 'typescript';

export interface TypeScriptExportExpectation {
  name: string;
  kind: 'function' | 'interface' | 'class' | 'type';
  minParameters?: number;
}

export interface SemanticCheckResult {
  passed: boolean;
  checks: Array<{ check: string; passed: boolean; observed: unknown }>;
}

function isExported(node: ts.Node): boolean {
  return Boolean(node.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword));
}

export function analyzeTypeScriptExports(
  sourceText: string,
  expectations: TypeScriptExportExpectation[],
): SemanticCheckResult {
  const source = ts.createSourceFile('evidence.ts', sourceText, ts.ScriptTarget.ES2022, true, ts.ScriptKind.TS);
  const observed = new Map<string, { kind: TypeScriptExportExpectation['kind']; parameters?: number }>();

  for (const statement of source.statements) {
    if (!isExported(statement)) continue;
    if (ts.isFunctionDeclaration(statement) && statement.name) {
      observed.set(statement.name.text, { kind: 'function', parameters: statement.parameters.length });
    } else if (ts.isInterfaceDeclaration(statement)) {
      observed.set(statement.name.text, { kind: 'interface' });
    } else if (ts.isClassDeclaration(statement) && statement.name) {
      observed.set(statement.name.text, { kind: 'class' });
    } else if (ts.isTypeAliasDeclaration(statement)) {
      observed.set(statement.name.text, { kind: 'type' });
    }
  }

  const checks = expectations.map((expectation) => {
    const match = observed.get(expectation.name);
    const passed = Boolean(
      match &&
        match.kind === expectation.kind &&
        (expectation.minParameters === undefined || (match.parameters ?? 0) >= expectation.minParameters),
    );
    return { check: `typescript_export:${expectation.name}`, passed, observed: match ?? null };
  });

  return { passed: checks.every((check) => check.passed), checks };
}

export function analyzeJsonSchema(
  raw: string,
  requiredProperties: string[],
): SemanticCheckResult {
  let schema: unknown;
  try {
    schema = JSON.parse(raw);
  } catch {
    return { passed: false, checks: [{ check: 'json_parse', passed: false, observed: 'invalid_json' }] };
  }

  if (!schema || typeof schema !== 'object' || Array.isArray(schema)) {
    return { passed: false, checks: [{ check: 'schema_object', passed: false, observed: typeof schema }] };
  }

  const value = schema as Record<string, unknown>;
  const properties = value.properties && typeof value.properties === 'object' && !Array.isArray(value.properties)
    ? (value.properties as Record<string, unknown>)
    : {};
  const required = Array.isArray(value.required) ? value.required.filter((item): item is string => typeof item === 'string') : [];

  const checks = [
    { check: 'schema_type_object', passed: value.type === 'object', observed: value.type ?? null },
    ...requiredProperties.flatMap((property) => [
      { check: `property_declared:${property}`, passed: Object.hasOwn(properties, property), observed: Object.hasOwn(properties, property) },
      { check: `property_required:${property}`, passed: required.includes(property), observed: required.includes(property) },
    ]),
  ];

  return { passed: checks.every((check) => check.passed), checks };
}

function stripSqlComments(sql: string): string {
  return sql
    .replace(/--[^\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ');
}

export function analyzeSqlStatements(sql: string): SemanticCheckResult {
  const statements = stripSqlComments(sql)
    .split(';')
    .map((statement) => statement.trim())
    .filter(Boolean);

  const checks = statements.map((statement, index) => {
    const normalized = statement.replace(/\s+/g, ' ').trim().toUpperCase();
    let passed = true;
    let observed: unknown = 'non_destructive';

    if (/^DELETE\s+FROM\b/.test(normalized)) {
      passed = /\bWHERE\b/.test(normalized);
      observed = passed ? 'delete_with_where' : 'delete_without_where';
    } else if (/^DROP\s+(TABLE|SCHEMA|DATABASE)\b/.test(normalized)) {
      passed = false;
      observed = 'drop_statement';
    } else if (/^TRUNCATE\b/.test(normalized)) {
      passed = false;
      observed = 'truncate_statement';
    }

    return { check: `sql_statement:${index + 1}`, passed, observed };
  });

  return { passed: checks.every((check) => check.passed), checks };
}
