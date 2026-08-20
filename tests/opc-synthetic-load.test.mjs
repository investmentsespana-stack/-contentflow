import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { runOpcSyntheticLoad } from '../experiments/opc-synthetic-load/harness.mjs';

const opcManifest = JSON.parse(
  fs.readFileSync(new URL('../projects/opc/director-manifest.v1.json', import.meta.url), 'utf8'),
);

test('OPC synthetic load proves bounded queueing, deterministic recovery and stale-worker fencing without enabling runtime execution', () => {
  const result = runOpcSyntheticLoad({
    totalTasks: 2000,
    virtualWorkers: 8,
    queueLimit: 32,
    failureEvery: 29,
  });

  assert.equal(opcManifest.status.executable, false);
  assert.equal(opcManifest.spec.capacity.concurrencyLimit, 0);
  assert.equal(result.externalEffects, 0);
  assert.equal(result.manifestConcurrencyChanged, false);
  assert.equal(result.completedTasks, result.totalTasks);
  assert.ok(result.backpressureEvents > 0, 'load must exercise backpressure');
  assert.ok(result.maxQueueDepth <= result.queueLimit, 'queue must remain bounded');
  assert.equal(result.recoveredFailures, result.injectedFailures);
  assert.equal(result.staleCompletionsRejected, result.injectedFailures);
  assert.ok(result.maxWaitTicks <= 8, `unexpected starvation bound: ${result.maxWaitTicks}`);

  const evidence = {
    ...result,
    invariant: 'OPC remains non-executable while an isolated virtual harness proves bounded backpressure, last-safe-state recovery and fencing behavior',
    opcExecutable: opcManifest.status.executable,
    opcConcurrencyLimit: opcManifest.spec.capacity.concurrencyLimit,
  };

  fs.mkdirSync('certification-evidence', { recursive: true });
  fs.writeFileSync(
    'certification-evidence/opc-synthetic-load-evidence.json',
    `${JSON.stringify(evidence, null, 2)}\n`,
    'utf8',
  );
});
