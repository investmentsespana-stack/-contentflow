import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { validatePortableDirectorPair } from "../src/director-contract/portability.mjs";

const cf = JSON.parse(fs.readFileSync(new URL("../projects/contentflow/director-manifest.v1.json", import.meta.url)));
const opc = JSON.parse(fs.readFileSync(new URL("../projects/opc/director-manifest.v1.json", import.meta.url)));

test("shared Director core is portable across ContentFlow and OPC without shared authority", () => {
  const result = validatePortableDirectorPair(cf, opc);
  assert.equal(result.portable, true, result.errors.join("\n"));
  assert.deepEqual(result.projects, ["contentflow", "opc"]);
  assert.ok(result.sharedInvariantCount >= 10);
});

test("OPC remains isolated and non-executable while serving as portability probe", () => {
  assert.equal(opc.status.executable, false);
  assert.equal(opc.spec.capacity.concurrencyLimit, 0);
  assert.equal(opc.security.crossProjectAccess, false);
  assert.equal(cf.security.crossProjectAccess, false);
  assert.notEqual(opc.security.projectBoundary, cf.security.projectBoundary);
  assert.notEqual(opc.metadata.directorId, cf.metadata.directorId);
});

test("project-specific capabilities may differ without breaking shared core portability", () => {
  assert.notDeepEqual(cf.capabilities.supportedTaskClasses, opc.capabilities.supportedTaskClasses);
  const result = validatePortableDirectorPair(cf, opc);
  assert.equal(result.portable, true);
});

test("portability gate fails if OPC is accidentally made executable", () => {
  const mutated = structuredClone(opc);
  mutated.status.executable = true;
  const result = validatePortableDirectorPair(cf, mutated);
  assert.equal(result.portable, false);
  assert.ok(result.errors.includes("OPC_MUST_REMAIN_NON_EXECUTABLE"));
});

test("portability gate fails on cross-project authority or core recovery drift", () => {
  const cross = structuredClone(opc);
  cross.security.crossProjectAccess = true;
  let result = validatePortableDirectorPair(cf, cross);
  assert.equal(result.portable, false);

  const drift = structuredClone(cf);
  drift.recovery.leaseFencingRequired = false;
  result = validatePortableDirectorPair(drift, opc);
  assert.equal(result.portable, false);
  assert.ok(result.errors.some((e) => e.includes("leaseFencingRequired") || e.includes("LEASE_FENCING_REQUIRED")));
});
