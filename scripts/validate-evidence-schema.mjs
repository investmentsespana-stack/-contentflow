import { readFile } from 'node:fs/promises';

export async function validateEvidenceSchema(path = 'schemas/evidence/v1.json') {
  const schema = JSON.parse(await readFile(path, 'utf8'));
  const requiredNames = ['builder_run_id', 'timestamp', 'action_id', 'artifact_type', 'payload_hash', 'storage_location'];
  const required = new Set(Array.isArray(schema.required) ? schema.required : []);
  const properties = schema.properties ?? {};
  const checks = [
    ['draft_2020_12', schema.$schema === 'https://json-schema.org/draft/2020-12/schema'],
    ['object_schema', schema.type === 'object'],
    ['closed_schema', schema.additionalProperties === false],
    ['builder_run_correlation', properties.builder_run_id?.const === 2923],
    ...requiredNames.map((name) => [`required:${name}`, required.has(name)]),
    ...requiredNames.map((name) => [`read_only:${name}`, properties[name]?.readOnly === true]),
    ['payload_hash_sha256', typeof properties.payload_hash?.pattern === 'string' && properties.payload_hash.pattern.includes('sha256')],
  ].map(([check, passed]) => ({ check, passed: Boolean(passed) }));
  return { schemaVersion: 1, passed: checks.every((item) => item.passed), path, checks };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const result = await validateEvidenceSchema();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.passed) process.exitCode = 2;
}
