import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const restore = JSON.parse(readFileSync(new URL("../certification-evidence/restore-drill-2026-08-20.json", import.meta.url), "utf8"));
const autonomy = JSON.parse(readFileSync(new URL("../certification-evidence/autonomy-sandbox-2026-08-20.json", import.meta.url), "utf8"));

test("restore drill is isolated, successful, and reports drift honestly", () => {
  assert.equal(restore.production_mutated, false);
  assert.equal(restore.result, "PASS_WITH_DRIFT");
  assert.equal(restore.schema_drift_detected, true);
  assert.ok(restore.restored.director_operating_rules > 0);
  assert.ok(restore.restored.director_repair_recipes > 0);
  assert.ok(restore.live_production_schema_counts_at_drill.tables >= restore.backup_manifest_schema_counts.tables);
});

test("sandbox autonomy evidence is measured rather than declared", () => {
  assert.equal(autonomy.production_mutated, false);
  assert.equal(autonomy.status, "PASS");
  assert.equal(autonomy.total_tasks, 100);
  assert.equal(autonomy.incidents, 50);
  assert.equal(autonomy.autonomous_recoveries, autonomy.incidents);
  assert.equal(autonomy.human_interventions, 0);
  assert.equal(autonomy.autonomy_rate, 1);
  assert.equal(autonomy.completion_rate, 1);
  assert.equal(autonomy.failure_domain_avoidance, true);
});
