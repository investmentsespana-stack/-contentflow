import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/functions/contentflow-auto-loop/index.ts", import.meta.url), "utf8");

test("auto-loop uses policy-controlled Director parallelism and never hardcodes support-only dispatch", () => {
  assert.match(source, /contentflow_director_core_cycle_auto/);
  assert.doesNotMatch(source, /p_max_dispatch\s*:\s*0/);
});

test("V12 external handoff retry isolation control plane preserves fail-closed evidence-first safety", () => {
  assert.match(source, /DURABLE_EXECUTION_CONTROL_LOOP_V12_EXTERNAL_HANDOFF_RETRY_ISOLATION/);
  assert.match(source, /ensureFreshRecoverySnapshot/);
  assert.match(source, /director_external_evidence/);
  assert.match(source, /recovery_snapshot/);
  assert.match(source, /evaluateAutonomyAdmission/);
  assert.match(source, /autonomy_admission_denied/);
  assert.match(source, /safety_gate/);
  assert.match(source, /contentflow-evidence-tool-runner/);
  assert.match(source, /contentflow-rara/);
  assert.match(source, /contentflow_retry_state/);
  assert.match(source, /contentflow_control_lease_acquire_v1/);
  assert.match(source, /contentflow_control_lease_release_v1/);
});
