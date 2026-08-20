import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateDirectorPair, validatePortableDirectorPair, validateSharedDirectorCore } from "../src/director-contract/portability.mjs";

const projectsDir = fileURLToPath(new URL("../projects/", import.meta.url));

function discoverRegisteredDirectors() {
  return fs.readdirSync(projectsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(projectsDir, entry.name, "director-manifest.v1.json"))
    .filter((manifestPath) => fs.existsSync(manifestPath))
    .map((manifestPath) => JSON.parse(fs.readFileSync(manifestPath, "utf8")))
    .sort((a, b) => a.metadata.projectId.localeCompare(b.metadata.projectId));
}

const projects = discoverRegisteredDirectors();
const byProjectId = new Map(projects.map((manifest) => [manifest.metadata.projectId, manifest]));

test("SDC registry discovers every project that declares a Director manifest", () => {
  assert.ok(projects.length >= 2, "expected at least ContentFlow and OPC to be registered");
  assert.ok(byProjectId.has("contentflow"), "ContentFlow Director must remain registered");
  assert.ok(byProjectId.has("opc"), "OPC Director must remain registered");
  assert.equal(byProjectId.size, projects.length, "projectId values must be unique");
});

test("SDC contract matrix preserves minimum invariants for every registered Director", () => {
  for (const manifest of projects) {
    const result = validateSharedDirectorCore(manifest);
    assert.equal(result.compliant, true, `${manifest.metadata.projectId}:\n${result.errors.join("\n")}`);
  }
});

test("all registered Directors remain pairwise portable without shared authority", () => {
  for (let i = 0; i < projects.length; i++) for (let j = i + 1; j < projects.length; j++) {
    const result = validateDirectorPair(projects[i], projects[j]);
    assert.equal(result.portable, true, result.errors.join("\n"));
    assert.notEqual(projects[i].metadata.directorId, projects[j].metadata.directorId);
    assert.notEqual(projects[i].security.projectBoundary, projects[j].security.projectBoundary);
  }
});

test("OPC role constraints remain enforced independently from generic SDC portability", () => {
  const contentflow = byProjectId.get("contentflow");
  const opc = byProjectId.get("opc");
  assert.ok(contentflow && opc);
  const result = validatePortableDirectorPair(contentflow, opc);
  assert.equal(result.portable, true, result.errors.join("\n"));
});

test("compatibility matrix detects a future contract regression", () => {
  const contentflow = byProjectId.get("contentflow");
  assert.ok(contentflow);
  const broken = structuredClone(contentflow);
  broken.recovery.leaseFencingRequired = false;
  const result = validateSharedDirectorCore(broken);
  assert.equal(result.compliant, false);
});
