import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { validatePortableDirectorPair } from "../src/director-contract/portability.mjs";

const load = (name) => JSON.parse(fs.readFileSync(new URL(`../projects/${name}/director-manifest.v1.json`, import.meta.url)));
const projects = [load("contentflow"), load("opc")];

const required = [
  ["spec.autonomyMode", "bounded-autonomous"],
  ["recovery.leaseFencingRequired", true],
  ["security.crossProjectAccess", false],
];
const get = (obj, path) => path.split(".").reduce((v, k) => v?.[k], obj);

test("SDC contract matrix preserves minimum invariants for every registered Director", () => {
  for (const manifest of projects) {
    for (const [path, expected] of required) assert.equal(get(manifest, path), expected, `${manifest.metadata.projectId}:${path}`);
    assert.ok(manifest.recovery.lastSafeState || manifest.recovery.lastSafeStateRequired || manifest.recovery.resumeFromLastSafeState, `${manifest.metadata.projectId}:last-safe-state`);
  }
});

test("all registered Directors remain pairwise portable without shared authority", () => {
  for (let i=0; i<projects.length; i++) for (let j=i+1; j<projects.length; j++) {
    const result = validatePortableDirectorPair(projects[i], projects[j]);
    assert.equal(result.portable, true, result.errors.join("\n"));
    assert.notEqual(projects[i].metadata.directorId, projects[j].metadata.directorId);
    assert.notEqual(projects[i].security.projectBoundary, projects[j].security.projectBoundary);
  }
});

test("compatibility matrix detects a future contract regression", () => {
  const broken = structuredClone(projects[0]);
  broken.recovery.leaseFencingRequired = false;
  const result = validatePortableDirectorPair(broken, projects[1]);
  assert.equal(result.portable, false);
});
