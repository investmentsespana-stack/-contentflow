export type IrreversibleFinding = {
  file_path: string;
  line_number: number;
  operation_type: 'DROP_TABLE' | 'TRUNCATE_TABLE' | 'DELETE_WITHOUT_WHERE' | 'ALTER_DROP_COLUMN';
};

const singleLinePatterns: Array<[RegExp, IrreversibleFinding['operation_type']]> = [
  [/^\s*DROP\s+TABLE\s+/i, 'DROP_TABLE'],
  [/^\s*TRUNCATE\s+TABLE\s+/i, 'TRUNCATE_TABLE'],
  [/^\s*ALTER\s+TABLE\s+[\w.]+\s+DROP\s+COLUMN\s+/i, 'ALTER_DROP_COLUMN'],
];
const deleteStart = /^\s*DELETE\s+FROM\s+[\w.]+\b/i;
const comment = /^\s*(--|#|\/\/)/;

export function scanMigrationText(filePath: string, source: string): IrreversibleFinding[] {
  const findings: IrreversibleFinding[] = [];
  const lines = source.split(/\r?\n/);

  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (comment.test(line)) continue;

    for (const [pattern, operationType] of singleLinePatterns) {
      if (pattern.test(line)) {
        findings.push({ file_path: filePath, line_number: index + 1, operation_type: operationType });
      }
    }

    if (deleteStart.test(line)) {
      const startLine = index + 1;
      const statementLines = [line];
      while (!statementLines[statementLines.length - 1].includes(';') && index + 1 < lines.length) {
        index += 1;
        statementLines.push(lines[index]);
      }
      const statement = statementLines.join('\n').replace(/--.*$/gm, ' ');
      if (!/\bWHERE\b/i.test(statement)) {
        findings.push({ file_path: filePath, line_number: startLine, operation_type: 'DELETE_WITHOUT_WHERE' });
      }
    }
  }

  return findings;
}

export function scanMigrationSet(files: Array<{ path: string; content: string }>): IrreversibleFinding[] {
  return files.flatMap((file) => scanMigrationText(file.path, file.content));
}
