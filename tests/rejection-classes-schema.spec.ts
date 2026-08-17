import { test, expect } from '@playwright/test';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';

const schemaPath = resolve(process.cwd(), 'rejection_classes.v1.schema');
const expected = [
  'format_violation',
  'missing_required_field',
  'secret_exposure',
  'unwarranted_assumption',
  'contradictory_content',
  'temporal_anomaly',
  'cardinality_violation',
  'domain_constraint',
];

test('rejection_classes.v1.schema is canonical, complete, and parser-neutral', () => {
  const raw = readFileSync(schemaPath, 'utf8');
  const schema = JSON.parse(raw);

  expect(schema['x-contentflow-version']).toBe('1.0.0');
  expect(schema.enum).toEqual(expected);
  expect(schema['x-decision-order']).toEqual(expected);
  expect(Object.keys(schema['x-rejection-classes'])).toEqual(expected);
  expect(new Set(schema.enum).size).toBe(expected.length);

  for (const id of expected) {
    const entry = schema['x-rejection-classes'][id];
    expect(entry.definition.length).toBeGreaterThan(20);
    expect(entry.discriminant_rule.length).toBeGreaterThan(20);
  }

  // Independent parser check: Python standard JSON parser.
  execFileSync('python3', ['-m', 'json.tool', schemaPath], { stdio: 'pipe' });

  // Independent parser check: Go standard encoding/json parser.
  const dir = mkdtempSync(join(tmpdir(), 'contentflow-rejection-schema-'));
  const goFile = join(dir, 'parse.go');
  writeFileSync(goFile, `package main\nimport (\"encoding/json\"; \"os\")\nfunc main(){ b,err:=os.ReadFile(os.Args[1]); if err!=nil { panic(err) }; var v any; if err:=json.Unmarshal(b,&v); err!=nil { panic(err) } }\n`);
  execFileSync('go', ['run', goFile, schemaPath], { stdio: 'pipe' });
});
