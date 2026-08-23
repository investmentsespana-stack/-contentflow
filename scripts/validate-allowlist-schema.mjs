import { readFile } from 'node:fs/promises';

export async function validateAllowlistSchema(path = 'schemas/tool_allowlist.v1.schema.json') {
  const schema = JSON.parse(await readFile(path, 'utf8'));
  const properties = schema?.properties ?? {};
  const required = new Set(Array.isArray(schema?.required) ? schema.required : []);
  const toolItem = properties.tools?.items ?? {};
  const toolProperties = toolItem.properties ?? {};
  const toolRequired = new Set(Array.isArray(toolItem.required) ? toolItem.required : []);
  const actionItems = toolProperties.actions?.items ?? {};

  const checks = [
    ['draft_2020_12', schema?.$schema === 'https://json-schema.org/draft/2020-12/schema'],
    ['object_schema', schema?.type === 'object'],
    ['closed_schema', schema?.additionalProperties === false],
    ['version_required', required.has('version')],
    ['allowlist_id_required', required.has('allowlist_id')],
    ['tools_required', required.has('tools')],
    ['version_semver_pattern', typeof properties.version?.pattern === 'string' && properties.version.pattern.length > 0],
    ['allowlist_id_pattern', typeof properties.allowlist_id?.pattern === 'string' && properties.allowlist_id.pattern.length > 0],
    ['tools_array', properties.tools?.type === 'array' && Number(properties.tools?.minItems ?? 0) >= 1],
    ['tool_item_closed', toolItem?.type === 'object' && toolItem?.additionalProperties === false],
    ['tool_name_required', toolRequired.has('tool_name')],
    ['actions_required', toolRequired.has('actions')],
    ['tool_name_pattern', typeof toolProperties.tool_name?.pattern === 'string' && toolProperties.tool_name.pattern.length > 0],
    ['actions_array', toolProperties.actions?.type === 'array' && Number(toolProperties.actions?.minItems ?? 0) >= 1],
    ['action_pattern', actionItems?.type === 'string' && typeof actionItems?.pattern === 'string' && actionItems.pattern.length > 0],
    ['examples_present', Array.isArray(schema.examples) && schema.examples.length > 0],
  ].map(([check, passed]) => ({ check, passed: Boolean(passed) }));

  return { schemaVersion: 1, passed: checks.every((item) => item.passed), path, checks };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const result = await validateAllowlistSchema();
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (!result.passed) process.exitCode = 2;
}
