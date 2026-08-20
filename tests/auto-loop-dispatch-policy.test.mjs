import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../supabase/functions/contentflow-auto-loop/index.ts", import.meta.url), "utf8");

test("auto-loop uses policy-controlled Director parallelism and never hardcodes support-only dispatch", () => {
  assert.match(source, /contentflow_director_core_cycle_auto/);
  assert.doesNotMatch(source, /p_max_dispatch\s*:\s*0/);
});

test("V8 evidence-first safety pipeline is preserved around dispatch", () => {
  assert.match(source, /MASTER_DIRECTOR_CONTROL_PLANE_V8_EVIDENCE_FIRST/);
  assert.match(source, /contentflow_evidence_first_reconcile/);
  assert.match(source, /contentflow-throughput-recovery/);
  assert.match(source, /contentflow-adaptive-dispatcher/);
  assert.match(source, /contentflow-evidence-tool-runner/);
  assert.match(source, /contentflow-rara/);
});
