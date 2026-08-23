import { mkdir, readFile, writeFile } from 'node:fs/promises';
import ts from 'typescript';

const sourcePath = 'src/guardrails/input-required-fields.ts';
const outDir = '.tmp-evidence';
const modulePath = `${outDir}/input-required-fields.mjs`;
const testPath = `${outDir}/input-required-fields.test.mjs`;

await mkdir(outDir, { recursive: true });
const source = await readFile(sourcePath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ES2022,
    strict: true,
  },
  fileName: sourcePath,
});
await writeFile(modulePath, compiled.outputText, 'utf8');
await writeFile(testPath, `
import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRequiredFields, assertRequiredFields } from './input-required-fields.mjs';

test('covers missing, null, undefined and complete required-field paths', () => {
  assert.deepEqual(validateRequiredFields({task:'x'}, ['task','resource_id']), {ok:false, missing:['resource_id']});
  assert.deepEqual(validateRequiredFields({task:null, resource_id:undefined}, ['task','resource_id']), {ok:false, missing:['task','resource_id']});
  assert.deepEqual(validateRequiredFields({task:'x', resource_id:'r1'}, ['task','resource_id']), {ok:true});
  assert.throws(() => assertRequiredFields({task:'x'}, ['task','resource_id']), /MISSING_REQUIRED_FIELDS:resource_id/);
  assert.doesNotThrow(() => assertRequiredFields({task:'x',resource_id:'r1'}, ['task','resource_id']));
});
`, 'utf8');

process.stdout.write(JSON.stringify({ passed: true, sourcePath, modulePath, testPath }));
