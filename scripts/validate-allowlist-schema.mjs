import { readFile } from 'node:fs/promises';

export async function validateAllowlistSchema(path = 'schemas/tool_allowlist.v1.schema.json') {
  const schema = JSON.parse(await readFile(path, 'utf8'));
  const properties = schema?.properties ?? {};
  const required = new Set(Array.isArray(schema?.required) ? schema.required : []);
  const checks = [
    ['draft_2020_12', schema?.$schema === 'https://json-schema.org/draft/2020-12/schema'],
    ['object_schema', schema?.type === 'object'],
    ['closed_schema', schema?.additionalProperties === false],
    ['tool_declared', Boolean(properties.tool)],
    ['action_declared', Boolean(properties.action)],
    ['tool_required', required.has('tool')],
    ['action_required', required.has('action')],
    ['tool_pattern', typeof properties.tool?.pattern === 'string' && properties.tool.pattern.length > 0],
    ['action_pattern', typeof properties.action?.pattern === 'string' && properties.action.pattern.length > 0],
  ].map(([check, passed]) => ({ check, passed: Boolean(passed) }));
  return { schemaVersion: 1, passed: checks.every((item) => item.passed), path, checks };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const result = await validateAllowlistSchema();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.passed) process.exitCode = 2;
}
