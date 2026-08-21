import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const script = fs.readFileSync('scripts/hyperstack-gpu-canary.mjs', 'utf8');
const workflow = fs.readFileSync('.github/workflows/hyperstack-gpu-canary.yml', 'utf8');

test('executor only allowlists non-destructive lifecycle actions', () => {
  assert.match(script, /\['hibernate', 'hibernate-restore', 'start'\]/);
  assert.doesNotMatch(script, /virtual-machines\/\$\{id\}\/delete/);
  assert.doesNotMatch(script, /resize/);
});

test('canary always attempts hibernation and verifies final state', () => {
  assert.match(script, /finally \{/);
  assert.match(script, /await ensureHibernated\(vmId\)/);
  assert.match(script, /waitFor\(id, 'HIBERNATED'/);
  assert.match(script, /evidence\.final_hibernated = true/);
});

test('workflow is manual, serialized, and exact-VM allowlisted', () => {
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /group: hyperstack-gpu-executor/);
  assert.match(workflow, /test "\$\{\{ inputs\.vm_name \}\}" = "ambitious-schrodinger"/);
  assert.doesNotMatch(workflow, /schedule:/);
});

test('workflow requires secrets without committing them', () => {
  assert.match(workflow, /secrets\.HYPERSTACK_API_KEY/);
  assert.match(workflow, /secrets\.HYPERSTACK_SSH_PRIVATE_KEY/);
  assert.doesNotMatch(workflow, /BEGIN (RSA |OPENSSH )?PRIVATE KEY/);
});

test('runtime proof is nvidia-smi and evidence requires hibernation', () => {
  assert.match(script, /nvidia-smi --query-gpu=/);
  assert.match(workflow, /!e\.runtime_verified \|\| !e\.final_hibernated \|\| !e\.success/);
});
