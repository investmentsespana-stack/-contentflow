export type IrreversibleFinding = {
  file_path: string;
  line_number: number;
  operation_type: 'DROP_TABLE' | 'TRUNCATE_TABLE' | 'DELETE_WITHOUT_WHERE' | 'ALTER_DROP_COLUMN';
};

const patterns: Array<[RegExp, IrreversibleFinding['operation_type']]> = [
  [/^\s*DROP\s+TABLE\s+/i, 'DROP_TABLE'],
  [/^\s*TRUNCATE\s+TABLE\s+/i, 'TRUNCATE_TABLE'],
  [/^\s*DELETE\s+FROM\s+[\w.]+\s*(?!WHERE)/i, 'DELETE_WITHOUT_WHERE'],
  [/^\s*ALTER\s+TABLE\s+[\w.]+\s+DROP\s+COLUMN\s+/i, 'ALTER_DROP_COLUMN'],
];
const comment = /^\s*(--|#|\/\/)/;

export function scanMigrationText(filePath: string, source: string): IrreversibleFinding[] {
  const findings: IrreversibleFinding[] = [];
  source.split(/\r?\n/).forEach((line, index) => {
    if (comment.test(line)) return;
    for (const [pattern, operationType] of patterns) {
      if (pattern.test(line)) {
        findings.push({ file_path: filePath, line_number: index + 1, operation_type: operationType });
      }
    }
  });
  return findings;
}

export function scanMigrationSet(files: Array<{ path: string; content: string }>): IrreversibleFinding[] {
  return files.flatMap((file) => scanMigrationText(file.path, file.content));
}
